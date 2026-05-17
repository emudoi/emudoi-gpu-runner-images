# Pin to CUDA 12.9 base — matches the driver gate in consumer dstack tasks
# (snelmind summarize task bails on CUDA < 12.9).
FROM nvidia/cuda:12.9.0-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV HF_HOME=/opt/hf-cache
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.11 python3.11-venv python3-pip \
      openssh-client jq curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# Latest vllm + transformers at build time. Pin captured into image tag
# (vllm<version>-cu129) by the dstack task that builds this Dockerfile.
RUN pip install --no-cache-dir \
      "vllm" \
      "transformers" \
      "huggingface_hub[cli]"

# Model name is a build arg. Same Dockerfile bakes any HF model.
# HF_TOKEN is also a build arg, NOT an env var — won't persist into layers.
ARG MODEL_NAME
ARG HF_TOKEN
RUN test -n "${MODEL_NAME}" || (echo "MODEL_NAME build-arg is required" && exit 1)

# Download into the STANDARD huggingface_hub cache layout under $HF_HOME so
# that `vllm serve <repo-id>` at runtime resolves to the cached blobs without
# any network. `huggingface-cli download` was removed in huggingface_hub
# >=0.34 — use `hf download` (its replacement). Without --local-dir the file
# lands at $HF_HOME/hub/models--<org>--<model>/snapshots/<sha>/...
RUN hf download "${MODEL_NAME}" --token "${HF_TOKEN}"

# At runtime the image should NEVER call out to the Hub. Hard-block it.
ENV HF_HUB_OFFLINE=1

# Sanity at build time — fails the build if pip resolved a broken combo
# OR if the model files didn't actually land in the cache.
RUN python3 -c "import vllm; print('vllm', vllm.__version__)"
RUN python3 -c "from huggingface_hub import snapshot_download; \
    p=snapshot_download('${MODEL_NAME}', local_files_only=True); \
    print('cached at', p)"
