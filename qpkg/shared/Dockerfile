# ComfyUI for QNAP Container Station with an NVIDIA GPU.
#
# The base is python slim rather than nvidia/cuda. The pip torch wheels already
# ship a complete CUDA runtime (site-packages/nvidia alone measured 2.7 GB), so
# stacking an nvidia/cuda base on top gives you two copies and 2 to 3 GB of
# waste. The driver side libcuda.so.1 is injected at runtime by nvidia-runtime.
FROM python:3.12-slim-bookworm

ARG COMFY_REF=v0.37.0
# The torch wheel index has to match the driver shipped by the NVIDIA_GPU_DRV
# package. Read the CUDA version out of nvidia-smi and pick wheels no newer
# than that. There is a table in the README.
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu128
ARG TORCH_VERSION=2.9.1+cu128
ARG TORCHVISION_VERSION=0.24.1+cu128
ARG TORCHAUDIO_VERSION=2.9.1+cu128

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

# libgl1 and libglib2.0-0 are runtime dependencies of opencv and Pillow.
# libgomp1 provides the OpenMP runtime that scipy and spandrel need.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl tini \
        libgl1 libglib2.0-0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv

# All three have to be pinned together. Pinning only torch lets pip resolve an
# incompatible torchaudio, which fails at import with
#   undefined symbol: torch_library_impl
# That error does not surface during pip install. It surfaces much later, when
# ComfyUI imports comfy.ldm.lightricks.vae.audio_vae.
RUN pip install --no-cache-dir --index-url "${TORCH_INDEX}" \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}"

# Only requirements.txt is baked in. The source tree itself is a bind mount so
# that upgrading ComfyUI does not mean rebuilding this image.
ADD https://raw.githubusercontent.com/comfyanonymous/ComfyUI/${COMFY_REF}/requirements.txt /tmp/requirements.txt

# Strip the torch trio, otherwise pip reinstalls them from the default index and
# silently replaces the pinned CUDA builds above.
# Keep comfy-aimdo and comfy-kitchen. They are genuine upstream dependencies,
# not optional extras: comfy-aimdo implements DynamicVRAM, which is what lets a
# model larger than your VRAM run at all.
RUN grep -vE '^(torch|torchvision|torchaudio)([=<>!~[]|$)' /tmp/requirements.txt > /tmp/req-notorch.txt \
    && pip install --no-cache-dir -r /tmp/req-notorch.txt \
    && python -c "import comfy_aimdo.control, comfy_kitchen; print('aimdo/kitchen import OK')"

# CPUs without AVX2 (some low-power parts stop at sse4_2) cannot
# execute the kornia_rs wheels from 0.1.13 onward. The failure is
#   Fatal Python error: Illegal instruction
# reported against comfy_extras/nodes_post_processing.py, which merely imports
# kornia, and pip gives no hint at all.
# /proc/cpuinfo inside a container reflects the host CPU, so this check is
# accurate at build time. Downgrading on an AVX2 machine would be harmless but
# pointless, hence the conditional.
RUN if grep -qw avx2 /proc/cpuinfo; then \
        echo "CPU has AVX2, keeping resolved kornia_rs"; \
    else \
        echo "CPU lacks AVX2, pinning kornia_rs to the last known-good build"; \
        pip install --no-cache-dir "kornia_rs==0.1.10"; \
    fi \
    && python -c "import kornia, kornia_rs; print('kornia', kornia.__version__, 'with kornia_rs', kornia_rs.__version__, 'OK')"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /opt/ComfyUI
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
