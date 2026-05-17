#!/usr/bin/env bash
# Runs ON the Hetzner build box, kicked by build.sh via `systemd-run`.
# Env: MODEL_NAME, IMAGE_TAG, HF_TOKEN, GIT_PAT (all required).
# Writes /var/run/emudoi-build/done (digest) on success, /var/run/emudoi-build/failed (rc) on error.
#
# `-e` matters here — without it, a failing `docker build` left the script
# running, an empty DIGEST got written to the `done` marker, and build.sh's
# poll loop reported "BUILD SUCCEEDED" on a broken image (2026-05-17).
set -euo pipefail

LOG=/var/log/emudoi-build.log
exec > >(tee -a "${LOG}") 2>&1

mkdir -p /var/run/emudoi-build
# Write `failed` on ANY non-zero exit (set -e makes most steps abort the
# script), with the rc captured before the trap body runs anything else.
trap 'rc=$?; if [ "${rc}" -ne 0 ]; then echo "${rc}" > /var/run/emudoi-build/failed; fi' EXIT

: "${MODEL_NAME:?MODEL_NAME required}"
: "${IMAGE_TAG:?IMAGE_TAG required}"
: "${HF_TOKEN:?HF_TOKEN required}"
: "${GIT_PAT:?GIT_PAT required}"

IMAGE_SLUG=$(echo "${MODEL_NAME#*/}" | tr '[:upper:]' '[:lower:]')
IMAGE_FULL="ghcr.io/emudoi/${IMAGE_SLUG}:${IMAGE_TAG}"

echo "=== remote-build.sh start ==="
echo "MODEL_NAME=${MODEL_NAME}"
echo "IMAGE_FULL=${IMAGE_FULL}"
date -u

echo "=== docker login ghcr.io ==="
echo "${GIT_PAT}" | docker login ghcr.io -u emudoi --password-stdin

echo "=== docker build ==="
# Dockerfile + remote-build.sh both land in /root/ via scp.
cd /root
docker build \
  --build-arg MODEL_NAME="${MODEL_NAME}" \
  --build-arg HF_TOKEN="${HF_TOKEN}" \
  -t "${IMAGE_FULL}" \
  -f Dockerfile \
  .

echo "=== docker push ==="
docker push "${IMAGE_FULL}"

echo "=== capture digest ==="
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_FULL}")
if [ -z "${DIGEST}" ] || [ "${DIGEST}" = "<no value>" ]; then
  echo "ERROR: docker inspect returned an empty digest after push — aborting."
  exit 1
fi
# Only mark `done` after every guard passed; failure trap relies on this
# marker being absent to know it's the canonical failure record.
echo "${DIGEST}" > /var/run/emudoi-build/done
echo "DIGEST=${DIGEST}"
echo "=== remote-build.sh done ==="
date -u
