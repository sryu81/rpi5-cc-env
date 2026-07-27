#!/bin/bash
# Runs INSIDE rpi5-builder. Container-instance-local — redo after every
# container recreation (docker rm/run, or a host reboot that recycles it).
# See docs/BUILD-AND-PACKAGE.md Step 0 for why this is needed.
set -euo pipefail

SYSROOT=/home/soo/cc/rpi5-sysroot

# git submodules are bind-mounted from the host (owned by the host UID) but
# accessed as root inside the container — git refuses to run any command
# (including the `git describe` INDI's CMakeLists.txt uses for its version
# string) against a repo it doesn't consider "owned" by the current user.
git config --global --add safe.directory '*'

apt-get update -qq
apt-get install -y -qq qtbase5-dev-tools qttools5-dev-tools qt5-qmake gettext \
    libkf5config-dev-bin kdoctools5 libkf5coreaddons-dev libkf5auth-dev libkf5config-bin

SYSQT="$SYSROOT/usr/lib/aarch64-linux-gnu/qt5/bin"
mkdir -p "$SYSQT" "$SYSROOT/usr/lib/qt5/bin"

ln -sf /usr/lib/qt5/bin/moc          "$SYSQT/moc"
ln -sf /usr/lib/qt5/bin/uic          "$SYSQT/uic"
ln -sf /usr/lib/qt5/bin/rcc          "$SYSQT/rcc"
ln -sf /usr/lib/qt5/bin/qdbusxml2cpp "$SYSQT/qdbusxml2cpp"
ln -sf /usr/lib/qt5/bin/qdbuscpp2xml "$SYSQT/qdbuscpp2xml"
ln -sf /usr/bin/qmake                "$SYSQT/qmake"
ln -sf /usr/bin/qmake                "$SYSROOT/usr/lib/qt5/bin/qmake"

# Same class of fix as Qt5 above, but for KF5 build-time code generators —
# these were previously symlinked into a `host-tools/` dir that got deleted
# during an earlier cleanup pass (it looked like dead gettext-only cruft, but
# it was also the symlink target for these). Native tools + symlink over the
# sysroot's expected (aarch64, unusable on the host) paths, same as Qt5.
mkdir -p "$SYSROOT/usr/lib/libexec/kf5" "$SYSROOT/usr/lib/kauth/libexec" "$SYSROOT/usr/lib/aarch64-linux-gnu/libexec/kf5"
ln -sf /usr/lib/libexec/kf5/kconfig_compiler_kf5              "$SYSROOT/usr/lib/libexec/kf5/kconfig_compiler_kf5"
ln -sf /usr/bin/meinproc5                                     "$SYSROOT/usr/bin/meinproc5"
ln -sf /usr/bin/checkXML5                                     "$SYSROOT/usr/bin/checkXML5"
ln -sf /usr/bin/desktoptojson                                 "$SYSROOT/usr/bin/desktoptojson"
ln -sf /usr/lib/kauth/libexec/kauth-policy-gen                "$SYSROOT/usr/lib/kauth/libexec/kauth-policy-gen"
ln -sf /usr/lib/x86_64-linux-gnu/libexec/kf5/kconf_update      "$SYSROOT/usr/lib/aarch64-linux-gnu/libexec/kf5/kconf_update"

# Debian's blas/lapack alternatives indirection (/etc/alternatives/...) was
# never rsynced from the Pi, leaving lib/aarch64-linux-gnu/lib{blas,lapack}.so.3
# dangling (the usr/lib/aarch64-linux-gnu copies resolve fine via a different,
# relative symlink chain — only the top-level lib/ copies are affected).
ln -sf /home/soo/cc/rpi5-sysroot/usr/lib/aarch64-linux-gnu/blas/libblas.so.3.11.0     "$SYSROOT/lib/aarch64-linux-gnu/libblas.so.3"
ln -sf /home/soo/cc/rpi5-sysroot/usr/lib/aarch64-linux-gnu/lapack/liblapack.so.3.11.0 "$SYSROOT/lib/aarch64-linux-gnu/liblapack.so.3"

echo "fix-env: native Qt5 + KF5 tools + gettext installed, sysroot symlinks fixed."
