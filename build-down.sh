#!/usr/bin/env bash
# =============================================================================
# emudoi - Tear down the image-builder Hetzner node and its firewall.
#
# build.sh tears down automatically on exit, so this is an escape hatch for:
#  - Ctrl+C'd or crashed build.sh that left the server up
#  - --no-teardown runs you want to clean up later
#
# Required env: HETZNER_TOKEN  (cached at ~/.config/emudoi/hetzner-token)
# Optional env: NODE_NAME      (default: emudoi-image-builder)
# =============================================================================
set -euo pipefail

HETZNER_API="https://api.hetzner.cloud/v1"
NODE_NAME="${NODE_NAME:-emudoi-image-builder}"
FIREWALL_NAME="${NODE_NAME}-firewall"
CACHE_DIR="${HOME}/.config/emudoi"

for cmd in curl jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "[build-down] ERROR: '${cmd}' is required but not installed." >&2
    exit 1
  }
done

if [ -z "${HETZNER_TOKEN:-}" ] && [ -f "${CACHE_DIR}/hetzner-token" ]; then
  HETZNER_TOKEN=$(cat "${CACHE_DIR}/hetzner-token")
fi
if [ -z "${HETZNER_TOKEN:-}" ]; then
  printf "Hetzner Cloud API token: "
  IFS= read -rs HETZNER_TOKEN
  echo
  [ -n "${HETZNER_TOKEN}" ] || { echo "[build-down] ERROR: empty token" >&2; exit 1; }
fi
export HETZNER_TOKEN

log() { echo "[build-down] $*"; }

api() {
  local resp http_code body
  resp=$(curl -s -w '\n%{http_code}' \
    -H "Authorization: Bearer ${HETZNER_TOKEN}" \
    "$@")
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [ "${http_code:0:1}" != "2" ] && [ "${http_code}" != "404" ]; then
    {
      echo "[build-down] ERROR: Hetzner API returned HTTP ${http_code}"
      echo "[build-down]        Request: $*"
      [ -n "${body}" ] && (echo "${body}" | jq . 2>/dev/null || echo "${body}")
    } >&2
    exit 1
  fi
  printf '%s' "${body}"
}

SERVER_ID=$(api "${HETZNER_API}/servers?name=${NODE_NAME}" | jq -r '.servers[0].id // empty')
if [ -n "${SERVER_ID}" ]; then
  log "Deleting server '${NODE_NAME}' (id=${SERVER_ID})..."
  curl -sf -X DELETE -H "Authorization: Bearer ${HETZNER_TOKEN}" \
    "${HETZNER_API}/servers/${SERVER_ID}" > /dev/null || true
else
  log "No server '${NODE_NAME}' found."
fi

FIREWALL_ID=$(api "${HETZNER_API}/firewalls?name=${FIREWALL_NAME}" | jq -r '.firewalls[0].id // empty')
if [ -n "${FIREWALL_ID}" ]; then
  log "Deleting firewall '${FIREWALL_NAME}' (id=${FIREWALL_ID})..."
  curl -sf -X DELETE -H "Authorization: Bearer ${HETZNER_TOKEN}" \
    "${HETZNER_API}/firewalls/${FIREWALL_ID}" > /dev/null || true
fi

log "Done."
