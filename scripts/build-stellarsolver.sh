#!/bin/bash
# Runs INSIDE rpi5-builder. Requires fix-env.sh to have been run first
# (StellarSolver's Qt5 autogen needs working moc/uic in the sysroot).
# repo/stellarsolver is a plain git clone (not a submodule) — must already be
# checked out (`make clone-repos` on the host if missing).
set -euo pipefail

CCDIR=/home/soo/cc
BUILD=$CCDIR/repo/stellarsolver/build-rpi5
STAGE=$CCDIR/rpi5-staging/kstars

# Cross-compiling fix: default qsort_r feature detection uses try_run(), which
# can't execute a cross-compiled test binary on the host. Adds a
# CMAKE_CROSSCOMPILING branch with hardcoded, known-correct values instead of
# guessing. Idempotent: no-op if already applied.
bash "$CCDIR/scripts/apply-patch.sh" "$CCDIR/repo/stellarsolver" "$CCDIR/patches/stellarsolver-cross-compile-qsort_r.patch"

mkdir -p "$BUILD" "$STAGE"
cd "$BUILD"

# CMAKE_STAGING_PREFIX (not DESTDIR) — StellarSolver uses install(EXPORT ...),
# which bakes the literal CMAKE_INSTALL_PREFIX into its generated
# StellarSolverTargets.cmake (INTERFACE_INCLUDE_DIRECTORIES etc). DESTDIR only
# relocates where `make install` physically writes files, it does NOT change
# what path gets recorded in exported config files — so KStars would later
# find a StellarSolverConfig.cmake correctly, but one that points
# INTERFACE_INCLUDE_DIRECTORIES at the real (non-staged) "/usr/include/...",
# which doesn't exist here. CMAKE_STAGING_PREFIX is the CMake mechanism built
# for exactly this: told about it, CMake generates exported config files that
# point at the staging path directly.
cmake .. \
  -DCMAKE_TOOLCHAIN_FILE=$CCDIR/rpi5-toolchain.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_STAGING_PREFIX=$STAGE/usr \
  -DCMAKE_PREFIX_PATH="$STAGE/usr;$CCDIR/rpi5-sysroot/usr" \
  -DBUILD_TESTER=OFF

make -j"$(nproc)" 2>&1 | tee "$CCDIR/stellarsolver-build.log"
make install
