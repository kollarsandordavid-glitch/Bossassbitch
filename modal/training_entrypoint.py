import json
import os
import subprocess
import tempfile
from typing import Dict, Any
from modal.gpu_entrypoint import detect_hardware_resources


def resolve_zig_binary(binary_name: str, config: Dict[str, Any]) -> str:
    configured_dir = config.get("zig_binary_dir", "/opt/neural_search/bin")
    candidate = os.path.join(configured_dir, binary_name)
    if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        return candidate
    local_candidate = os.path.abspath(os.path.join("zig-out", "bin", binary_name))
    if os.path.isfile(local_candidate) and os.access(local_candidate, os.X_OK):
        return local_candidate
    raise FileNotFoundError(f"Executable not found: {binary_name}")


def run_training_job(job_json: str, config: Dict[str, Any]) -> str:
    job_spec = json.loads(job_json)
    hw = detect_hardware_resources(config)
    binary_path = resolve_zig_binary("training-coordinator", config)
    with tempfile.NamedTemporaryFile("w+", suffix=".json", delete=False, encoding="utf-8") as req_file:
        req_Data = {
            "job": job_spec,
            "hardware": hw,
            "checkpoint_dir": config.get("volumes", {}).get("checkpoints", "./var/lib/neural_search/checkpoints"),
        }
        json.dump(req_Data, req_file)
        req_path = req_file.name
    out_path = req_path + ".out.json"
    try:
        completed = subprocess.run(
            [binary_path, "--mode=modal-train-step", f"--input={req_path}", f"--output={out_path}"],
            check=True,
            capture_output=True,
            text=True,
            timeout=int(config.get("timeout_seconds", 3600)),
        )
        if os.path.isfile(out_path):
            with open(out_path, "r", encoding="utf-8") as result_file:
                return result_file.read()
        return json.dumps({
            "status": "completed",
            "stdout": completed.stdout,
            "hardware": hw,
        })
    finally:
        if os.path.exists(req_path):
            os.unlink(req_path)
        if os.path.exists(out_path):
            os.unlink(out_path)
