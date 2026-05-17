#!/usr/bin/env bash
# =============================================================================
# emudoi - Build & push an LLM runner image on a fresh Hetzner box.
#
# Spins up a Hetzner VM, builds the Dockerfile in this repo with MODEL_NAME +
# HF_TOKEN as build-args, pushes the result to ghcr.io/emudoi/<slug>:<tag>,
# then tears the VM down. Hard 3-hour ceiling — if the build hangs, the box
# gets nuked regardless.
#
# Usage:
#   ./build.sh                      # interactive: prompts for model name
#   ./build.sh --model Qwen/Qwen2.5-7B-Instruct
#   ./build.sh --model meta-llama/Llama-3.1-8B-Instruct --tag vllm0.10
#   ./build.sh --no-teardown        # keep the box after build (debugging)
#   ./build.sh --list-locations     # print which DCs sell SERVER_TYPE and exit
#
# Prompts for any credential not pre-set or cached at ~/.config/emudoi/:
#   HETZNER_TOKEN     Hetzner Cloud API token
#   GIT_PAT           GitHub PAT, scopes: repo + write:packages
#   HF_TOKEN          HuggingFace token (model download)
#
# Optional env vars:
#   NODE_NAME         default: emudoi-image-builder
#   SERVER_TYPE       default: cpx41 (16vCPU shared / 32GB / 240GB, ~€0.068/h)
#   LOCATION          default: auto — picked from /v1/server_types at runtime
#                     (preferred order: nbg1 > fsn1 > hel1 > ash > hil > sin)
#   MAX_BUILD_HOURS   default: 3  (kill switch — server torn down regardless)
#
# SSH key: ${REPO_ROOT}/emudoi_infra_desktop_only — gitignored. Same key as
# emudoi-desktop-infra; drop it in from there.
# =============================================================================
set -euo pipefail

MODEL_NAME=""
IMAGE_TAG="latest"
TEARDOWN=1
LIST_LOCATIONS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --model=*) MODEL_NAME="${1#*=}"; shift ;;
    --model)   MODEL_NAME="${2:-}"; shift 2 ;;
    --tag=*)   IMAGE_TAG="${1#*=}"; shift ;;
    --tag)     IMAGE_TAG="${2:-}"; shift 2 ;;
    --no-teardown) TEARDOWN=0; shift ;;
    --list-locations) LIST_LOCATIONS=1; shift ;;
    -h|--help)
      sed -n '2,/^# ===*$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown arg: $1 (try --help)" >&2; exit 1 ;;
  esac
done

HETZNER_API="https://api.hetzner.cloud/v1"
NODE_NAME="${NODE_NAME:-emudoi-image-builder}"
SERVER_TYPE="${SERVER_TYPE:-cpx41}"
# LOCATION is auto-discovered from the API if empty — see "Resolve location"
# block below. Set it explicitly only if you need a specific DC.
LOCATION="${LOCATION:-}"
IMAGE="ubuntu-24.04"
SSH_KEY_NAME="emudoi-infra-desktop-only"
FIREWALL_NAME="${NODE_NAME}-firewall"
MAX_BUILD_HOURS="${MAX_BUILD_HOURS:-3}"
CACHE_DIR="${HOME}/.config/emudoi"

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "${REPO_ROOT}"

SSH_KEY="${REPO_ROOT}/emudoi_infra_desktop_only"
[ -f "${SSH_KEY}" ] || {
  echo "[build] ERROR: SSH key not found at ${SSH_KEY}" >&2
  echo "[build]        Copy it from your emudoi-desktop-infra checkout." >&2
  exit 1
}
chmod 600 "${SSH_KEY}"

log() { echo "[build] $*"; }

for cmd in curl jq ssh scp; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[build] ERROR: '${cmd}' is required but not installed." >&2
    exit 1
  }
done

