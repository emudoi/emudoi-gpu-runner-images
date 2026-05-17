# emudoi-gpu-runner-images

Generic factory for GPU-baked LLM serving images. One Dockerfile, one shell
script — pass a HuggingFace model name in, get back a GHCR image with the
weights + vLLM + CUDA 12.9 runtime baked in.

## How it works

```bash
./build.sh                                          # interactive (prompts for model)
./build.sh --model Qwen/Qwen2.5-7B-Instruct
./build.sh --model meta-llama/Llama-3.1-8B-Instruct --tag vllm0.10
```

The script:

1. Provisions a fresh Hetzner Cloud VM (`cpx41`, auto-picked DC, ~€0.07/h)
2. Installs Docker on it
3. Runs `docker build` with `MODEL_NAME` + `HF_TOKEN` as build-args
4. Pushes the resulting image to `ghcr.io/emudoi/<model-slug>:<tag>`
5. Tears the VM down — even if the build fails, even if it hits the 3h cap

The image slug is derived from the model name: `Qwen/Qwen2.5-7B-Instruct` →
`qwen2.5-7b-instruct`.

## Prerequisites

1. Copy the SSH key in from `emudoi-desktop-infra`:
   ```bash
   cp ../emudoi-desktop-infra/emudoi_infra_desktop_only ./
   ```
   (Gitignored — same key the dev-desktops use.)

2. Have three credentials ready (first run prompts and caches under
   `~/.config/emudoi/`; subsequent runs reuse the cache):

   | Var             | Required? | Where to get it                                |
   |-----------------|-----------|------------------------------------------------|
   | `HETZNER_TOKEN` | yes       | Hetzner Cloud console → API tokens             |
   | `GIT_PAT`       | yes       | github.com/settings/tokens — scope: `repo` (used for `git clone` on the box) |
   | `GHCR_PAT`      | optional  | Second GitHub PAT used for `docker push` to GHCR — scope: `write:packages`. Leave blank to reuse `GIT_PAT`. |
   | `HF_TOKEN`      | yes       | huggingface.co/settings/tokens                 |

   The script validates each token up front before touching Hetzner, so a
   bad scope never costs you a wasted build. On failure it prints the
   exact cache file to delete to re-prompt with a fresh value.

3. Local tools: `curl`, `jq`, `ssh`, `scp` (all standard).

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--model <name>` | prompt (default `Qwen/Qwen2.5-7B-Instruct`) | HF model to bake |
| `--tag <tag>` | `latest` | GHCR image tag |
| `--no-teardown` | off | Leave the box up after the build (debugging) |
| `--list-locations` | off | Print which DCs sell the chosen `SERVER_TYPE`, then exit |

Optional env overrides: `NODE_NAME`, `SERVER_TYPE`, `LOCATION`, `MAX_BUILD_HOURS`.

## Existing images

| Model | GHCR image | Consumer |
|---|---|---|
| Qwen/Qwen2.5-7B-Instruct | `ghcr.io/emudoi/qwen2.5-7b-instruct` | emudoi-snelmind summarize pipeline |

## Post-build (first time per model)

The first push of any new model creates a private GHCR package. Flip to public:

```bash
gh api -X PATCH /orgs/emudoi/packages/container/<slug>/visibility -f visibility=public
```

## Recovery

If `build.sh` crashes or you Ctrl+C it without teardown, clean up manually:

```bash
./build-down.sh
```
