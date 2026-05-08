#!/bin/bash
# RunPod Volume Download Script
# Run inside a RunPod pod with /runpod-volume mounted.
#
# Usage:
#   CIVITAI_API_KEY=your_token_here bash download_volume.sh

set -e

BASE=/runpod-volume/ComfyUI/models
CIVITAI_TOKEN="${CIVITAI_API_KEY:-}"
TMP=/tmp/vol_downloads

if [ -z "$CIVITAI_TOKEN" ]; then
    echo "WARNING: CIVITAI_API_KEY not set — CivitAI downloads will fail"
fi

A2C="aria2c -x16 -s16 -k1M --continue=true --console-log-level=warn"

hf() {
    local url="$1" dir="$2" name="$3"
    [ -f "$dir/$name" ] && echo "  SKIP $name (exists)" && return
    $A2C --dir="$dir" --out="$name" "$url"
}

civitai() {
    local version_id="$1" dir="$2" name="$3"
    [ -f "$dir/$name" ] && echo "  SKIP $name (exists)" && return
    $A2C --header="Authorization: Bearer ${CIVITAI_TOKEN}" \
         --dir="$dir" --out="$name" \
         "https://civitai.com/api/download/models/${version_id}"
}

civitai_zip() {
    local version_id="$1" dir="$2" pt_name="$3"
    [ -f "$dir/$pt_name" ] && echo "  SKIP $pt_name (exists)" && return
    mkdir -p "$TMP"
    $A2C --header="Authorization: Bearer ${CIVITAI_TOKEN}" \
         --dir="$TMP" --out="${pt_name}.zip" \
         "https://civitai.com/api/download/models/${version_id}"
    unzip -o "$TMP/${pt_name}.zip" "*.pt" -d "$TMP/extracted/" 2>/dev/null || \
    unzip -o "$TMP/${pt_name}.zip" -d "$TMP/extracted/"
    find "$TMP/extracted" -name "*.pt" | head -1 | xargs -I{} cp {} "$dir/$pt_name"
    rm -rf "$TMP/${pt_name}.zip" "$TMP/extracted"
    echo "  OK $pt_name"
}

echo "=== Creating directory structure ==="
mkdir -p $BASE/diffusion_models
mkdir -p $BASE/text_encoders
mkdir -p $BASE/vae
mkdir -p $BASE/loras
mkdir -p $BASE/model_patches
mkdir -p $BASE/ultralytics/bbox

# ─────────────────────────────────────────────
# CORE MODELS  (f5aiteam/Z-Image)
# ─────────────────────────────────────────────

echo "=== Z-Image Turbo BF16 (12.3 GB) ==="
hf "https://huggingface.co/f5aiteam/Z-Image/resolve/main/z_image_turbo_bf16.safetensors" \
   "$BASE/diffusion_models" "z_image_turbo_bf16.safetensors"

echo "=== Qwen3-4B text encoder (8 GB) ==="
hf "https://huggingface.co/f5aiteam/Z-Image/resolve/main/qwen_3_4b.safetensors" \
   "$BASE/text_encoders" "qwen_3_4b.safetensors"

echo "=== VAE (335 MB) ==="
hf "https://huggingface.co/f5aiteam/Z-Image/resolve/main/ae.safetensors" \
   "$BASE/vae" "ae.safetensors"

echo "=== Z-Image ControlNet Union 2.1 (6.4 GB) ==="
hf "https://huggingface.co/alibaba-pai/Z-Image-Turbo-Fun-Controlnet-Union-2.1/resolve/main/Z-Image-Turbo-Fun-Controlnet-Union-2.1.safetensors" \
   "$BASE/model_patches" "Z-Image-Turbo-Fun-Controlnet-Union-2.1.safetensors"

# ─────────────────────────────────────────────
# CHARACTER LoRA
# ─────────────────────────────────────────────

echo "=== anna_zit LoRA ==="
hf "https://huggingface.co/kaspbss/anna001/resolve/main/annaface001_zit/zit_lora_000002250.safetensors" \
   "$BASE/loras" "anna_zit.safetensors"

# ─────────────────────────────────────────────
# NSFW LoRAs
# ─────────────────────────────────────────────

echo "=== Mystic-XXX-ZIT-V7 LoRA (CivitAI v2855359) ==="
civitai "2855359" "$BASE/loras" "Mystic-XXX-ZIT-V7.safetensors"

echo "=== Detailed_Nipples_Z LoRA (CivitAI v2454851) ==="
civitai "2454851" "$BASE/loras" "Detailed_Nipples_Z.safetensors"

echo "=== pussy-zimage-v1 LoRA (HuggingFace Sentinel7) ==="
hf "https://huggingface.co/Sentinel7/z-image/resolve/main/2205140/2486059/pussy-zimage-v1_000026000.safetensors" \
   "$BASE/loras" "pussy-zimage-v1_000026000.safetensors"

echo "=== TurboPussyZ_v2 LoRA (HuggingFace Sentinel7) ==="
hf "https://huggingface.co/Sentinel7/z-image/resolve/ad8de65702b23756cd1f9d3a1b23c022b7f09a71/2178383/2639284/TurboPussyZ_v2.safetensors" \
   "$BASE/loras" "TurboPussyZ_v2.safetensors"

# ─────────────────────────────────────────────
# BBOX DETECTORS
# ─────────────────────────────────────────────

echo "=== face_yolov8m.pt ==="
hf "https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt" \
   "$BASE/ultralytics/bbox" "face_yolov8m.pt"

echo "=== pussyV2.pt (CivitAI v149617, zip) ==="
civitai_zip "149617" "$BASE/ultralytics/bbox" "pussyV2.pt"

echo "=== nipples.pt (CivitAI v149588, zip) ==="
civitai_zip "149588" "$BASE/ultralytics/bbox" "nipples.pt"

# ─────────────────────────────────────────────
# OPTIONAL: SeedVR2 (currently unused)
# ─────────────────────────────────────────────
# Uncomment to download (~3-4 GB):
# mkdir -p $BASE/SEEDVR2
# hf "FILL_URL" "$BASE/SEEDVR2" "seedvr2_ema_3b_fp8_e4m3fn.safetensors"
# hf "FILL_URL" "$BASE/SEEDVR2" "ema_vae_fp16.safetensors"

# ─────────────────────────────────────────────

rm -rf "$TMP"

echo ""
echo "=== Files downloaded ==="
for dir in diffusion_models text_encoders vae model_patches loras ultralytics/bbox; do
    echo "[$dir]"
    ls -lh $BASE/$dir/ 2>/dev/null || echo "  (empty)"
    echo ""
done
du -sh $BASE
echo "=== Done ==="
