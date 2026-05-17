"""Airflow DAG — build & push an LLM runner image to GHCR.

Generic builder: takes a HuggingFace model name as a runtime parameter,
clones this repo, runs the dstack build task with the model name passed
through as an env var. The dstack task derives the GHCR image name from
the model name (lowercased, org-prefix stripped) and pushes there.

Manual trigger only — typical cadence is 3-6 builds per year (vllm bumps,
new models, model swaps). To trigger:
  1. Open Airflow UI -> DAGs -> build_llm_runner_image
  2. Click "Trigger DAG w/ config"
  3. Edit `model_name` (default: Qwen/Qwen2.5-7B-Instruct)
  4. Submit

Required Airflow Variables (already configured for snelmind pipeline):
  HF_TOKEN     - HuggingFace token, baked into image at build time
  GIT_PAT      - GitHub PAT with `repo` + `write:packages` scope
  DSTACK_TOKEN - dstack server API token

This DAG lives in `emudoi-gpu-runner-images` (not emudoi-snelmind).
Airflow auto-syncs it because this repo is tagged with the GitHub topic
`emudoi-airflow-dags`. See: emudoi-k3s-ai-infra dags-reconciler-cronjob.
"""

from __future__ import annotations

from datetime import timedelta

import pendulum
from airflow import DAG
from airflow.models.param import Param
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator

DSTACK_RUNNER_IMAGE = "ghcr.io/emudoi/dstacker-runner:main"
BUILD_REPO_DIR = "/tmp/gpu-runner-images"

# Preamble mirrors snelmind_summarize_today.py's pattern: register dstack
# project, clone the dstack task source, dstack init (so dstack uploads it).
# We clone THIS repo because the Dockerfile + dstack task live here.
setup_preamble = (
    "set -e && "
    'dstack project add --name main --url https://dstack.emudoi.com '
    '--token "$DSTACK_TOKEN" -y && '
    f"rm -rf {BUILD_REPO_DIR} && "
    f'git clone "https://${{GIT_PAT}}@github.com/emudoi/emudoi-gpu-runner-images.git" {BUILD_REPO_DIR} && '
    f'cd {BUILD_REPO_DIR} && dstack init --token "$GIT_PAT"'
)

default_args = {
    "owner": "emudoi",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    # Manual-trigger DAG, single retry. If kaniko fails twice, it's a real
    # bug (wrong scopes, broken Dockerfile, bad MODEL_NAME), not transient.
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="build_llm_runner_image",
    default_args=default_args,
    description="Build & push a parameterized LLM runner image to GHCR via dstack+kaniko.",
    schedule=None,  # manual only
    start_date=pendulum.datetime(2026, 5, 17, tz="Europe/Amsterdam"),
    catchup=False,
    tags=["build", "manual", "gpu", "llm"],
    # Parameters appear as editable fields in the "Trigger DAG w/ config" UI.
    params={
        "model_name": Param(
            "Qwen/Qwen2.5-7B-Instruct",
            type="string",
            title="HuggingFace model name",
            description=(
                "Full HF model identifier (e.g. 'Qwen/Qwen2.5-7B-Instruct', "
                "'meta-llama/Llama-3.1-8B-Instruct'). Image will be pushed to "
                "ghcr.io/emudoi/<lowercase-model-name>:<image_tag>."
            ),
        ),
        "image_tag": Param(
            "latest",
            type="string",
            title="GHCR image tag",
            description="Tag to push as. Defaults to 'latest'. Use a vllm-version tag for reproducibility.",
        ),
    },
) as dag:

    build_image = KubernetesPodOperator(
        task_id="dstack_build_llm_runner",
        name="build-llm-runner-image",
        image=DSTACK_RUNNER_IMAGE,
        image_pull_policy="Always",
        cmds=["bash", "-c"],
        arguments=[
            setup_preamble + " && "
            "dstack apply -y --force --project main "
            "-f dstack/build.dstack.yml "
            '--env HF_TOKEN="$HF_TOKEN" '
            '--env GIT_PAT="$GIT_PAT" '
            '--env MODEL_NAME="$MODEL_NAME" '
            '--env IMAGE_TAG="$IMAGE_TAG"'
        ],
        env_vars={
            "DSTACK_TOKEN": "{{ var.value.DSTACK_TOKEN }}",
            "GIT_PAT": "{{ var.value.GIT_PAT }}",
            "HF_TOKEN": "{{ var.value.HF_TOKEN }}",
            # Pull from DAG run params (set at trigger time via UI).
            "MODEL_NAME": "{{ params.model_name }}",
            "IMAGE_TAG": "{{ params.image_tag }}",
        },
        is_delete_operator_pod=True,
        execution_timeout=timedelta(hours=3),
    )