# Cached credentials — same pattern as dev-up.sh's RCLONE_DRIVE_TOKEN cache.
# Each cached file is chmod 600 inside chmod 700 dir; first paste persists.
mkdir -p "${CACHE_DIR}" && chmod 700 "${CACHE_DIR}"
resolve_cred() {
  local var="$1" prompt="$2" cache="${CACHE_DIR}/$3"
  local val="${!var:-}"
  if [ -z "${val}" ] && [ -f "${cache}" ]; then
    val=$(cat "${cache}")
  fi
  if [ -z "${val}" ]; then
    printf "%s" "${prompt}" >&2
    IFS= read -rs val < /dev/tty
    echo >&2
    [ -n "${val}" ] || { echo "[build] ERROR: empty ${var}" >&2; exit 1; }
    umask 077 && printf '%s' "${val}" > "${cache}"
    log "Cached ${var} at ${cache}" >&2
  fi
  printf '%s' "${val}"
}

HETZNER_TOKEN=$(resolve_cred HETZNER_TOKEN "Hetzner Cloud API token: " hetzner-token)
GIT_PAT=$(resolve_cred GIT_PAT "GitHub PAT (repo + write:packages): " ghcr-pat)
HF_TOKEN=$(resolve_cred HF_TOKEN "HuggingFace token: " hf-token)
export HETZNER_TOKEN GIT_PAT HF_TOKEN

if [ -z "${MODEL_NAME}" ]; then
  printf "HuggingFace model name [Qwen/Qwen2.5-7B-Instruct]: "
  IFS= read -r MODEL_NAME < /dev/tty
  MODEL_NAME="${MODEL_NAME:-Qwen/Qwen2.5-7B-Instruct}"
fi
case "${MODEL_NAME}" in
  */*) : ;;
  *) echo "[build] ERROR: MODEL_NAME must look like 'org/model' (got '${MODEL_NAME}')" >&2; exit 1 ;;
esac

IMAGE_SLUG=$(echo "${MODEL_NAME#*/}" | tr '[:upper:]' '[:lower:]')
IMAGE_FULL="ghcr.io/emudoi/${IMAGE_SLUG}:${IMAGE_TAG}"
log "Will build and push: ${IMAGE_FULL}"

