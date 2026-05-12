"""vast.ai serverless worker — FastAPI HTTP server on port 8080.

Receives jobs from vast.ai routing engine, submits to local ComfyUI,
uploads result to S3, returns URL in the same format as RunPod handler.
"""

import json
import os
import time
import urllib.request
import urllib.error
from pathlib import Path

from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse
import uvicorn

COMFYUI_URL = "http://127.0.0.1:8188"
PORT = int(os.environ.get("VAST_SERVER_PORT", "8080"))

app = FastAPI()


# ---------------------------------------------------------------------------
# Health check (vast.ai polls this to know the worker is ready)
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    """Return 200 once ComfyUI is up."""
    try:
        urllib.request.urlopen(f"{COMFYUI_URL}/system_stats", timeout=3)
        return {"status": "ok"}
    except Exception:
        raise HTTPException(status_code=503, detail="ComfyUI not ready")


# ---------------------------------------------------------------------------
# Job handler
# ---------------------------------------------------------------------------

@app.post("/generate/sync")
async def generate(request: Request):
    body = await request.json()

    # vast.ai wraps the payload: {"auth_data": {...}, "payload": {...}}
    # Fall back to body itself if no wrapping (direct test calls)
    inner = body.get("payload", body)
    inp = inner.get("input", inner)

    workflow = inp.get("workflow_json") or inp.get("workflow")
    if not workflow:
        raise HTTPException(status_code=400, detail="Missing workflow_json in input")

    file_inputs = inp.get("file_inputs", {})
    overrides = inp.get("overrides", {})
    timeout = inp.get("timeout", 1200)

    start_t = time.time()

    # --- Download any file_inputs to /tmp and update workflow ---
    for node_id, fi in file_inputs.items():
        url = fi.get("url", "")
        filename = fi.get("filename", Path(url).name)
        field = fi.get("field", "image")
        if url:
            local = f"/tmp/{filename}"
            _download_file(url, local)
            if node_id in workflow and isinstance(workflow[node_id], dict):
                workflow[node_id].setdefault("inputs", {})[field] = local

    # --- Apply overrides ---
    for node_id, params in overrides.items():
        if node_id in workflow and isinstance(workflow[node_id], dict):
            workflow[node_id].setdefault("inputs", {}).update(params)

    # --- Submit to ComfyUI ---
    prompt_id = _comfy_submit(workflow)

    # --- Poll for completion ---
    result_images = _comfy_wait(prompt_id, timeout)

    # --- Upload to S3 ---
    urls = []
    for img_info in result_images:
        img_bytes = _comfy_get_image(img_info["filename"], img_info.get("subfolder", ""))
        if img_bytes:
            s3_url = _s3_upload(img_bytes, img_info["filename"])
            if s3_url:
                urls.append(s3_url)

    elapsed = round(time.time() - start_t)

    if not urls:
        return JSONResponse({"ok": False, "error": "No output images produced"}, status_code=500)

    return {
        "ok": True,
        "output": {
            "url": urls[0],
            "urls": urls,
        },
        "elapsed_seconds": elapsed,
    }


# ---------------------------------------------------------------------------
# ComfyUI helpers
# ---------------------------------------------------------------------------

def _comfy_submit(workflow: dict) -> str:
    data = json.dumps({"prompt": workflow}).encode()
    req = urllib.request.Request(
        f"{COMFYUI_URL}/prompt",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
    prompt_id = resp.get("prompt_id")
    if not prompt_id:
        raise HTTPException(status_code=500, detail=f"ComfyUI /prompt error: {resp}")
    return prompt_id


def _comfy_wait(prompt_id: str, timeout: int) -> list[dict]:
    """Poll /history until the prompt is done. Returns list of image dicts."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(2)
        try:
            req = urllib.request.Request(f"{COMFYUI_URL}/history/{prompt_id}")
            hist = json.loads(urllib.request.urlopen(req, timeout=10).read())
        except Exception:
            continue
        if prompt_id not in hist:
            continue
        entry = hist[prompt_id]
        # Collect all output images
        images = []
        for node_output in entry.get("outputs", {}).values():
            for img in node_output.get("images", []):
                if img.get("type") == "output":
                    images.append(img)
        if images:
            return images
        # Check for error
        status = entry.get("status", {})
        if status.get("completed") and not images:
            raise HTTPException(status_code=500, detail="ComfyUI completed but no output images")
    raise HTTPException(status_code=504, detail=f"ComfyUI timed out after {timeout}s")


def _comfy_get_image(filename: str, subfolder: str = "") -> bytes | None:
    params = f"filename={filename}&type=output"
    if subfolder:
        params += f"&subfolder={subfolder}"
    try:
        return urllib.request.urlopen(f"{COMFYUI_URL}/view?{params}", timeout=30).read()
    except Exception:
        return None


def _download_file(url: str, dest: str) -> None:
    urllib.request.urlretrieve(url, dest)


# ---------------------------------------------------------------------------
# S3 upload
# ---------------------------------------------------------------------------

def _s3_upload(data: bytes, filename: str) -> str | None:
    """Upload image bytes to S3/R2 and return a presigned URL."""
    try:
        import boto3
        from botocore.client import Config

        bucket = os.environ.get("S3_BUCKET", "")
        endpoint = os.environ.get("S3_ENDPOINT_URL", "")
        region = os.environ.get("S3_REGION", "auto")
        key_id = os.environ.get("AWS_ACCESS_KEY_ID", "")
        secret = os.environ.get("AWS_SECRET_ACCESS_KEY", "")

        if not all([bucket, endpoint, key_id, secret]):
            print("[vast_server] S3 not configured — cannot upload")
            return None

        s3 = boto3.client(
            "s3",
            endpoint_url=endpoint,
            aws_access_key_id=key_id,
            aws_secret_access_key=secret,
            region_name=region,
            config=Config(signature_version="s3v4"),
        )

        key = f"comfy-gen/outputs/{Path(filename).stem}_{int(time.time())}{Path(filename).suffix}"
        s3.put_object(Bucket=bucket, Key=key, Body=data, ContentType="image/png")

        url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": bucket, "Key": key},
            ExpiresIn=604800,  # 7 days
        )
        return url
    except Exception as e:
        print(f"[vast_server] S3 upload failed: {e}")
        return None


# ---------------------------------------------------------------------------
# Wait for ComfyUI to be ready before accepting requests
# ---------------------------------------------------------------------------

def _wait_for_comfyui(timeout: int = 300) -> None:
    print("[vast_server] Waiting for ComfyUI...", flush=True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"{COMFYUI_URL}/system_stats", timeout=3)
            print("[vast_server] ComfyUI is ready", flush=True)
            return
        except Exception:
            time.sleep(3)
    raise RuntimeError("ComfyUI did not start within timeout")


if __name__ == "__main__":
    _wait_for_comfyui()
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
