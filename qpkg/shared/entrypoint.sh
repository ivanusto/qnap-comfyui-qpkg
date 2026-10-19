#!/bin/sh
# Fail loudly at startup rather than quietly degrading to CPU and running all
# night at one hundredth of the speed.
set -e

COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"

die() { echo "[entrypoint] $*" >&2; exit 1; }

[ -f "$COMFY_DIR/main.py" ] || die "ComfyUI source is not mounted: $COMFY_DIR/main.py missing"

# Dependencies for custom nodes go here, so that adding one small package does
# not mean rebuilding a 9 GB image. Packages ComfyUI-Manager installs land in
# the container itself and are gone after the next stop, because stopping the
# app removes the container. With COMFY_NODE_REQUIREMENTS=install, every
# custom_nodes/*/requirements.txt is installed under pip-extra instead, where it
# survives. It runs again only when one of those files changes. --prefix rather
# than --target, because --target ignores what the image already has and would
# install a second copy of torch.
# The image puts $PIP_EXTRA/prefix/lib/python3.12/site-packages and $PIP_EXTRA
# on PYTHONPATH.
PIP_EXTRA=/opt/pip-extra

if [ "${COMFY_NODE_REQUIREMENTS:-off}" = "install" ]; then
    STAMP="$PIP_EXTRA/.node-requirements.sha256"
    SUM=$(for r in "$COMFY_DIR"/custom_nodes/*/requirements.txt; do
              [ -f "$r" ] && echo "$r" && cat "$r"
          done | sha256sum | cut -d' ' -f1)
    if [ "$SUM" != "$(cat "$STAMP" 2>/dev/null)" ]; then
        failed=0
        for r in "$COMFY_DIR"/custom_nodes/*/requirements.txt; do
            [ -f "$r" ] || continue
            node=$(basename "$(dirname "$r")")
            echo "[entrypoint] installing requirements for $node"
            # A node that asks for another torch fails here rather than
            # replacing the CUDA build; the others still get installed.
            pip install --prefix "$PIP_EXTRA/prefix" --no-warn-script-location \
                    -c /opt/constraints.txt -r "$r" \
                || { echo "[entrypoint] $node: install failed, see above" >&2; failed=1; }
        done
        # polars, which ultralytics and deepdiff pull in, defaults to a runtime
        # built for AVX2 and kills the whole process with Illegal instruction
        # on CPUs without it. polars prefers its compat runtime when present.
        if ! grep -qw avx2 /proc/cpuinfo; then
            PV=$(python -c "import importlib.metadata as m; print(m.version('polars'))" 2>/dev/null || true)
            if [ -n "$PV" ]; then
                echo "[entrypoint] CPU lacks AVX2, adding polars-runtime-compat $PV"
                pip install --prefix "$PIP_EXTRA/prefix" --no-warn-script-location \
                        "polars-runtime-compat==$PV" \
                    || { echo "[entrypoint] polars-runtime-compat: install failed" >&2; failed=1; }
            fi
        fi
        # Only remember a fully successful pass, so a failure is retried on
        # the next start.
        [ $failed -eq 0 ] && echo "$SUM" > "$STAMP"
    else
        echo "[entrypoint] custom node requirements unchanged, skipping install"
    fi
fi

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
