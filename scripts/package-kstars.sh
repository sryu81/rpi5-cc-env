#!/bin/bash
# Runs INSIDE rpi5-builder. Packages rpi5-staging/kstars (StellarSolver +
# KStars combined) into deb/kstars-custom_<version>_arm64.deb.
set -euo pipefail

CCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE=$CCDIR/rpi5-staging/kstars
PKG=$CCDIR/deb/kstars-custom-pkg
VERSION=3.8.3

rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN"
cp -a "$STAGE/usr" "$PKG/"

# drop build-only artifacts — never ship these in a runtime package:
rm -f  "$PKG/usr/lib/libhtmesh.a"
rm -rf "$PKG/usr/lib/cmake"
rm -rf "$PKG/usr/lib/pkgconfig"

aarch64-linux-gnu-strip "$PKG/usr/bin/kstars"
aarch64-linux-gnu-strip "$PKG/usr/lib/libstellarsolver.so.2.6"

INSTALLED_SIZE=$(du -sk "$PKG/usr" | cut -f1)

cat > "$PKG/DEBIAN/control" << EOF
Package: kstars-custom
Version: $VERSION
Section: science
Priority: optional
Architecture: arm64
Maintainer: soo
Installed-Size: $INSTALLED_SIZE
Depends: libqt5core5a, libqt5gui5, libqt5widgets5, libqt5sql5, libqt5svg5, libqt5websockets5, libqt5network5, libqt5dbus5, libqt5printsupport5, libqt5quick5, libqt5qml5, libqt5concurrent5, libqt5datavisualization5, libkf5xmlgui5, libkf5i18n5, libkf5configcore5, libkf5configgui5, libkf5configwidgets5, libkf5coreaddons5, libkf5widgetsaddons5, libkf5notifications5, libkf5notifyconfig5, libkf5kiocore5, libkf5kiowidgets5, libkf5plotting5, libkf5newstuff5, libgsl27, libopencv-core406, libopencv-imgproc406, libopencv-calib3d406, libqt5keychain1, libraw20, libwcs7, libcfitsio10, zlib1g, indi-core-rpi5 (>= 2.2.1)
Description: KStars $VERSION custom aarch64 build for RPi5
 Cross-compiled for Raspberry Pi 5 (Debian 12 Bookworm, GCC 12, GLIBC 2.36
 max). Bundles StellarSolver 2.6 for plate-solving. Requires indi-core-rpi5
 for libindiclient.
EOF

cat > "$PKG/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
ldconfig
update-desktop-database /usr/share/applications || true
EOF
chmod 755 "$PKG/DEBIAN/postinst"

cat > "$PKG/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
ldconfig
update-desktop-database /usr/share/applications || true
EOF
chmod 755 "$PKG/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "$PKG" "$CCDIR/deb/kstars-custom_${VERSION}_arm64.deb"
echo "Built $CCDIR/deb/kstars-custom_${VERSION}_arm64.deb"
