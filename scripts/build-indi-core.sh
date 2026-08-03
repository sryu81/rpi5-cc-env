#!/bin/bash
# Runs INSIDE rpi5-builder.
set -euo pipefail

CCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD=$CCDIR/repo/indi/build-rpi5
STAGE=$CCDIR/rpi5-staging/indi
SYSROOT=$CCDIR/rpi5-sysroot

# Real upstream GCC12 bug (bare isnan() not injected into global namespace by
# <cmath>) — see docs/BUILD-AND-PACKAGE.md. Idempotent: no-op if already applied.
bash "$CCDIR/scripts/apply-patch.sh" "$CCDIR/repo/indi" "$CCDIR/patches/indi-glibc-isnan.patch"

mkdir -p "$BUILD" "$STAGE"
cd "$BUILD"

cmake .. \
  -DCMAKE_TOOLCHAIN_FILE=$CCDIR/rpi5-toolchain.cmake \
  -DSYSROOT=$SYSROOT \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_PREFIX_PATH="$STAGE/usr;$SYSROOT/usr" \
  -DINDI_BUILD_SERVER=ON \
  -DINDI_BUILD_CLIENT=ON \
  -DINDI_BUILD_DRIVERS=ON \
  -DINDI_BUILD_UNITTESTS=OFF \
  -DINDI_BUILD_INTEGTESTS=OFF

make -j"$(nproc)" 2>&1 | tee "$CCDIR/indi-core-build.log"
make install DESTDIR=$STAGE
