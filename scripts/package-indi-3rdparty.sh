#!/bin/bash
# Runs INSIDE rpi5-builder. Packages rpi5-staging/indi-3rdparty into
# deb/indi-3rdparty-rpi5_<version>_arm64.deb. Depends on indi-core-rpi5 for
# libindidriver.so.2/libindiclient.so.2/libindiAlignmentDriver.so.2 — those
# are NOT bundled here even though this binary set links against them.
set -euo pipefail

CCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE=$CCDIR/rpi5-staging/indi-3rdparty
PKG=$CCDIR/deb/indi-3rdparty-rpi5-pkg
VERSION=2.2.1
CORE_VERSION=2.2.1

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

# Depends derived from `objdump -p` NEEDED scan (excluding the ~40 bundled
# closed-source vendor camera SDKs shipped as .so files inside this same
# tree — those are payload, not system deps) cross-checked against the real
# Pi's dpkg database. See docs/BUILD-AND-PACKAGE.md.
cat > "$PKG/DEBIAN/control" << EOF
Package: indi-3rdparty-rpi5
Version: $VERSION
Architecture: arm64
Maintainer: soo
Installed-Size: $INSTALLED_SIZE
Depends: indi-core-rpi5 (>= $CORE_VERSION), libcfitsio10, libcurl4, libdc1394-25, libftdi1-2, libgphoto2-6, libgphoto2-port12, libgps28, libjpeg62-turbo, liblimesuite22.09-1, libnova-0.16-0, libraw20, libudev1, libusb-1.0-0, libzmq5
Description: INDI 3rd-party drivers and vendor SDKs for Raspberry Pi 5
 All INDI 3rd-party libs and drivers (camera/mount/focuser/filter-wheel
 vendor SDKs), cross-compiled for Raspberry Pi 5 aarch64 using the Debian
 Bookworm toolchain (GCC 12, GLIBC 2.36). Requires indi-core-rpi5.
EOF

cat > "$PKG/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
ldconfig
setcap cap_net_raw+ep /usr/bin/indi_pentax || true
udevadm control --reload-rules || true
udevadm trigger || true
EOF
chmod 755 "$PKG/DEBIAN/postinst"

cat > "$PKG/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
ldconfig
EOF
chmod 755 "$PKG/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "$PKG" "$CCDIR/deb/indi-3rdparty-rpi5_${VERSION}_arm64.deb"
echo "Built $CCDIR/deb/indi-3rdparty-rpi5_${VERSION}_arm64.deb"
