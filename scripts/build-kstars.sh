#!/bin/bash
# Runs INSIDE rpi5-builder. Requires fix-env.sh and build-stellarsolver.sh
# to have been run first. repo/kstars is a plain git clone (not a submodule) — see Makefile's clone-repos target.
set -euo pipefail

CCDIR=/home/soo/cc
BUILD=$CCDIR/repo/kstars/build-rpi5
STAGE=$CCDIR/rpi5-staging/kstars
STAGE_INDI=$CCDIR/rpi5-staging/indi

# Real upstream GCC12 bug (missing <limits> include, same class as INDI's
# isnan fix). Idempotent: no-op if already applied.
bash "$CCDIR/scripts/apply-patch.sh" "$CCDIR/repo/kstars" "$CCDIR/patches/kstars-rectangleoverlap-limits.patch"

mkdir -p "$BUILD"
cd "$BUILD"

# KStars' cmake/modules/FindINDI.cmake finds INDI via pkg-config + find_path,
# neither of which searched our indi-core staging without this — it was
# silently resolving against whatever INDI the sysroot happened to have
# (rsynced from the Pi's own system packages), not our freshly cross-compiled
# indi-core-rpi5. Surfaced as "indiversion.h: No such file or directory".
cmake .. \
  -DCMAKE_TOOLCHAIN_FILE=$CCDIR/rpi5-toolchain.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_PREFIX_PATH="$STAGE/usr;$STAGE_INDI/usr;$CCDIR/rpi5-sysroot/usr" \
  -DStellarSolver_DIR=$STAGE/usr/lib/cmake/StellarSolver \
  -DGETTEXT_MSGFMT_EXECUTABLE=/usr/bin/msgfmt \
  -DGETTEXT_MSGMERGE_EXECUTABLE=/usr/bin/msgmerge \
  -DBUILD_WITH_QT6=OFF \
  -DBUILD_TESTING=OFF

make -j"$(nproc)" 2>&1 | tee "$CCDIR/kstars-build.log"
make install DESTDIR=$STAGE
