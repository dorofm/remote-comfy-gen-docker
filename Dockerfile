FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_PREFER_BINARY=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8

# System deps (libgl1 replaces libgl1-mesa-glx on Ubuntu 24.04)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev python3-pip \
    build-essential gcc g++ ninja-build \
    git git-lfs aria2 ffmpeg wget curl ca-certificates \
    libgl1 libglib2.0-0 libopenblas-dev liblapack-dev \
    && ln -sf /usr/bin/python3.12 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && python3.12 -m venv /opt/venv \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:$PATH"

# ComfyUI + all deps (includes torch, safetensors, transformers, etc.)
# Keep ComfyUI in /ComfyUI (baked into image) for fast cold starts
RUN pip install --upgrade pip setuptools wheel packaging && \
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI && \
    pip install -r /ComfyUI/requirements.txt

# Freeze torch versions to prevent custom node deps from upgrading/downgrading
RUN pip freeze | grep -E "^(torch|torchvision|torchaudio|torchsde)==" > /torch-constraint.txt


# RunPod SDK + runtime deps
RUN pip install runpod boto3 requests websocket-client

# Clone and install all custom nodes (baked for fast cold starts)
# Each node: clone repo, install requirements.txt (constrained to frozen torch),
# run install.py if present. This avoids runtime dep installation.
RUN pip install ultralytics
RUN for repo in \
    https://github.com/ltdrdata/ComfyUI-Manager.git \
    https://github.com/ClownsharkBatwing/RES4LYF.git \
    https://github.com/Fannovel16/comfyui_controlnet_aux.git \
    https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
    https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git \
    https://github.com/kijai/ComfyUI-KJNodes.git \
    https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git \
    https://github.com/rgthree/rgthree-comfy.git; \
  do \
    cd /ComfyUI/custom_nodes; \
    repo_dir=$(basename "$repo" .git); \
    echo "=== Installing $repo_dir ==="; \
    git clone --depth 1 "$repo"; \
    if [ -f "/ComfyUI/custom_nodes/$repo_dir/requirements.txt" ]; then \
      pip install -r "/ComfyUI/custom_nodes/$repo_dir/requirements.txt" \
        --constraint /torch-constraint.txt || \
        echo "WARNING: some deps failed for $repo_dir (continuing)"; \
    fi; \
    if [ -f "/ComfyUI/custom_nodes/$repo_dir/install.py" ]; then \
      cd "/ComfyUI/custom_nodes/$repo_dir" && \
      python install.py || \
        echo "WARNING: install.py failed for $repo_dir (continuing)"; \
    fi; \
  done

# VideoX-Fun: clone, install deps, register as editable package for relative imports,
# then replace __init__.py with a minimal version that only loads z_image nodes
# (the original __init__.py imports CogVideoX/Flux2/Wan which fail without their deps)
RUN cd /ComfyUI/custom_nodes && \
    git clone --depth 1 https://github.com/aigc-apps/VideoX-Fun.git && \
    pip install -r /ComfyUI/custom_nodes/VideoX-Fun/requirements.txt \
        --constraint /torch-constraint.txt || \
        echo "WARNING: some VideoX-Fun deps failed (continuing)" && \
    pip install -e /ComfyUI/custom_nodes/VideoX-Fun/ --constraint /torch-constraint.txt || \
        echo "WARNING: VideoX-Fun editable install failed (continuing)" && \
    touch /ComfyUI/custom_nodes/VideoX-Fun/comfyui/__init__.py && \
    touch /ComfyUI/custom_nodes/VideoX-Fun/comfyui/z_image/__init__.py && \
    touch /ComfyUI/custom_nodes/VideoX-Fun/comfyui/annotator/__init__.py
COPY vxfun_init.py /ComfyUI/custom_nodes/VideoX-Fun/__init__.py

# Verify key imports (fail fast if something is broken)
RUN python3 -c "\
import torch; print(f'PyTorch {torch.__version__}'); \
import safetensors; print(f'safetensors {safetensors.__version__}'); \
import transformers; print(f'transformers {transformers.__version__}'); \
import kornia; print('kornia OK'); \
import spandrel; print('spandrel OK'); \
import videox_fun; print(f'videox_fun OK'); \
import videox_fun.models; print('videox_fun.models OK'); \
"

# qwen3_tokenizer: needed by VideoX-Fun LoadZImageTextEncoderModel
# Search path: folder_paths.models_dir/Fun_Models/qwen3_tokenizer
RUN python3 -c "import transformers; tok = transformers.AutoTokenizer.from_pretrained('Qwen/Qwen3-4B', trust_remote_code=True); tok.save_pretrained('/ComfyUI/models/Fun_Models/qwen3_tokenizer'); print('qwen3_tokenizer saved')"

# CivitAI downloader (uses aria2c which is already installed above)
RUN git clone --depth 1 https://github.com/Hearmeman24/CivitAI_Downloader /tools/civitai-downloader

# extra_model_paths.yaml tells ComfyUI to look at network volume for models
COPY extra_model_paths.yaml /ComfyUI/extra_model_paths.yaml
RUN mkdir -p /ComfyUI/models/ultralytics/bbox && \
    wget -O /ComfyUI/models/ultralytics/bbox/face_yolov8m.pt \
    https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt && \
    ls -lh /ComfyUI/models/ultralytics/bbox/
RUN printf 'import folder_paths\nfor p in ["/ComfyUI/models/ultralytics/bbox", "/runpod-volume/ComfyUI/models/ultralytics/bbox"]:\n    folder_paths.add_model_folder_path("ultralytics_bbox", p)\nNODE_CLASS_MAPPINGS = {}\n' > /ComfyUI/custom_nodes/fix_ultralytics_bbox.py
# VideoX-Fun: LoadZImageControlNetInModel uses "model_patches" folder type,
# but our ControlNet weights live in the "controlnet" folder on the volume.
# Register controlnet paths as additional model_patches search paths.
RUN printf 'import folder_paths\nfor p in ["/ComfyUI/models/controlnet", "/runpod-volume/ComfyUI/models/controlnet"]:\n    folder_paths.add_model_folder_path("model_patches", p)\nNODE_CLASS_MAPPINGS = {}\n' > /ComfyUI/custom_nodes/fix_vxfun_model_patches.py
COPY log_forwarder.py /log_forwarder.py
COPY start_script.sh /start_script.sh
RUN chmod +x /start_script.sh

CMD ["/start_script.sh"]
