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
