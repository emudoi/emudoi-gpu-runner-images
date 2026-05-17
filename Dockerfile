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
RUN huggingface-cli download "${MODEL_NAME}" \
      --local-dir "/opt/hf-cache/models--$(echo ${MODEL_NAME} | sed 's|/|--|g')" \
      --token "${HF_TOKEN}"

# Sanity at build time — fails the build if pip resolved a broken combo.
RUN python3 -c "import vllm; print('vllm', vllm.__version__)"
