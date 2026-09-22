"""Keep comfy-kitchen's flash decode off on PyTorch builds older than CUDA 13.

Managed by the ComfyUI QPKG. Reinstalling the package overwrites this file.

ComfyUI disables the comfy-kitchen CUDA backend when torch.version.cuda is
below 13 (comfy/quant_ops.py), but from v0.37.0 the Qwen text generation path
in comfy/text_encoders/llama.py only asks
comfy_kitchen.flash_attention_decode_is_available() and then launches the
extension kernel anyway. On a driver that stops at CUDA 12.9, which is where
QNAP's NVIDIA GPU Driver package stops, that fails with
  CUDA error: CUDA driver version is insufficient for CUDA runtime version
Upstream supports CUDA 12 only on GPUs that cannot run CUDA 13, so the guard
lives here. llama.py looks the function up at call time, so replacing it at
startup is enough and no upstream file is edited. On a cu130 build this file
does nothing.
"""
import logging

import torch

try:
    import comfy_kitchen
except ImportError:
    comfy_kitchen = None

NODE_CLASS_MAPPINGS = {}


def _cuda_major():
    try:
        return int(str(torch.version.cuda).split(".")[0])
    except (TypeError, ValueError):
        return 0


def _flash_attention_decode_unavailable(device=None):
    return False


if (comfy_kitchen is not None
        and torch.version.cuda is not None
        and _cuda_major() < 13
        and hasattr(comfy_kitchen, "flash_attention_decode_is_available")):
    comfy_kitchen.flash_attention_decode_is_available = _flash_attention_decode_unavailable
    logging.info("qnap_cu12_guard: PyTorch built for CUDA %s, disabling comfy-kitchen flash decode", torch.version.cuda)
