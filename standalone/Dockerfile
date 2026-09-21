# syntax=docker/dockerfile:1
#
# Standalone ComfyUI image for QNAP Container Station's "Create Application".
#
# This file is deliberately self contained: it copies nothing from the build
# context, so it can be built straight from a URL with no files on the NAS.
#
# Differences from the QPKG variant one directory over:
#   - ComfyUI's source is baked into the image rather than bind mounted, because
#     there is no install hook to fetch it. Upgrading means rebuilding.
#   - kornia_rs is pinned unconditionally rather than only on CPUs without AVX2.
#     The build still happens on your own NAS so a conditional would work, but
#     an unconditional pin keeps the image identical everywhere and costs
#     nothing: kornia_rs is only used for image IO.
#   - The entrypoint seeds a default extra_model_paths.yaml into /config on
#     first run, because bind mounting a file that does not exist yet makes
#     Docker create a directory in its place and the container then fails.
FROM python:3.12-slim-bookworm

ARG COMFY_REF=v0.36.0
# These must match the CUDA version your NVIDIA driver reports. Check with
# nvidia-smi and see the table in the project README.
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu128
ARG TORCH_VERSION=2.9.1+cu128
ARG TORCHVISION_VERSION=0.24.1+cu128
ARG TORCHAUDIO_VERSION=2.9.1+cu128

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl tini \
        libgl1 libglib2.0-0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv

# All three have to be pinned together. Pinning only torch lets pip resolve an
# incompatible torchaudio, which fails at import with
#   undefined symbol: torch_library_impl
# and not during pip install.
RUN pip install --no-cache-dir --index-url "${TORCH_INDEX}" \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}"

