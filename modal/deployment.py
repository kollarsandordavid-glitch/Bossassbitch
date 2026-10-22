import json
import os
import subprocess
import pathlib
import modal

CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "modal_config.json"
with open(CONFIG_PATH, "r", encoding="utf-8") as cfg_file:
    MODAL_CFG = json.load(cfg_file)

app = modal.App(MODAL_CFG["app_name"])

checkpoint_volume = modal.Volume.from_name(
    "neural-search-checkpoints-vol",
    create_if_missing=True,
)

artifact_volume = modal.Volume.from_name(
    "neural-search-artifacts-vol",
    create_if_missing=True,
)

b300_image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("ca-certificates", "curl", "xz-utils")
    .run_commands(
        "mkdir -p /opt/zig /opt/neural_search/bin",
        "curl -sL https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz | tar -xJ -C /opt/zig --strip-components=1",
    )
    .copy_local_dir(".", "/opt/neural_search/src_tree")
    .run_commands(
        "cd /opt/neural_search/src_tree && /opt/zig/zig build -Doptimize=ReleaseFast --prefix /opt/neural_search"
    )
)

GPU_SPEC = f"{MODAL_CFG['gpu_type']}:{MODAL_CFG['gpu_count_per_worker']}"


@app.function(
    image=b300_image,
    gpu=GPU_SPEC,
    volumes={
        MODAL_CFG["volumes"]["checkpoints"]: checkpoint_volume,
        MODAL_CFG["volumes"]["artifacts"]: artifact_volume,
    },
    timeout=MODAL_CFG["timeout_seconds"],
    concurrency_limit=MODAL_CFG["max_containers"],
)
def execute_gpu_workload(payload_bytes: bytes) -> bytes:
    from modal.gpu_entrypoint import dispatch_binary_workload
    result = dispatch_binary_workload(payload_bytes, MODAL_CFG)
    checkpoint_volume.commit()
    artifact_volume.commit()
    return result


@app.function(
    image=b300_image,
    gpu=GPU_SPEC,
    volumes={
        MODAL_CFG["volumes"]["checkpoints"]: checkpoint_volume,
        MODAL_CFG["volumes"]["artifacts"]: artifact_volume,
    },
    timeout=MODAL_CFG["timeout_seconds"],
)
def execute_training_stage(job_json: str) -> str:
    from modal.training_entrypoint import run_training_job
    output = run_training_job(job_json, MODAL_CFG)
    checkpoint_volume.commit()
    artifact_volume.commit()
    return output


@app.function(
    image=b300_image,
    gpu=GPU_SPEC,
    volumes={
        MODAL_CFG["volumes"]["checkpoints"]: checkpoint_volume,
        MODAL_CFG["volumes"]["artifacts"]: artifact_volume,
    },
    timeout=600,
)
def execute_embedding_batch(batch_json: str) -> str:
    from modal.embedding_entrypoint import run_embedding_batch
    return run_embedding_batch(batch_json, MODAL_CFG)
