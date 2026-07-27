#!/bin/bash
# Runs on the HOST (rsync/ssh to the Pi, not through the container).
# Usage: sync-sysroot.sh <user@pi-ip>
set -euo pipefail

PI="$1"
SYSROOT=/home/soo/cc/rpi5-sysroot

mkdir -p "$SYSROOT/usr/lib" "$SYSROOT/usr" "$SYSROOT/lib" "$SYSROOT/usr/share" \
         "$SYSROOT/usr/lib/aarch64-linux-gnu" "$SYSROOT/usr/lib/cmake"

# aarch64 shared libs, headers, linker scripts, pkgconfig — needed for any build
rsync -avz --rsync-path="sudo rsync" "$PI":/usr/lib/aarch64-linux-gnu "$SYSROOT/usr/lib/"
rsync -avz --rsync-path="sudo rsync" "$PI":/usr/include "$SYSROOT/usr/"
rsync -avz --rsync-path="sudo rsync" "$PI":/lib/aarch64-linux-gnu "$SYSROOT/lib/"
rsync -avz --rsync-path="sudo rsync" "$PI":/usr/share/pkgconfig "$SYSROOT/usr/share/"

# KF5/Qt5/ECM cmake configs — needed for StellarSolver/KStars only, harmless for INDI
rsync -avz --rsync-path="sudo rsync" "$PI":/usr/lib/aarch64-linux-gnu/cmake "$SYSROOT/usr/lib/aarch64-linux-gnu/cmake"
rsync -avz --rsync-path="sudo rsync" "$PI":/usr/lib/cmake "$SYSROOT/usr/lib/cmake"

# fix absolute symlinks so they resolve inside this copy, not the Pi's real root
command -v symlinks >/dev/null || sudo apt-get install -y symlinks
symlinks -cr "$SYSROOT"

# Debian's blas/lapack alternatives indirection (/etc/alternatives/...) is never
# rsynced above (out of scope of the paths we pull) — lib/aarch64-linux-gnu/
# lib{blas,lapack}.so.3 end up dangling. usr/lib/aarch64-linux-gnu/ copies
# resolve fine via a different, relative symlink chain; only the top-level
# lib/ ones need this. Point them directly at the real concrete files.
for name in blas lapack; do
  target=$(find "$SYSROOT/usr/lib/aarch64-linux-gnu/$name" -maxdepth 1 -name "lib${name}.so.3.*" 2>/dev/null | head -1)
  if [ -n "$target" ]; then
    ln -sf "$target" "$SYSROOT/lib/aarch64-linux-gnu/lib${name}.so.3"
  fi
done

echo "sync-sysroot: done. Verify key cmake configs exist:"
find "$SYSROOT/usr" -name "Qt5Config.cmake" -o -name "KF5ConfigConfig.cmake" -o -name "ECMConfig.cmake"
