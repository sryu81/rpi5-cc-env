#!/bin/bash
# Runs INSIDE rpi5-builder. Must run after build-indi-core.sh — headers/libs
# from indi-core's rpi5-staging/indi are needed here.
set -euo pipefail

CCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD=$CCDIR/repo/indi-3rdparty/build-libs-rpi5
STAGE=$CCDIR/rpi5-staging/indi-3rdparty
STAGE_CORE=$CCDIR/rpi5-staging/indi
SYSROOT=$CCDIR/rpi5-sysroot

mkdir -p "$BUILD" "$STAGE"
cd "$BUILD"

cmake .. \
  -DCMAKE_TOOLCHAIN_FILE=$CCDIR/rpi5-toolchain.cmake \
  -DSYSROOT=$SYSROOT \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_PREFIX_PATH="$STAGE/usr;$STAGE_CORE/usr;$SYSROOT/usr" \
  -DBUILD_LIBS=ON \
  -DBUILD_DRIVERS=OFF \
  -DINDI_DATA_DIR=/usr/share/indi

make -j"$(nproc)" 2>&1 | tee "$CCDIR/indi-3rdparty-libs-build.log"
make install DESTDIR=$STAGE
