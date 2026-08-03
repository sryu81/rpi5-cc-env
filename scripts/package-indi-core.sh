#!/bin/bash
# Runs INSIDE rpi5-builder. Packages rpi5-staging/indi (INDI core only) into
# deb/indi-core-rpi5_<version>_arm64.deb.
set -euo pipefail

CCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE=$CCDIR/rpi5-staging/indi
PKG=$CCDIR/deb/indi-core-rpi5-pkg
VERSION=2.2.1

rm -rf "$PKG"
mkdir -p "$PKG"
cp -a "$STAGE/." "$PKG/"
rm -rf "$PKG/DEBIAN"
mkdir -p "$PKG/DEBIAN"

# drop build/dev-only artifacts — never ship these in a runtime package:
rm -rf "$PKG/usr/include"
rm -rf "$PKG/usr/lib/pkgconfig"
rm -rf "$PKG/usr/lib/cmake"
find "$PKG" -iname "*.a" -delete

find "$PKG" -type f -exec file {} \; \
  | grep 'ELF ' | cut -d: -f1 \
  | xargs -r aarch64-linux-gnu-strip 2>/dev/null || true

INSTALLED_SIZE=$(du -sk "$PKG" | cut -f1)

# Depends derived from `objdump -p` NEEDED scan of every binary in this
# staging tree, cross-checked against the real Pi's dpkg database (ssh
# soo@<pi-ip> "dpkg -S ...") — not guessed. See docs/BUILD-AND-PACKAGE.md.
cat > "$PKG/DEBIAN/control" << EOF
Package: indi-core-rpi5
Version: $VERSION
Architecture: arm64
Maintainer: soo
Installed-Size: $INSTALLED_SIZE
Depends: libcfitsio10, libcurl4, libev4, libfftw3-double3, libgslcblas0, libgsl27, libjpeg62-turbo, libnova-0.16-0, libogg0, librtlsdr0, libtheora0, libudev1, libusb-1.0-0
Description: INDI core framework (indiserver, libindi, libindiclient) for Raspberry Pi 5
 INDI core $VERSION — server, client library, and bundled simulator/basic
 drivers, cross-compiled for Raspberry Pi 5 aarch64 using the Debian
 Bookworm toolchain (GCC 12, GLIBC 2.36).
EOF

cat > "$PKG/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
ldconfig
EOF
chmod 755 "$PKG/DEBIAN/postinst"

cat > "$PKG/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
ldconfig
EOF
chmod 755 "$PKG/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "$PKG" "$CCDIR/deb/indi-core-rpi5_${VERSION}_arm64.deb"
echo "Built $CCDIR/deb/indi-core-rpi5_${VERSION}_arm64.deb"
