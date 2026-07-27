#!/bin/bash
# Runs INSIDE rpi5-builder. Must run after build-indi-3rdparty-libs.sh
# (drivers link against the just-built 3rd-party libs, and against
# indi-core's libindidriver/libindiclient/libindiAlignmentDriver).
set -euo pipefail

CCDIR=/home/soo/cc
BUILD=$CCDIR/repo/indi-3rdparty/build-drivers-rpi5
STAGE=$CCDIR/rpi5-staging/indi-3rdparty
STAGE_CORE=$CCDIR/rpi5-staging/indi
SYSROOT=$CCDIR/rpi5-sysroot

mkdir -p "$BUILD"
cd "$BUILD"

cmake .. \
  -DCMAKE_TOOLCHAIN_FILE=$CCDIR/rpi5-toolchain.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_PREFIX_PATH="$STAGE/usr;$STAGE_CORE/usr;$SYSROOT/usr" \
  -DBUILD_LIBS=OFF \
  -DBUILD_DRIVERS=ON \
  -DINDI_DATA_DIR=/usr/share/indi \
  -DWITH_WEBCAM=OFF \
  -DCMAKE_CXX_FLAGS="--sysroot=$SYSROOT -march=armv8.2-a+crypto+fp16 -mtune=cortex-a76 -I$STAGE/usr/include -I$STAGE_CORE/usr/include" \
  -DCMAKE_C_FLAGS="--sysroot=$SYSROOT -march=armv8.2-a+crypto+fp16 -mtune=cortex-a76 -I$STAGE/usr/include -I$STAGE_CORE/usr/include"

make -j"$(nproc)" 2>&1 | tee "$CCDIR/indi-3rdparty-drivers-build.log"
# setcap is not DESTDIR-aware and can fail here — deferred to postinst instead.
# -k lets the rest of the install proceed past that one failure if it happens.
make -k install DESTDIR=$STAGE
