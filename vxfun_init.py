import os
import folder_paths
from . import comfyui as _comfyui_pkg
from .comfyui import comfyui_utils as _vxfun_utils

# Patch search functions to also look at the RunPod volume path.
# Original code only checks folder_paths.models_dir (/ComfyUI/models/),
# but our models live on /runpod-volume/ComfyUI/models/.
_VOLUME_MODELS = "/runpod-volume/ComfyUI/models"
_orig_search_sub_dir = _vxfun_utils.search_sub_dir_in_possible_folders
_orig_search_model = _vxfun_utils.search_model_in_possible_folders


def _patched_search_sub_dir(possible_folders, sub_dir_name):
    try:
        return _orig_search_sub_dir(possible_folders, sub_dir_name)
    except ValueError:
        pass
    for folder in possible_folders:
        candidate = os.path.join(_VOLUME_MODELS, folder, sub_dir_name)
        if os.path.exists(candidate):
            return candidate
    # Also check directly under volume models_dir subdirs
    candidate = os.path.join(_VOLUME_MODELS, sub_dir_name)
    if os.path.exists(candidate):
        return candidate
    raise ValueError(f"Please download Fun model (searched in {_VOLUME_MODELS})")


def _patched_search_model(possible_folders, model):
    try:
        return _orig_search_model(possible_folders, model)
    except ValueError:
        pass
    for folder in possible_folders:
        candidate = os.path.join(_VOLUME_MODELS, folder, model)
        if os.path.exists(candidate):
            return candidate
    raise ValueError(f"Please download Fun model (searched in {_VOLUME_MODELS})")


_vxfun_utils.search_sub_dir_in_possible_folders = _patched_search_sub_dir
_vxfun_utils.search_model_in_possible_folders = _patched_search_model


from .comfyui.z_image.nodes import (
    LoadZImageLora,
    LoadZImageTextEncoderModel,
    LoadZImageTransformerModel,
    LoadZImageVAEModel,
    CombineZImagePipeline,
    LoadZImageControlNetInPipeline,
    LoadZImageControlNetInModel,
    LoadZImageModel,
    ZImageT2ISampler,
    ZImageControlSampler,
)
from .comfyui.annotator.nodes import ImageToCanny, ImageToPose, ImageToDepth


class FunTextBox:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"prompt": ("STRING", {"multiline": True, "default": ""})}}
    RETURN_TYPES = ("STRING_PROMPT",)
    FUNCTION = "run"
    CATEGORY = "VideoX-Fun"

    def run(self, prompt):
        return (prompt,)


NODE_CLASS_MAPPINGS = {
    "LoadZImageLora": LoadZImageLora,
    "LoadZImageTextEncoderModel": LoadZImageTextEncoderModel,
    "LoadZImageTransformerModel": LoadZImageTransformerModel,
    "LoadZImageVAEModel": LoadZImageVAEModel,
    "CombineZImagePipeline": CombineZImagePipeline,
    "LoadZImageControlNetInPipeline": LoadZImageControlNetInPipeline,
    "LoadZImageControlNetInModel": LoadZImageControlNetInModel,
    "LoadZImageModel": LoadZImageModel,
    "ZImageT2ISampler": ZImageT2ISampler,
    "ZImageControlSampler": ZImageControlSampler,
    "ImageToCanny": ImageToCanny,
    "ImageToPose": ImageToPose,
    "ImageToDepth": ImageToDepth,
    "FunTextBox": FunTextBox,
}

NODE_DISPLAY_NAME_MAPPINGS = {k: k for k in NODE_CLASS_MAPPINGS}

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
