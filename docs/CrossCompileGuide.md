# Cross-Compiling for Raspberry Pi 5 on Debian 12 (Bookworm)

> **Superseded by the `Makefile`.** The project has since been restructured: source
> repos live under `repo/` (plain git clones, not submodules), INDI staging is split into
> `rpi5-staging/indi` and `rpi5-staging/indi-3rdparty`, INDI now packages as **two**
> `.deb`s (`indi-core-rpi5` + `indi-3rdparty-rpi5`, not one combined `indi-full-rpi5`),
> and output goes to `deb/`. Paths and commands below (`~/cc/indi`, one combined INDI
> deb, etc.) are the original narrative and no longer match exactly — run `make help`
> and see `docs/BUILD-AND-PACKAGE.md` for the current, authoritative steps. Kept here
> for the reasoning behind the sysroot/toolchain setup, which is unchanged.

## Overview

This guide covers setting up a cross-compilation environment on an Ubuntu host to build aarch64 binaries for Raspberry Pi 5 running Debian Bookworm. We use a Debian Bookworm Docker container as the build environment to ensure GCC 12 and GLIBC 2.36 compatibility with the Pi.

The key problem this guide solves: Ubuntu 24.04 ships GCC 13 which automatically uses `__isoc23_*` symbols (GLIBC 2.38) even when targeting older systems. The Pi runs GLIBC 2.36, so binaries built on the host directly will fail to run. Using a Debian Bookworm container with GCC 12 avoids this entirely.

---

## Prerequisites

- Ubuntu 24.04 host (or any modern Linux)
- Raspberry Pi 5 running Raspberry Pi OS Bookworm 64-bit (Debian 12)
- SSH access to the Pi
- Docker installed on the host

---

## 1. Install Docker on the Host

```bash
sudo apt install -y docker.io
sudo usermod -aG docker $USER
newgrp docker
```

---

## 2. Set Up Directory Structure

```bash
mkdir -p ~/cc/rpi5-sysroot
mkdir -p ~/cc/rpi5-staging
```

- `rpi5-sysroot` — copy of Pi's libraries and headers used during compilation
- `rpi5-staging` — installation prefix where built files are collected before packaging

---

## 3. Sync the Sysroot from the Pi

The sysroot is a copy of the Pi's filesystem libraries and headers. The cross compiler uses it to find aarch64 libraries during linking.

On the Pi, install development libraries first:

```bash
sudo apt install -y \
    libusb-1.0-0-dev \
    libcurl4-openssl-dev \
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
    zlib1g-dev
```

Then on the host, sync the sysroot:

```bash
PI_USER=soo
PI_IP=your.pi.ip.address

rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/usr/lib/aarch64-linux-gnu \
    ~/cc/rpi5-sysroot/usr/lib/

rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/usr/include \
    ~/cc/rpi5-sysroot/usr/

rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/lib/aarch64-linux-gnu \
    ~/cc/rpi5-sysroot/lib/

rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/usr/share/pkgconfig \
    ~/cc/rpi5-sysroot/usr/share/
```

After syncing, fix broken symlinks in the sysroot using `symlinks`:

```bash
sudo apt install -y symlinks
symlinks -cr ~/cc/rpi5-sysroot
```

---

## 4. Create the CMake Toolchain File

Create `~/cc/rpi5-toolchain.cmake` with absolute paths — avoid `$ENV{HOME}` since this file is used inside a Docker container where HOME resolves differently:

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(SYSROOT /home/soo/cc/rpi5-sysroot)
set(STAGING /home/soo/cc/rpi5-staging)

set(CMAKE_SYSROOT ${SYSROOT})

set(CMAKE_C_COMPILER   /usr/bin/aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER /usr/bin/aarch64-linux-gnu-g++)
set(CMAKE_AR           /usr/bin/aarch64-linux-gnu-ar)
set(CMAKE_STRIP        /usr/bin/aarch64-linux-gnu-strip)

