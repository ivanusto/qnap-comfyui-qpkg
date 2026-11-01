"""Keep comfy-kitchen's CUDA extension off on PyTorch builds older than CUDA 13.

Managed by the ComfyUI QPKG. Reinstalling the package overwrites this file.

The comfy-kitchen wheels ship a CUDA extension built for CUDA 13. It imports
fine under a cu128 PyTorch, but its kernels cannot launch on a driver that
stops at CUDA 12.9, which is where QNAP's NVIDIA GPU Driver package stops.
ComfyUI disables the comfy-kitchen CUDA backend in its own dispatch when
torch.version.cuda is below 13 (comfy/quant_ops.py), but several model paths
call the extension directly and only ask comfy-kitchen whether it is there:

- v0.37.0 and later, Qwen text generation in comfy/text_encoders/llama.py asks
  comfy_kitchen.flash_attention_decode_is_available() and fails with
    CUDA error: CUDA driver version is insufficient for CUDA runtime version
- Qwen3.5 text generation in comfy/text_encoders/qwen35.py (for example the
  FLUX 3 prompt upsampler) calls the deferred DeltaNet decode kernels, which
  fail with
    RuntimeError: deltanet_conv_step_deferred launch rejected

Every one of those checks reads comfy_kitchen.backends.cuda._EXT_AVAILABLE at
call time, so setting it to False at startup sends them all to comfy-kitchen's
torch fallbacks, including call sites added by later releases. The flash
decode check is also replaced directly, as before. Upstream supports CUDA 12
only on GPUs that cannot run CUDA 13, so the guard lives here and no upstream
file is edited. On a cu130 build this file does nothing.
"""
import logging

import torch

try:
    import comfy_kitchen
except ImportError:
    comfy_kitchen = None

try:
    from comfy_kitchen.backends import cuda as _kitchen_cuda
except ImportError:
    _kitchen_cuda = None

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
        and _cuda_major() < 13):
    if hasattr(comfy_kitchen, "flash_attention_decode_is_available"):
        comfy_kitchen.flash_attention_decode_is_available = _flash_attention_decode_unavailable
    if _kitchen_cuda is not None and getattr(_kitchen_cuda, "_EXT_AVAILABLE", False):
        _kitchen_cuda._EXT_AVAILABLE = False
    logging.info("qnap_cu12_guard: PyTorch built for CUDA %s, disabling the comfy-kitchen CUDA extension", torch.version.cuda)