# ComfyUI source goes into the image here.
RUN curl -fsSL "https://codeload.github.com/comfyanonymous/ComfyUI/tar.gz/refs/tags/${COMFY_REF}" \
        -o /tmp/comfyui.tar.gz \
    && mkdir -p /opt/ComfyUI \
    && tar -xzf /tmp/comfyui.tar.gz --strip-components=1 -C /opt/ComfyUI \
    && rm -f /tmp/comfyui.tar.gz \
    && mkdir -p /opt/defaults/custom_nodes \
    && cp /opt/ComfyUI/custom_nodes/* /opt/defaults/custom_nodes/ 2>/dev/null || true

# Strip the torch trio so pip does not reinstall them from the default index and
# silently replace the pinned CUDA builds. Keep comfy-aimdo and comfy-kitchen:
# they are genuine upstream dependencies and comfy-aimdo implements DynamicVRAM,
# which is what lets a model larger than your VRAM run at all.
RUN grep -vE '^(torch|torchvision|torchaudio)([=<>!~[]|$)' /opt/ComfyUI/requirements.txt > /tmp/req.txt \
    && pip install --no-cache-dir -r /tmp/req.txt \
    && python -c "import comfy_aimdo.control, comfy_kitchen; print('aimdo/kitchen import OK')"

# kornia_rs 0.1.13 and newer will not run on CPUs without AVX2, such as the
# low-power parts QNAP uses in several models. The failure is a fatal Illegal instruction
# reported against an unrelated file, with no warning from pip.
RUN pip install --no-cache-dir "kornia_rs==0.1.10" \
    && python -c "import kornia, kornia_rs; print('kornia', kornia.__version__, 'with kornia_rs', kornia_rs.__version__, 'OK')"

COPY <<'YAML' /opt/defaults/extra_model_paths.yaml
# Extra model search paths. Edit the copy in your /config directory, not this
# one, and restart the container.
#
# Container mount points:
#   /models/public  read only, your shared model folder
#   /models/local   writable, for models you download from inside
#
# Four behaviours of folder_paths.py that are not documented and will silently
# change which weights load:
#
# 1. diffusion_models already searches both models/diffusion_models and
#    models/unet by default.
# 2. text_encoders is bound to both models/text_encoders and models/clip, and
#    map_legacy maps the "clip" key onto "text_encoders", so the two keys below
#    merge into one namespace.
# 3. get_full_path returns the first hit with no warning and the dropdown
#    deduplicates by filename, so a name collision between two roots is
#    invisible. clip_l.safetensors under both clip/ and text_encoders/ at
#    different sizes is the usual real case.
# 4. is_default: true makes the loader insert(0, ...) for every path, so a
#    multi-line block is searched in REVERSE and the last line wins. The blocks
#    below are written back to front on purpose.

shared_models:
    base_path: /models/public/
    is_default: true
    # Reversed. Effective order is diffusion_models/ then unet/.
    diffusion_models: |
        unet/
        diffusion_models/
    # Reversed. Effective order is text_encoders/ then clip/.
    text_encoders: |
        clip/
        text_encoders/
    vae: vae/
    loras: loras/
    controlnet: controlnet/
    clip_vision: clip_vision/
    embeddings: embeddings/
    upscale_models: upscale_models/
    style_models: style_models/
    model_patches: model_patches/
    configs: configs/

local_models:
    base_path: /models/local/
    diffusion_models: diffusion_models/
    text_encoders: text_encoders/
    vae: vae/
    loras: loras/
    unet_gguf: unet/
    clip_gguf: clip/
YAML

COPY <<'SCRIPT' /usr/local/bin/entrypoint.sh
#!/bin/sh
# Fail loudly at startup rather than quietly degrading to CPU and running all
# night at one hundredth of the speed.
set -e

CONFIG_DIR="${CONFIG_DIR:-/config}"
MODEL_PATHS="$CONFIG_DIR/extra_model_paths.yaml"

mkdir -p "$CONFIG_DIR"

# Seed the config on first run. A bind mounted file that does not exist on the
# host makes Docker create a directory in its place, so the config lives in a
# mounted directory instead and is copied in here.
if [ ! -f "$MODEL_PATHS" ]; then
    cp /opt/defaults/extra_model_paths.yaml "$MODEL_PATHS"
    echo "[entrypoint] wrote a default $MODEL_PATHS, edit it on the NAS and restart"
fi

# The custom_nodes bind mount shadows the examples shipped with ComfyUI, so put
# them back the first time.
if [ -d /opt/ComfyUI/custom_nodes ] && [ -z "$(ls -A /opt/ComfyUI/custom_nodes 2>/dev/null)" ]; then
    cp /opt/defaults/custom_nodes/* /opt/ComfyUI/custom_nodes/ 2>/dev/null || true
fi

# Dependencies for custom nodes, so adding one small package does not mean
# rebuilding the image.
export PYTHONPATH="/opt/pip-extra:${PYTHONPATH}"

# GPU preflight. If NVIDIA_DRIVER_CAPABILITIES lacks the compute capability the
# container gets a working nvidia-smi but no libcuda.so.1, and torch reports
# CUDA as unavailable without raising anything. That is the most misleading
# failure on this platform, so catch it here.
python - <<'PY' || exit 1
import sys, torch
print("[entrypoint] torch", torch.__version__, "built for CUDA", torch.version.cuda)
if not torch.cuda.is_available():
    print("[entrypoint] CUDA unavailable. Check the compose runtime and the NVIDIA_* environment variables.", file=sys.stderr)
    sys.exit(1)
cap = torch.cuda.get_device_capability(0)
print("[entrypoint] device", torch.cuda.get_device_name(0), "sm_%d%d" % cap)
if cap < (8, 9):
    print("[entrypoint] note: sm_%d%d has no native fp8, so fp8 weights are storage only and are cast for compute." % cap)
if cap < (10, 0):
    print("[entrypoint] note: sm_%d%d has no native NVFP4, so nvfp4 weights go through emulated dequantization." % cap)
PY

cd /opt/ComfyUI
echo "[entrypoint] exec main.py $*"
exec python main.py --extra-model-paths-config "$MODEL_PATHS" "$@"
SCRIPT

RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /opt/ComfyUI
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