set(CMAKE_FIND_ROOT_PATH ${STAGING} ${SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(ENV{PKG_CONFIG_SYSROOT_DIR} ${SYSROOT})
set(ENV{PKG_CONFIG_LIBDIR}
    ${STAGING}/usr/lib/pkgconfig:${STAGING}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/share/pkgconfig)

set(RPATH_LINK
    "-Wl,-rpath-link,${STAGING}/usr/lib \
     -Wl,-rpath-link,${SYSROOT}/usr/lib/aarch64-linux-gnu \
     -Wl,-rpath-link,${SYSROOT}/lib/aarch64-linux-gnu")

set(CMAKE_C_FLAGS
    "--sysroot=${SYSROOT} -march=armv8.2-a+crypto+fp16 -mtune=cortex-a76"
    CACHE STRING "")
set(CMAKE_CXX_FLAGS
    "--sysroot=${SYSROOT} -march=armv8.2-a+crypto+fp16 -mtune=cortex-a76"
    CACHE STRING "")
set(CMAKE_EXE_LINKER_FLAGS
    "--sysroot=${SYSROOT} ${RPATH_LINK}"
    CACHE STRING "")
set(CMAKE_SHARED_LINKER_FLAGS
    "--sysroot=${SYSROOT} ${RPATH_LINK}"
    CACHE STRING "")
set(CMAKE_MODULE_LINKER_FLAGS
    "--sysroot=${SYSROOT} ${RPATH_LINK}"
    CACHE STRING "")
```

Key points about this toolchain file:

- `CMAKE_SYSROOT` tells CMake where to find aarch64 libraries and headers
- `--sysroot` in compiler and linker flags prevents the compiler from falling back to host libraries
- `CMAKE_FIND_ROOT_PATH_MODE_*` set to `ONLY` prevents CMake from searching host paths
- `PKG_CONFIG_LIBDIR` points pkg-config exclusively at aarch64 pkgconfig files
- `-march=armv8.2-a` and `-mtune=cortex-a76` optimize for the Pi 5's CPU

---

## 5. Set Up the Debian Bookworm Docker Container

This is the critical step. Using a Debian Bookworm container ensures GCC 12 is used, which matches the Pi's native compiler and does not generate GLIBC 2.38 symbols.

```bash
# Create the container, mounting the cc directory
docker run -it --name rpi5-builder \
    -v $HOME/cc:/home/soo/cc \
    debian:bookworm bash
```

Inside the container, install the cross toolchain:

```bash
apt update && apt install -y \
    gcc-aarch64-linux-gnu \
    g++-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    cmake \
    make \
    ninja-build \
    pkg-config \
    rsync \
    file \
    python3

# Verify GCC version — must be 12.x
aarch64-linux-gnu-gcc --version
```

Verify the GLIBC version the cross compiler targets:

```bash
echo '#include <stdio.h>
int main() { int x; sscanf("123", "%d", &x); return 0; }' > /tmp/test.c

aarch64-linux-gnu-gcc \
    --sysroot=/home/soo/cc/rpi5-sysroot \
    /tmp/test.c -o /tmp/test-aarch64

objdump -p /tmp/test-aarch64 | grep GLIBC
```

The highest version shown must be `GLIBC_2.36` or lower. If you see `GLIBC_2.38` the compiler is leaking host symbols and something is wrong with the sysroot or toolchain flags.

---

## 6. Build indi-core Inside the Container

```bash
# Clone the source on the host first if not already done
# git clone https://github.com/indilib/indi.git ~/cc/indi

# Inside the container
mkdir -p /home/soo/cc/indi/build-rpi5
cd /home/soo/cc/indi/build-rpi5

cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=/home/soo/cc/rpi5-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_PREFIX_PATH="/home/soo/cc/rpi5-staging/usr;/home/soo/cc/rpi5-sysroot/usr" \
    -DINDI_BUILD_SERVER=ON \
    -DINDI_BUILD_CLIENT=ON \
    -DINDI_BUILD_DRIVERS=ON \
    -DINDI_BUILD_UNITTESTS=OFF \
    -DINDI_BUILD_INTEGTESTS=OFF

make -j$(nproc) 2>&1 | tee /home/soo/cc/indi-core-build.log
make install DESTDIR=/home/soo/cc/rpi5-staging
```

---

## 7. Verify the Built Binaries

Before deploying, confirm no GLIBC symbols above 2.36 leaked in:

```bash
objdump -p /home/soo/cc/rpi5-staging/usr/bin/indiserver | grep GLIBC
```

Confirm the binary is aarch64:

```bash
file /home/soo/cc/rpi5-staging/usr/bin/indiserver
# Should show: ELF 64-bit LSB pie executable, ARM aarch64
```

---

## 8. Package as a Debian Package

Rather than deploying a raw tarball — which risks overwriting system files — package everything as a proper deb:

```bash
# Inside the container
mkdir -p /home/soo/cc/rpi5-indi-deb/DEBIAN
cp -a /home/soo/cc/rpi5-staging/. /home/soo/cc/rpi5-indi-deb/
rm -rf /home/soo/cc/rpi5-indi-deb/DEBIAN
mkdir -p /home/soo/cc/rpi5-indi-deb/DEBIAN

INSTALLED_SIZE=$(du -sk /home/soo/cc/rpi5-indi-deb | cut -f1)

cat > /home/soo/cc/rpi5-indi-deb/DEBIAN/control << EOF
Package: indi-full-rpi5
Version: 2.2.1
Architecture: arm64
Maintainer: soo
Installed-Size: $INSTALLED_SIZE
Depends: libusb-1.0-0, libcurl4, libgphoto2-6, libjpeg62-turbo, libfftw3-double3, libfftw3-single3, libgsl27, libftdi1-2, libev4, libogg0, libtheora0, libdc1394-25, libzmq5, libudev1, libblas3, liblapack3, libgps28, libcfitsio10, libnova-0.16-0, libavcodec59, libavdevice59, libavformat59, libavutil57, libswscale6, libgphoto2-port12
Description: INDI astronomy framework with all drivers for Raspberry Pi 5
 Full INDI 2.2.1 installation including core framework, all third party
 drivers and vendor SDKs cross-compiled for Raspberry Pi 5 aarch64
 using Debian Bookworm toolchain (GCC 12, GLIBC 2.36).
EOF

cat > /home/soo/cc/rpi5-indi-deb/DEBIAN/postinst << 'EOF'
#!/bin/bash
set -e
ldconfig
setcap cap_net_raw+ep /usr/bin/indi_pentax || true
udevadm control --reload-rules || true
udevadm trigger || true
EOF
chmod 755 /home/soo/cc/rpi5-indi-deb/DEBIAN/postinst

cat > /home/soo/cc/rpi5-indi-deb/DEBIAN/postrm << 'EOF'
#!/bin/bash
set -e
ldconfig
EOF
chmod 755 /home/soo/cc/rpi5-indi-deb/DEBIAN/postrm

dpkg-deb --build --root-owner-group \
    /home/soo/cc/rpi5-indi-deb \
    /home/soo/cc/rpi5-indi_2.2.1_arm64.deb
```

---

## 9. Deploy to the Pi

```bash
scp /home/soo/cc/rpi5-indi_2.2.1_arm64.deb $PI_USER@$PI_IP:/tmp/
ssh $PI_USER@$PI_IP "sudo apt install /tmp/rpi5-indi_2.2.1_arm64.deb"
```

Verify on the Pi:

```bash
ssh $PI_USER@$PI_IP

file /usr/bin/indiserver
ldconfig -p | grep libindi
indiserver -v indi_simulator_telescope
```

---

## Common Pitfalls

**GLIBC version mismatch** — Always build inside a Debian Bookworm container, never directly on Ubuntu 24.04. Ubuntu's GCC 13 silently links against GLIBC 2.38 symbols.

**Tarball overwriting system files** — Never deploy a raw tarball of the entire staging directory with `tar xzf -C /`. Always use `dpkg` or carefully filter the tarball to only include your built files.

**`$ENV{HOME}` in toolchain file** — This resolves to `/root` inside a Docker container, breaking all sysroot paths. Always use absolute paths in the toolchain file.

**`setcap` during cross-compile install** — `setcap` is not DESTDIR-aware and will fail during `make install` on the host. Use `make -k install` to continue past the error and run `setcap` in the `postinst` script after deployment.

**Sysroot symlinks** — After rsyncing the sysroot, always run `symlinks -cr ~/cc/rpi5-sysroot` to convert absolute symlinks to relative ones, otherwise the linker cannot follow them.

**pkg-config picking up host libraries** — Always set `PKG_CONFIG_SYSROOT_DIR` and `PKG_CONFIG_LIBDIR` in the toolchain file to point exclusively at sysroot paths.
