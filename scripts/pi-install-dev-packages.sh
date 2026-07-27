#!/bin/bash
# Runs on the HOST — ssh's into the Pi and installs every -dev package the
# sysroot sync needs headers/pkgconfig for. Union of the package lists from
# docs/CrossCompileGuide.md §3 (INDI) and docs/KStars-Build-Plan.md §2
# (StellarSolver/KStars/KF5/Qt5) — kept in one place here instead of two docs.
# Usage: pi-install-dev-packages.sh <user@pi-ip>
set -euo pipefail

PI="$1"

ssh "$PI" 'sudo apt update && sudo apt install -y \
    build-essential cmake git \
    libusb-1.0-0-dev \
    libcurl4-openssl-dev \
    libcurl4-gnutls-dev \
    libgsl-dev \
    libjpeg-dev \
    libfftw3-dev \
    libev-dev \
    libtheora-dev \
    libnova-dev \
    libcfitsio-dev \
    libgphoto2-dev \
    libavcodec-dev \
    libavdevice-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    libzmq3-dev \
    libudev-dev \
    libblas-dev \
    liblapack-dev \
    libgps-dev \
    libdc1394-dev \
    librtlsdr-dev \
    libogg-dev \
    libftdi1-dev \
    libraw-dev \
    zlib1g-dev \
    libeigen3-dev \
    extra-cmake-modules \
    qtbase5-dev \
    qtdeclarative5-dev \
    libqt5svg5-dev \
    libqt5websockets5-dev \
    libqt5datavisualization5-dev \
    qttools5-dev \
    qttools5-dev-tools \
    libqt5keychain1 \
    libkf5plotting-dev \
    libkf5xmlgui-dev \
    libkf5kio-dev \
    libkf5newstuff-dev \
    libkf5notifications-dev \
    libkf5crash-dev \
    libkf5notifyconfig-dev \
    libkf5iconthemes-dev \
    libkf5doctools-dev \
    libkf5i18n-dev \
    libkf5config-dev \
    libkf5widgetsaddons-dev \
    libkf5auth-dev \
    kinit-dev \
    libkf5windowsystem-dev \
    gettext \
    wcslib-dev \
    libsecret-1-dev \
    breeze-icon-theme'

echo "pi-install-dev-packages: done on $PI"
