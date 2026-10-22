import json
import os
import struct
import subprocess
import tempfile
from typing import Dict, Any

MAGIC_HEADER = 0x4E534750


def detect_hardware_resources(config: Dict[str, Any]) -> Dict[str, Any]:
    visible_devices = os.environ.get("CUDA_VISIBLE_DEVICES", "")
    if visible_devices.strip():
        device_count = len([d for d in visible_devices.split(",") if d.strip()])
    else:
        device_count = int(config.get("gpu_count_per_worker", 8))
    return {
        "gpu_model": config.get("gpu_type", "B300"),
        "detected_gpu_count": device_count,
        "reference_h200_count": int(config.get("curriculum_reference_profile", {}).get("gpu_count", 144)),
        "primary_dim": int(config.get("primary_embedding_dim", 4096)),
        "matryoshka_dim": int(config.get("matryoshka_retained_dim", 256)),
    }


def dispatch_binary_workload(payload_bytes: bytes, config: Dict[str, Any]) -> bytes:
    if len(payload_bytes) < 16:
        raise ValueError("Invalid workload frame length")
    magic, version, op_code, body_len = struct.unpack("<IIII", payload_bytes[:16])
    if magic != MAGIC_HEADER:
        raise ValueError("Invalid workload magic")
    body = payload_bytes[16 : 16 + body_len]
    if op_code == 1:
        from modal.embedding_entrypoint import run_embedding_batch
        response_str = run_embedding_batch(body.decode("utf-8"), config)
        response_body = response_str.encode("utf-8")
    elif op_code == 2:
        from modal.training_entrypoint import run_training_job
        response_str = run_training_job(body.decode("utf-8"), config)
        response_body = response_str.encode("utf-8")
    else:
        hw = detect_hardware_resources(config)
        response_body = json.dumps({"status": "ok", "version": version, "hardware": hw}).encode("utf-8")
    header = struct.unpack("<IIII", struct.pack("<IIII", MAGIC_HEADER, version, op_code, len(response_body)))
    return struct.pack("<IIII", *header) + response_body
