# ComfyUI for QNAP Container Station with an NVIDIA GPU.
#
# base 用 python slim 而非 nvidia/cuda：pip 的 torch wheel 已自帶完整 CUDA runtime
# （實測 site-packages/nvidia 就佔 2.7 GB），疊 nvidia/cuda base 會得到兩份 CUDA，
# 白多 2 至 3 GB。驅動端的 libcuda.so.1 由 nvidia-runtime 在啟動時注入。
FROM python:3.12-slim-bookworm

ARG COMFY_REF=v0.34.3
# torch 輪子的索引要對得上 NAS 上 NVIDIA_GPU_DRV 的驅動版本。
# 用 nvidia-smi 查 CUDA Version，再選不高於它的輪子。對照表見 README。
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu128
ARG TORCH_VERSION=2.9.1+cu128
ARG TORCHVISION_VERSION=0.24.1+cu128
ARG TORCHAUDIO_VERSION=2.9.1+cu128

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH

# libgl1 與 libglib2.0-0 是 opencv 與 Pillow 的執行期相依；
# libgomp1 是 scipy 與 spandrel 需要的 OpenMP。
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl tini \
        libgl1 libglib2.0-0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv

# 三件套必須一起釘死版本。只釘 torch 的話 pip 會解到不相容的 torchaudio，
# 載入時是 undefined symbol: torch_library_impl，而且不會在 pip 階段報錯，
# 要等 ComfyUI import comfy.ldm.lightricks.vae.audio_vae 才炸開。
RUN pip install --no-cache-dir --index-url "${TORCH_INDEX}" \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}"

# 只取 requirements.txt，原始碼本身走 bind mount 以利升級。
ADD https://raw.githubusercontent.com/comfyanonymous/ComfyUI/${COMFY_REF}/requirements.txt /tmp/requirements.txt

# 濾掉 torch 三件套，否則 pip 會從預設 index 重裝並覆蓋掉上面釘好的版本。
# comfy-aimdo 與 comfy-kitchen 必須保留：它們是上游的正規相依，提供 DynamicVRAM，
# 是顯存小於模型時還能出圖的關鍵。
RUN grep -vE '^(torch|torchvision|torchaudio)([=<>!~[]|$)' /tmp/requirements.txt > /tmp/req-notorch.txt \
    && pip install --no-cache-dir -r /tmp/req-notorch.txt \
    && python -c "import comfy_aimdo.control, comfy_kitchen; print('aimdo/kitchen import OK')"

# 沒有 AVX2 的 CPU（例如 Atom C5125 這類 Tremont 核心，指令集只到 sse4_2）
# 跑不動 kornia_rs 0.1.13 以上的 wheel，import 時直接
#   Fatal Python error: Illegal instruction
# 而且崩潰點顯示在 comfy_extras/nodes_post_processing.py，pip 階段完全看不出來。
# 容器內的 /proc/cpuinfo 反映的是主機 CPU，所以這個偵測在 build 階段就準確。
# 有 AVX2 就保持 pip 解出來的版本，沒有才降版。降版對有 AVX2 的機器無害，
# 但沒必要，所以做成條件式。
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
