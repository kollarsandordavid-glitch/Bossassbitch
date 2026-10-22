import json
import os
import subprocess
import tempfile
from typing import Dict, Any
from modal.gpu_entrypoint import detect_hardware_resources
from modal.training_entrypoint import resolve_zig_binary


def run_embedding_batch(batch_json: str, config: Dict[str, Any]) -> str:
    batch_spec = json.loads(batch_json)
    hw = detect_hardware_resources(config)
    binary_path = resolve_zig_binary("embedding-client", config)
    with tempfile.NamedTemporaryFile("w+", suffix=".json", delete=False, encoding="utf-8") as req_file:
        req_data = {
            "batch": batch_spec,
            "hardware": hw,
            "primary_dim": int(config.get("primary_embedding_dim", 4096)),
            "matryoshka_dim": int(config.get("matryoshka_retained_dim", 256)),
        }
        json.dump(req_data, req_file)
        req_path = req_file.name
    out_path = req_path + ".out.json"
    try:
        completed = subprocess.run(
            [binary_path, "--mode=modal-embed-batch", f"--input={req_path}", f"--output={out_path}"],
            check=True,
            capture_output=True,
            text=True,
            timeout=300,
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
