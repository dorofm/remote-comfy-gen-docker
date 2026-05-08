#!/bin/bash
set -euo pipefail

# Log forwarding (same as start_script.sh)
if [[ -n "${LOG_RECEIVER_URL:-}" && -z "${_LOG_FORWARDER_ACTIVE:-}" ]]; then
    export _LOG_FORWARDER_ACTIVE=1
    exec > >(python3 /log_forwarder.py) 2>&1
fi

echo "[start_vast] Starting ComfyUI + vast.ai HTTP server..."

VOLUME_PATH="${VOLUME_PATH:-/runpod-volume}"
RUNTIME_DIR="$VOLUME_PATH/runtime"
RUNTIME_REPO_URL="${RUNTIME_REPO_URL:-}"
RUNTIME_REPO_REF="${RUNTIME_REPO_REF:-main}"
GITHUB_PAT="${GITHUB_PAT:-}"

# --- Clone or update runtime repo (same logic as start_script.sh) ---
if [ -n "$RUNTIME_REPO_URL" ]; then
    if [ -n "$GITHUB_PAT" ]; then
        CLONE_URL=$(echo "$RUNTIME_REPO_URL" | sed "s|https://|https://${GITHUB_PAT}@|")
    else
        CLONE_URL="$RUNTIME_REPO_URL"
    fi

    if [ -d "$RUNTIME_DIR/.git" ]; then
        cd "$RUNTIME_DIR"
        git remote set-url origin "$CLONE_URL"
        LOCAL_HASH=$(git rev-parse HEAD 2>/dev/null || echo "none")
        REMOTE_HASH=$(git ls-remote origin "$RUNTIME_REPO_REF" 2>/dev/null | cut -f1 || echo "unknown")
        if [ "$LOCAL_HASH" != "$REMOTE_HASH" ] || [ "$REMOTE_HASH" = "unknown" ]; then
            echo "[start_vast] Pulling runtime repo..."
            git fetch origin
            git reset --hard "origin/$RUNTIME_REPO_REF"
        else
            echo "[start_vast] Runtime already up to date ($LOCAL_HASH)"
        fi
    else
        echo "[start_vast] Cloning runtime repo..."
        git clone --depth 1 --branch "$RUNTIME_REPO_REF" "$CLONE_URL" "$RUNTIME_DIR"
    fi

    # Override VideoX-Fun __init__.py if provided
    if [ -f "$RUNTIME_DIR/vxfun_init.py" ]; then
        cp "$RUNTIME_DIR/vxfun_init.py" /ComfyUI/custom_nodes/VideoX-Fun/__init__.py
    fi
fi

# --- Ensure ultralytics bbox symlink ---
mkdir -p "$VOLUME_PATH/ComfyUI/models/ultralytics/bbox"
if [ -f "$VOLUME_PATH/ComfyUI/models/ultralytics/face_yolov8m.pt" ] && \
   [ ! -f "$VOLUME_PATH/ComfyUI/models/ultralytics/bbox/face_yolov8m.pt" ]; then
    ln -s "$VOLUME_PATH/ComfyUI/models/ultralytics/face_yolov8m.pt" \
          "$VOLUME_PATH/ComfyUI/models/ultralytics/bbox/face_yolov8m.pt"
fi

# --- Start ComfyUI in background ---
echo "[start_vast] Starting ComfyUI..."
mkdir -p "$VOLUME_PATH/ComfyUI/output" "$VOLUME_PATH/ComfyUI/input"

python3 /ComfyUI/main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --extra-model-paths-config /ComfyUI/extra_model_paths.yaml \
    --output-directory "$VOLUME_PATH/ComfyUI/output" \
    --input-directory "$VOLUME_PATH/ComfyUI/input" \
    --disable-auto-launch \
    &

COMFYUI_PID=$!
echo "[start_vast] ComfyUI PID: $COMFYUI_PID"

# --- Start vast HTTP server (blocks, waits for ComfyUI internally) ---
echo "[start_vast] Starting vast_server.py..."
exec python3 /vast_server.py
