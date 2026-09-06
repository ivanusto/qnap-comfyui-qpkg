#!/bin/sh
# 沿用 comfyui-up.sh 的 preflight 哲學：寧可啟動時大聲失敗，
# 也不要無聲地降級成 CPU 模式跑一整晚。
set -e

COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"

die() { echo "[entrypoint] $*" >&2; exit 1; }

[ -f "$COMFY_DIR/main.py" ] || die "ComfyUI 原始碼未掛入：$COMFY_DIR/main.py 不存在"

# custom node 的相依放這裡，避免為了一個小套件重建 7 GB 映像。
export PYTHONPATH="/opt/pip-extra:${PYTHONPATH}"

# GPU preflight。NVIDIA_DRIVER_CAPABILITIES 若少了 compute，
# 容器內會有 nvidia-smi 但沒有 libcuda.so.1，torch 會靜靜地回報 False。
# 這是本機最容易誤判的失敗態，所以在這裡擋掉。
python - <<'PY' || exit 1
import sys, torch
print("[entrypoint] torch", torch.__version__, "built for CUDA", torch.version.cuda)
if not torch.cuda.is_available():
    print("[entrypoint] CUDA 不可用。檢查 compose 的 runtime 與 NVIDIA_* 環境變數。", file=sys.stderr)
    sys.exit(1)
cap = torch.cuda.get_device_capability(0)
print("[entrypoint] device", torch.cuda.get_device_name(0), "sm_%d%d" % cap)
if cap < (8, 9):
    print("[entrypoint] 注意 sm_%d%d 無 fp8 原生運算，fp8 權重只是儲存格式，計算時轉型。" % cap)
if cap < (10, 0):
    print("[entrypoint] 注意 sm_%d%d 無 NVFP4 原生運算，nvfp4 權重會走 emulated 反量化。" % cap)
PY

cd "$COMFY_DIR"
echo "[entrypoint] exec main.py $*"
exec python main.py "$@"
