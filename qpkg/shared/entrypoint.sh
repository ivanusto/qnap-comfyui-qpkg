#!/bin/sh
# Fail loudly at startup rather than quietly degrading to CPU and running all
# night at one hundredth of the speed.
set -e

COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"

die() { echo "[entrypoint] $*" >&2; exit 1; }

[ -f "$COMFY_DIR/main.py" ] || die "ComfyUI source is not mounted: $COMFY_DIR/main.py missing"

# Dependencies for custom nodes go here, so that adding one small package does
# not mean rebuilding a 9 GB image.
export PYTHONPATH="/opt/pip-extra:${PYTHONPATH}"

# GPU preflight. If NVIDIA_DRIVER_CAPABILITIES is missing the compute
# capability, the container gets a working nvidia-smi but no libcuda.so.1, and
# torch reports CUDA as unavailable without raising anything. That is the most
# misleading failure mode on this platform, so catch it here.
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

cd "$COMFY_DIR"
echo "[entrypoint] exec main.py $*"
exec python main.py "$@"
