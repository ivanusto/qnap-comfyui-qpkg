#!/bin/sh
# Build the ComfyUI QPKG. Run this ON the NAS, not on your workstation.
#
# QDK ships with QNAP's own QDK package. Install it from App Center first,
# then run this script from the repository root:
#
#     sh build.sh
#
# The resulting .qpkg lands in build/.
set -e

ARCH="${ARCH:-x86_64}"
VERSION="${VERSION:-0.37.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

QBUILD=$(command -v qbuild 2>/dev/null || true)
if [ -z "$QBUILD" ]; then
    for d in /share/*/.qpkg/QDK/bin/qbuild; do
        [ -x "$d" ] && QBUILD="$d" && break
    done
fi
[ -n "$QBUILD" ] || { echo "qbuild not found. Install the QDK package from App Center." >&2; exit 1; }

# qbuild expects the build environment layout, so assemble it in a temp dir.
SRC=$(cd "$(dirname "$0")" && pwd)
WORK="${WORK:-$SRC/.build-env}"
rm -rf "$WORK"
mkdir -p "$WORK/shared" "$WORK/icons" "$WORK/$ARCH"

cp "$SRC/qpkg/qpkg.cfg"          "$WORK/qpkg.cfg"
cp "$SRC/qpkg/package_routines"  "$WORK/package_routines"
cp "$SRC/qpkg/shared/"*          "$WORK/shared/"
cp "$SRC/qpkg/icons/"*           "$WORK/icons/"
chmod +x "$WORK/shared/ComfyUI.sh" "$WORK/shared/entrypoint.sh"

cd "$WORK"
"$QBUILD" --build-arch "$ARCH" --build-version "$VERSION" --build-number "$BUILD_NUMBER"

mkdir -p "$SRC/build"
cp "$WORK/build/"*.qpkg "$WORK/build/"*.qpkg.md5 "$SRC/build/" 2>/dev/null || true
# qbuild writes the checksum as "<md5>  build/<file>", which md5sum -c cannot
# find next to a downloaded file. Drop the directory prefix.
sed -i 's#  build/#  #' "$SRC/build/"*.qpkg.md5 2>/dev/null || true
echo
echo "Built:"
ls -la "$SRC/build/"