SSH_OPTS=(-i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

api() {
  local resp http_code body
  resp=$(curl -s -w '\n%{http_code}' \
    -H "Authorization: Bearer ${HETZNER_TOKEN}" \
    "$@")
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [ "${http_code:0:1}" != "2" ]; then
    {
      echo "[build] ERROR: Hetzner API returned HTTP ${http_code}"
      echo "[build]        Request: $*"
      [ -n "${body}" ] && (echo "${body}" | jq . 2>/dev/null || echo "${body}")
    } >&2
    exit 1
  fi
  printf '%s' "${body}"
}

# Teardown — invoked on EXIT (success, failure, or Ctrl+C). Idempotent.
teardown() {
  local rc=$?
  if [ "${TEARDOWN}" = "0" ]; then
    log "--no-teardown set; leaving ${NODE_NAME} alive (rc=${rc})."
    log "Clean up later with: ./build-down.sh"
    exit "${rc}"
  fi
  log "Tearing down ${NODE_NAME}..."
  local SID
  SID=$(api "${HETZNER_API}/servers?name=${NODE_NAME}" | jq -r '.servers[0].id // empty')
  if [ -n "${SID}" ]; then
    curl -sf -X DELETE -H "Authorization: Bearer ${HETZNER_TOKEN}" \
      "${HETZNER_API}/servers/${SID}" > /dev/null || true
    log "Deleted server ${NODE_NAME} (id=${SID})"
  fi
  local FID
  FID=$(api "${HETZNER_API}/firewalls?name=${FIREWALL_NAME}" | jq -r '.firewalls[0].id // empty')
  if [ -n "${FID}" ]; then
    curl -sf -X DELETE -H "Authorization: Bearer ${HETZNER_TOKEN}" \
      "${HETZNER_API}/firewalls/${FID}" > /dev/null || true
    log "Deleted firewall ${FIREWALL_NAME} (id=${FID})"
  fi
  exit "${rc}"
}
trap teardown EXIT

# =============================================================================
# 0. Resolve DATACENTER from /v1/datacenters BEFORE provisioning anything.
#
# Why not /server_types: that endpoint returns global pricing for every SKU,
# which doesn't reflect what THIS project can actually provision — the SKU
# might be priced in a DC the project's quota or current inventory state
# blocks. The 422 "unsupported location for server type" error is Hetzner
# telling us "your project can't get this SKU in this DC right now."
#
# Authoritative answer: /v1/datacenters returns per-DC
# .server_types.available — the SKU IDs the DC has live inventory for, for
# this token's project. We resolve $SERVER_TYPE to an id, then find DCs
# where it's in .available.
#
# We then pass `datacenter: "<dc-name>"` (e.g. "nbg1-dc3") on server create
# instead of `location: "<loc>"` — Hetzner accepts both, but datacenter is
# more precise and matches what /datacenters returns.
#
# This block is up here (before firewall + ssh key) so --list-locations is
# a read-only inspection — no side effects to clean up.
# =============================================================================
ST_ID=$(api "${HETZNER_API}/server_types?name=${SERVER_TYPE}" \
  | jq -r '.server_types[0].id // empty')
if [ -z "${ST_ID}" ]; then
  echo "[build] ERROR: no server_type named '${SERVER_TYPE}' in Hetzner catalog." >&2
  exit 1
fi
DC_JSON=$(api "${HETZNER_API}/datacenters?per_page=50")
AVAILABLE_DCS=$(echo "${DC_JSON}" | jq -r --argjson id "${ST_ID}" '
  .datacenters[]
  | select(.server_types.available | index($id))
  | "\(.name)\t\(.location.name)"
')

if [ "${LIST_LOCATIONS}" = "1" ]; then
  echo "Datacenters with ${SERVER_TYPE} in stock right now (this project):"
  if [ -z "${AVAILABLE_DCS}" ]; then
    echo "  (none — every DC is out of stock for ${SERVER_TYPE})"
    echo "  Try a different SERVER_TYPE. SKUs your project can see:"
    echo "${DC_JSON}" | jq -r '[.datacenters[].server_types.available[]] | unique | .[]' \
      | while read -r sid; do
          api "${HETZNER_API}/server_types/${sid}" \
            | jq -r '.server_type | "    \(.name)\t\(.cores) cores / \(.memory)GB / \(.disk)GB"'
        done
  else
    echo "${AVAILABLE_DCS}" | awk '{printf "  %-12s (location: %s)\n", $1, $2}'
  fi
  TEARDOWN=0  # nothing was provisioned; don't try to delete anything
  exit 0
fi

if [ -z "${AVAILABLE_DCS}" ]; then
  echo "[build] ERROR: no datacenter has '${SERVER_TYPE}' in stock for your project right now." >&2
  echo "[build]        Run \`./build.sh --list-locations\` to see SKUs your project can provision." >&2
  echo "[build]        Or override: SERVER_TYPE=cpx31 ./build.sh ..." >&2
  exit 1
fi

# If LOCATION is set, restrict the DC list to that location.
if [ -n "${LOCATION}" ]; then
  FILTERED=$(echo "${AVAILABLE_DCS}" | awk -v loc="${LOCATION}" '$2 == loc {print}')
  if [ -z "${FILTERED}" ]; then
    echo "[build] ERROR: ${SERVER_TYPE} not in stock in location '${LOCATION}' right now." >&2
    echo "[build]        Available DCs for ${SERVER_TYPE}:" >&2
    echo "${AVAILABLE_DCS}" | awk '{printf "  %-12s (location: %s)\n", $1, $2}' >&2
    exit 1
  fi
  AVAILABLE_DCS="${FILTERED}"
fi

# Pick a DC. Prefer EU locations (nbg1/fsn1/hel1) first for lower GHCR egress.
DATACENTER=""
for pref_loc in nbg1 fsn1 hel1 ash hil sin; do
  cand=$(echo "${AVAILABLE_DCS}" | awk -v loc="${pref_loc}" '$2 == loc {print $1; exit}')
  if [ -n "${cand}" ]; then
    DATACENTER="${cand}"
    LOCATION="${pref_loc}"
    break
  fi
done
if [ -z "${DATACENTER}" ]; then
  # Fall back: pick whatever DC came first.
  DATACENTER=$(echo "${AVAILABLE_DCS}" | head -n1 | awk '{print $1}')
  LOCATION=$(echo "${AVAILABLE_DCS}" | head -n1 | awk '{print $2}')
fi
log "Auto-selected DATACENTER=${DATACENTER} (location=${LOCATION})"

# =============================================================================
# 1. Cloud firewall (SSH only inbound, all outbound)
# =============================================================================
log "Configuring firewall '${FIREWALL_NAME}'..."
RULES='{
  "rules": [
    {"direction":"in","protocol":"tcp","port":"22","source_ips":["0.0.0.0/0","::/0"],"description":"SSH"},
    {"direction":"out","protocol":"tcp","port":"1-65535","destination_ips":["0.0.0.0/0","::/0"],"description":"All TCP out"},
    {"direction":"out","protocol":"udp","port":"1-65535","destination_ips":["0.0.0.0/0","::/0"],"description":"All UDP out"}
  ]
}'
FIREWALL_ID=$(api "${HETZNER_API}/firewalls?name=${FIREWALL_NAME}" | jq -r '.firewalls[0].id // empty')
if [ -n "${FIREWALL_ID}" ]; then
  api -X POST -H "Content-Type: application/json" -d "${RULES}" \
    "${HETZNER_API}/firewalls/${FIREWALL_ID}/actions/set_rules" > /dev/null
else
  PAYLOAD=$(echo "${RULES}" | jq --arg name "${FIREWALL_NAME}" '. + {name: $name}')
  FIREWALL_ID=$(api -X POST -H "Content-Type: application/json" -d "${PAYLOAD}" \
    "${HETZNER_API}/firewalls" | jq -r '.firewall.id')
fi
log "Firewall ready: id=${FIREWALL_ID}"

# =============================================================================
# 2. SSH key in Hetzner
# =============================================================================
SSH_KEY_ID=$(api "${HETZNER_API}/ssh_keys?name=${SSH_KEY_NAME}" | jq -r '.ssh_keys[0].id // empty')
if [ -z "${SSH_KEY_ID}" ]; then
  log "Uploading SSH key '${SSH_KEY_NAME}'..."
  SSH_PUB_KEY=$(tr -d '\n' < emudoi_infra_desktop_only.pub)
  SSH_KEY_ID=$(api -X POST -H "Content-Type: application/json" \
    -d "$(jq -n --arg name "${SSH_KEY_NAME}" --arg key "${SSH_PUB_KEY}" '{name:$name,public_key:$key}')" \
    "${HETZNER_API}/ssh_keys" | jq -r '.ssh_key.id')
fi

# =============================================================================
# 3. Server — refuse to clobber an existing build, otherwise create fresh
# =============================================================================
EXISTING=$(api "${HETZNER_API}/servers?name=${NODE_NAME}" | jq -r '.servers[0].id // empty')
if [ -n "${EXISTING}" ]; then
  EXISTING_IP=$(api "${HETZNER_API}/servers/${EXISTING}" | jq -r '.server.public_net.ipv4.ip')
  echo "[build] ERROR: server '${NODE_NAME}' already exists (id=${EXISTING}, ip=${EXISTING_IP})." >&2
  echo "[build]        Another build is probably in flight. Inspect with:" >&2
  echo "[build]          ssh -i ${SSH_KEY} root@${EXISTING_IP} 'journalctl -u emudoi-build -f'" >&2
  echo "[build]        Or force-clean: ./build-down.sh" >&2
  TEARDOWN=0  # don't blow away someone else's running build on exit
  exit 1
fi

log "Creating server '${NODE_NAME}' (${SERVER_TYPE}) in ${DATACENTER}..."
PAYLOAD=$(jq -n \
  --arg name "${NODE_NAME}" \
  --arg server_type "${SERVER_TYPE}" \
  --arg image "${IMAGE}" \
  --arg datacenter "${DATACENTER}" \
  --argjson ssh_key_id "${SSH_KEY_ID}" \
  --argjson firewall_id "${FIREWALL_ID}" \
  '{
    name: $name,
    server_type: $server_type,
    image: $image,
    datacenter: $datacenter,
    ssh_keys: [$ssh_key_id],
    firewalls: [{firewall: $firewall_id}],
    start_after_create: true,
    labels: {app:"emudoi", role:"image-builder", managed:"true"}
  }')
SERVER_ID=$(api -X POST -H "Content-Type: application/json" -d "${PAYLOAD}" \
  "${HETZNER_API}/servers" | jq -r '.server.id')

log "Waiting for server to become running..."
for _ in $(seq 1 60); do
  STATUS=$(api "${HETZNER_API}/servers/${SERVER_ID}" | jq -r '.server.status')
  [ "${STATUS}" = "running" ] && break
  sleep 5
done
[ "${STATUS}" = "running" ] || { echo "[build] ERROR: server did not start" >&2; exit 1; }

SERVER_IP=$(api "${HETZNER_API}/servers/${SERVER_ID}" | jq -r '.server.public_net.ipv4.ip')
log "Server: id=${SERVER_ID} ip=${SERVER_IP}"

# =============================================================================
# 4. Wait for SSH, push remote-build script, kick it via systemd-run
# =============================================================================
log "Waiting for SSH on ${SERVER_IP}..."
for _ in $(seq 1 30); do
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes \
    "root@${SERVER_IP}" 'echo ok' >/dev/null 2>&1 && break
  sleep 5
done

scp "${SSH_OPTS[@]}" Dockerfile scripts/remote-build.sh "root@${SERVER_IP}:/root/"

START_TS=$(date +%s)
MAX_SECS=$(( MAX_BUILD_HOURS * 3600 ))

# Run as a transient systemd unit so an SSH drop doesn't kill the build.
# `--collect` lets systemd garbage-collect the unit after it exits.
log "Starting build on the box (model=${MODEL_NAME}, tag=${IMAGE_TAG})..."
ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" "
  set -e
  apt-get update -qq && apt-get install -y -qq docker.io ca-certificates >/dev/null
  systemctl enable --now docker
  mkdir -p /var/run/emudoi-build
  rm -f /var/run/emudoi-build/done /var/run/emudoi-build/failed
  systemd-run --unit=emudoi-build --collect \
    --setenv=MODEL_NAME='${MODEL_NAME}' \
    --setenv=IMAGE_TAG='${IMAGE_TAG}' \
    --setenv=HF_TOKEN='${HF_TOKEN}' \
    --setenv=GIT_PAT='${GIT_PAT}' \
    bash /root/remote-build.sh
"

# =============================================================================
# 5. Poll loop — every 30s, tail the log, watch for done/failed markers
# =============================================================================
log "Polling for completion (max ${MAX_BUILD_HOURS}h)..."
TAIL_OFFSET=0
while :; do
  ELAPSED=$(( $(date +%s) - START_TS ))
  if [ "${ELAPSED}" -gt "${MAX_SECS}" ]; then
    log "TIMEOUT: ${MAX_BUILD_HOURS}h elapsed — killing the build."
    ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" "systemctl kill emudoi-build || true" >/dev/null 2>&1 || true
    exit 124
  fi

  # Stream any new bytes from the remote log so the user sees progress.
  NEW_OFFSET=$(ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" \
    "wc -c < /var/log/emudoi-build.log 2>/dev/null || echo 0" 2>/dev/null || echo "${TAIL_OFFSET}")
  if [ "${NEW_OFFSET}" -gt "${TAIL_OFFSET}" ]; then
    ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" \
      "tail -c +$((TAIL_OFFSET + 1)) /var/log/emudoi-build.log" 2>/dev/null || true
    TAIL_OFFSET="${NEW_OFFSET}"
  fi

  STATE=$(ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" '
    if [ -f /var/run/emudoi-build/done ]; then echo done;
    elif [ -f /var/run/emudoi-build/failed ]; then echo failed;
    else echo running; fi
  ' 2>/dev/null || echo "running")

  case "${STATE}" in
    done)
      DIGEST=$(ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" "cat /var/run/emudoi-build/done")
      echo
      echo "=============================================================="
      echo "BUILD SUCCEEDED in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
      echo "Image:  ${IMAGE_FULL}"
      echo "Digest: ${DIGEST}"
      echo "=============================================================="
      exit 0
      ;;
    failed)
      RC=$(ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" "cat /var/run/emudoi-build/failed")
      echo
      echo "=============================================================="
      echo "BUILD FAILED (rc=${RC}) after $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
      echo "Last 50 lines of /var/log/emudoi-build.log:"
      echo "--------------------------------------------------------------"
      ssh "${SSH_OPTS[@]}" "root@${SERVER_IP}" "tail -50 /var/log/emudoi-build.log" 2>/dev/null || true
      echo "=============================================================="
      exit "${RC}"
      ;;
  esac

  sleep 30
done
