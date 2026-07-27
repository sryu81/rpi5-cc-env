#!/bin/bash
# Runs INSIDE rpi5-builder.
set -euo pipefail

CCDIR=/home/soo/cc
BUILD=$CCDIR/repo/indi/build-rpi5
STAGE=$CCDIR/rpi5-staging/indi

mkdir -p "$BUILD" "$STAGE"
cd "$BUILD"

cmake .. \
  -DCMAKE_TOOLCHAIN_FILE=$CCDIR/rpi5-toolchain.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_PREFIX_PATH="$STAGE/usr;$CCDIR/rpi5-sysroot/usr" \
  -DINDI_BUILD_SERVER=ON \
  -DINDI_BUILD_CLIENT=ON \
  -DINDI_BUILD_DRIVERS=ON \
  -DINDI_BUILD_UNITTESTS=OFF \
  -DINDI_BUILD_INTEGTESTS=OFF

make -j"$(nproc)" 2>&1 | tee "$CCDIR/indi-core-build.log"
make install DESTDIR=$STAGE
