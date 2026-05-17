# emudoi-gpu-runner-images

Generic factory for GPU-baked LLM serving images. One Dockerfile,
one dstack build task, one Airflow DAG — parameterized by model name.

## How it works

Trigger the `build_llm_runner_image` DAG in Airflow:
- Click "Trigger DAG w/ config"
- Set `model_name` (default: `Qwen/Qwen2.5-7B-Instruct`)
- Submit

The DAG runs a dstack task (kaniko-based, on Runpod) that:
1. Downloads the model weights from HuggingFace
2. Bakes them into an image with vLLM + CUDA 12.9 runtime
3. Pushes to `ghcr.io/emudoi/<model-slug>:vllm<version>-cu129`

The image slug is derived from the model name: `Qwen/Qwen2.5-7B-Instruct`
becomes `qwen2.5-7b-instruct`.

## Existing images

| Model | GHCR image | Consumer |
|---|---|---|
| Qwen/Qwen2.5-7B-Instruct | ghcr.io/emudoi/qwen2.5-7b-instruct | emudoi-snelmind summarize pipeline |

## Requirements

- Airflow Variables (already configured): `HF_TOKEN`, `GIT_PAT`, `DSTACK_TOKEN`
- `GIT_PAT` must have `repo` + `write:packages` scopes
- This repo must have GitHub topic `emudoi-airflow-dags` for Airflow auto-sync

## Rebuild cadence

Manual trigger only — typically 3-6×/year (vllm bumps, new models).
Cost per build: ~$0.50-2.00.
