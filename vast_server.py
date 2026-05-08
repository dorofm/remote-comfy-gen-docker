#!/usr/bin/env python3
"""
HTTP server for vast.ai Serverless — replaces RunPod SDK.
Accepts POST / with {"input": {"workflow": {...}, "file_inputs": {...}, "overrides": {...}, "timeout": N}}
Returns {"output": {"url": "...", "resolution": {...}, "model_hashes": {...}}}
"""

import hashlib
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import boto3

COMFYUI_URL = "http://127.0.0.1:8188"
COMFYUI_OUTPUT_DIR = "/ComfyUI/output"
COMFYUI_INPUT_DIR = "/ComfyUI/input"
PORT = int(os.environ.get("SERVER_PORT", "8080"))

S3_BUCKET = os.environ.get("S3_BUCKET", "")
S3_KEY = os.environ.get("AWS_ACCESS_KEY_ID", "")
S3_SECRET = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
S3_ENDPOINT = os.environ.get("S3_ENDPOINT_URL", "")
S3_REGION = os.environ.get("S3_REGION", "auto")


def _s3_client():
    kwargs = {
        "aws_access_key_id": S3_KEY,
        "aws_secret_access_key": S3_SECRET,
        "region_name": S3_REGION,
    }
    if S3_ENDPOINT:
        kwargs["endpoint_url"] = S3_ENDPOINT
    return boto3.client("s3", **kwargs)


def wait_for_comfyui(timeout: int = 300) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{COMFYUI_URL}/system_stats", timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(2)
    return False


def _apply_file_inputs(workflow: dict, file_inputs: dict) -> dict:
    """Download S3-hosted input files to /ComfyUI/input/ and update workflow nodes."""
    os.makedirs(COMFYUI_INPUT_DIR, exist_ok=True)
    for node_id, fi in file_inputs.items():
        if node_id not in workflow:
            continue
        field = fi.get("field", "image")
        filename = fi.get("filename", "input.png")
        url = fi.get("url", "")
        if url:
            dest = f"{COMFYUI_INPUT_DIR}/{filename}"
            if not os.path.exists(dest):
                with urllib.request.urlopen(url, timeout=120) as r:
                    with open(dest, "wb") as f:
                        f.write(r.read())
            workflow[node_id]["inputs"][field] = filename
    return workflow


def _apply_overrides(workflow: dict, overrides: dict) -> dict:
    for node_id, params in overrides.items():
        if node_id in workflow:
            workflow[node_id]["inputs"].update(params)
    return workflow


def _submit_prompt(workflow: dict) -> str:
    payload = json.dumps({"prompt": workflow}).encode()
    req = urllib.request.Request(
        f"{COMFYUI_URL}/prompt",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())["prompt_id"]


def _poll_history(prompt_id: str, timeout: int) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{COMFYUI_URL}/history/{prompt_id}", timeout=10) as r:
                history = json.loads(r.read())
            if prompt_id in history:
                return history[prompt_id]
        except Exception:
            pass
        time.sleep(2)
    raise TimeoutError(f"ComfyUI prompt timed out after {timeout}s")


def _get_output_files(history: dict) -> list[str]:
    files = []
    for node_output in history.get("outputs", {}).values():
        for img in node_output.get("images", []):
            if img.get("type") == "output":
                files.append(img["filename"])
    return files


def _upload_to_s3(filepath: str) -> str:
    if not S3_BUCKET:
        raise RuntimeError("S3_BUCKET not set — cannot upload output")
    with open(filepath, "rb") as f:
        data = f.read()
    md5 = hashlib.md5(data).hexdigest()[:12]
    ext = Path(filepath).suffix or ".png"
    key = f"comfy-gen/outputs/{md5}{ext}"
    s3 = _s3_client()
    s3.put_object(Bucket=S3_BUCKET, Key=key, Body=data)
    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": S3_BUCKET, "Key": key},
        ExpiresIn=604800,
    )
    return url


def process_job(inp: dict) -> dict:
    workflow = dict(inp.get("workflow", {}))
    file_inputs = inp.get("file_inputs", {})
    overrides = inp.get("overrides", {})
    timeout = int(inp.get("timeout", 600))

    if file_inputs:
        workflow = _apply_file_inputs(workflow, file_inputs)
    if overrides:
        workflow = _apply_overrides(workflow, overrides)

    prompt_id = _submit_prompt(workflow)
    print(f"[vast_server] ComfyUI prompt_id: {prompt_id}", flush=True)

    history = _poll_history(prompt_id, timeout)

    files = _get_output_files(history)
    if not files:
        raise RuntimeError("No output images from ComfyUI")

    output_path = f"{COMFYUI_OUTPUT_DIR}/{files[0]}"
    url = _upload_to_s3(output_path)
    print(f"[vast_server] Uploaded: {url[:80]}...", flush=True)

    return {"ok": True, "output": {"url": url}}


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
            inp = data.get("input", data)
            result = process_job(inp)
            self._respond(200, result)
        except Exception as e:
            print(f"[vast_server] ERROR: {e}", flush=True)
            self._respond(500, {"ok": False, "error": str(e)})

    def _respond(self, code: int, body: dict):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(f"[vast_server] {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"[vast_server] Waiting for ComfyUI at {COMFYUI_URL}...", flush=True)
    if not wait_for_comfyui(timeout=300):
        print("[vast_server] ERROR: ComfyUI not ready after 300s", flush=True)
        raise SystemExit(1)
    print(f"[vast_server] ComfyUI ready. Listening on port {PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), _Handler).serve_forever()
