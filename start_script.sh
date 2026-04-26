#!/bin/bash
set -euo pipefail

# --- Log forwarding: capture ALL output from the very start ---
# Gracefully no-ops if LOG_RECEIVER_URL is not set.
if [[ -n "${LOG_RECEIVER_URL:-}" && -z "${_LOG_FORWARDER_ACTIVE:-}" ]]; then
    export _LOG_FORWARDER_ACTIVE=1
    exec > >(python3 /log_forwarder.py) 2>&1
fi

echo "[start_script] Starting ComfyUI serverless worker..."

RUNTIME_DIR="/runpod-volume/runtime"
RUNTIME_REPO_URL="${RUNTIME_REPO_URL:-}"
RUNTIME_REPO_REF="${RUNTIME_REPO_REF:-main}"
GITHUB_PAT="${GITHUB_PAT:-}"

# --- Clone or pull runtime repo ---
if [ -z "$RUNTIME_REPO_URL" ]; then
    echo "[start_script] ERROR: RUNTIME_REPO_URL not set"
    exit 1
fi

# Inject PAT into URL if provided
if [ -n "$GITHUB_PAT" ]; then
    CLONE_URL=$(echo "$RUNTIME_REPO_URL" | sed "s|https://|https://${GITHUB_PAT}@|")
else
    CLONE_URL="$RUNTIME_REPO_URL"
fi

if [ -d "$RUNTIME_DIR/.git" ]; then
    cd "$RUNTIME_DIR"
    git remote set-url origin "$CLONE_URL"

    # Skip fetch if already at the latest remote commit
    LOCAL_HASH=$(git rev-parse HEAD 2>/dev/null || echo "none")
    REMOTE_HASH=$(git ls-remote origin "$RUNTIME_REPO_REF" 2>/dev/null | cut -f1 || echo "unknown")

    if [ "$LOCAL_HASH" = "$REMOTE_HASH" ] && [ "$REMOTE_HASH" != "unknown" ]; then
        echo "[start_script] Runtime already at $RUNTIME_REPO_REF ($LOCAL_HASH) — skipping fetch"
    else
        echo "[start_script] Pulling latest runtime code ($LOCAL_HASH -> $REMOTE_HASH)..."
        git fetch origin
        git reset --hard "origin/$RUNTIME_REPO_REF"
    fi
else
    echo "[start_script] Cloning runtime repo..."
    git clone --depth 1 --branch "$RUNTIME_REPO_REF" "$CLONE_URL" "$RUNTIME_DIR"
fi

echo "[start_script] Runtime repo ready at $RUNTIME_DIR (ref: $RUNTIME_REPO_REF)"

# --- Hand off to runtime start.sh ---
# --- Ensure ultralytics bbox symlink ---
mkdir -p /runpod-volume/ComfyUI/models/ultralytics/bbox
if [ -f "/runpod-volume/ComfyUI/models/ultralytics/face_yolov8m.pt" ] && \
   [ ! -f "/runpod-volume/ComfyUI/models/ultralytics/bbox/face_yolov8m.pt" ]; then
    ln -s /runpod-volume/ComfyUI/models/ultralytics/face_yolov8m.pt \
          /runpod-volume/ComfyUI/models/ultralytics/bbox/face_yolov8m.pt
fi
# Patch worker.py: handle prefixed model names like "bbox/face_yolov8m.pt"
WORKER_PY="$RUNTIME_DIR/worker.py"
if [ -f "$WORKER_PY" ]; then
    python3 - "$WORKER_PY" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
new_lines = []
patched = False
for line in lines:
    if 'if filename in files:' in line and '_fn' not in line:
        indent = len(line) - len(line.lstrip())
        new_lines.append(' ' * indent + '_fn = os.path.basename(filename)\n')
        new_lines.append(line.replace('filename', '_fn', 1))
        patched = True
    elif 'path = os.path.join(root, filename)' in line and '_fn' not in line:
        new_lines.append(line.replace('os.path.join(root, filename)', 'os.path.join(root, _fn)'))
        patched = True
    else:
        new_lines.append(line)
if patched:
    with open(path, 'w') as f:
        f.writelines(new_lines)
    print('[patch] worker.py patched OK')
else:
    print('[patch] worker.py: no changes (already patched or not found)')
PYEOF
fi
# --- Override vxfun_init.py from runtime repo if present ---
VXFUN_INIT="/ComfyUI/custom_nodes/VideoX-Fun/__init__.py"
RUNTIME_VXFUN="$RUNTIME_DIR/vxfun_init.py"
if [ -f "$RUNTIME_VXFUN" ]; then
    echo "[start_script] Overriding VideoX-Fun __init__.py from runtime repo..."
    cp "$RUNTIME_VXFUN" "$VXFUN_INIT"
fi


# Patch worker.py: add hf_download command via monkey-patch appended to end of file
if [ -f "$WORKER_PY" ]; then
    python3 - "$WORKER_PY" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

if 'hf_download' in content:
    print('[patch] worker.py: hf_download already present — skipping')
    sys.exit(0)

APPEND = '''

# --- hf_download patch injected by start_script.sh ---
import subprocess as _subprocess, time as _time, os as _os

def _hf_download_handler(job):
    start_t = _time.time()
    inp = job.get("input") or {}
    downloads = inp.get("downloads", [])
    hf_token = inp.get("hf_token", "") or ""
    files = []
    for dl in downloads:
        url = dl["url"]
        dest = dl["dest"]
        filename = dl.get("filename") or url.split("/")[-1].split("?")[0]
        dest_dir = f"/runpod-volume/ComfyUI/models/{dest}"
        _os.makedirs(dest_dir, exist_ok=True)
        dest_path = f"{dest_dir}/{filename}"
        if _os.path.exists(dest_path):
            size_mb = round(_os.path.getsize(dest_path) / (1024 * 1024), 1)
            files.append({"filename": filename, "dest": dest, "path": dest_path, "size_mb": size_mb})
            continue
        headers = [f"--header=Authorization: Bearer {hf_token}"] if (hf_token and "huggingface.co" in url) else []
        cmd = ["aria2c", "-x16", "-s16", "-k1M", "--console-log-level=warn", "--continue=true"] + headers + ["-o", filename, "-d", dest_dir, url]
        result = _subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"aria2c hf_download failed (exit {result.returncode}): {result.stdout}\\n{result.stderr}")
        size_mb = round(_os.path.getsize(dest_path) / (1024 * 1024), 1)
        files.append({"filename": filename, "dest": dest, "path": dest_path, "size_mb": size_mb})
    return {"ok": True, "files": files, "elapsed_seconds": round(_time.time() - start_t)}

_original_handler = handler

def handler(job):
    command = (job.get("input") or {}).get("command", "")
    if command == "hf_download":
        return _hf_download_handler(job)
    return _original_handler(job)
# --- end hf_download patch ---
'''

with open(path, 'a') as f:
    f.write(APPEND)
print('[patch] worker.py: hf_download appended OK')
PYEOF
fi

echo "[start_script] Launching runtime start.sh..."
exec bash "$RUNTIME_DIR/start.sh"
