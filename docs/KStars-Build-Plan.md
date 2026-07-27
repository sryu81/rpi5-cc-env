# Cross-Compiling KStars 3.8.3 for Raspberry Pi 5

## Goal

Cross-compile stock upstream KStars for RPi5 aarch64. INDI's built-in `indiweb` WebSocket
interface is used for INDI device communication — no custom work needed there.

Separate staging dirs keep INDI and KStars builds independent.

> **Note:** earlier drafts of this doc planned a KStars fork with a custom WebSocket
> server (`git checkout v3.7.1` + "add your WebSocket server code here"). That never
> happened — the actual tree built and packaged (`kstars-custom_3.8.3_arm64.deb`) is
> stock upstream `kde/kstars.git` on the `stable-3.8.3` branch, no fork, no custom code.
> This doc now reflects what's actually built. If the WebSocket fork is still planned,
> it hasn't been started yet — treat it as a separate future task, not something already
> baked into this pipeline.

> **Also superseded by the `Makefile`.** Source now lives at `repo/stellarsolver` and
> `repo/kstars` (git submodules), staging is `rpi5-staging/kstars`, packaging output is
> `deb/kstars-custom_3.8.3_arm64.deb`, and `kstars-custom`'s `Depends` now points at
> `indi-core-rpi5` (INDI packages split into two `.deb`s). Run `make help` and see
> `docs/BUILD-AND-PACKAGE.md` for the current, authoritative steps. Kept here for the
> StellarSolver/KStars-specific reasoning (Qt5 tools fix, gettext fix, GLIBC ceiling),
> which is unchanged.

---

## Step 1: Create KStars staging directory

```bash
mkdir -p ~/cc/rpi5-staging-kstars
```

The existing `rpi5-staging` stays untouched (INDI only).

---

## Step 2: Install -dev packages on Pi

Most likely already installed (KStars built directly on Pi). Verify or install:

```bash
sudo apt install -y \
    build-essential cmake git \
    libeigen3-dev \
    libcfitsio-dev \
    zlib1g-dev \
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
    libnova-dev \
    libgsl-dev \
    libraw-dev \
    wcslib-dev \
    libsecret-1-dev \
    breeze-icon-theme \
    libcurl4-gnutls-dev
```

---

## Step 3: Re-sync sysroot from Pi

On the host, re-sync to include all KStars/KF5/Qt5 dev packages:

```bash
PI_USER=soo
PI_IP=<your.pi.ip.address>

# aarch64 shared libs (overwrite existing)
rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/usr/lib/aarch64-linux-gnu \
    ~/cc/rpi5-sysroot/usr/lib/

# headers
rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/usr/include \
    ~/cc/rpi5-sysroot/usr/

# linker scripts
rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/lib/aarch64-linux-gnu \
    ~/cc/rpi5-sysroot/lib/

# pkgconfig
rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/usr/share/pkgconfig \
    ~/cc/rpi5-sysroot/usr/share/

# cmake configs — critical for Qt5/KF5/ECM detection
rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/usr/lib/aarch64-linux-gnu/cmake \
    ~/cc/rpi5-sysroot/usr/lib/aarch64-linux-gnu/cmake

rsync -avz --rsync-path="sudo rsync" \
    $PI_USER@$PI_IP:/usr/lib/cmake \
    ~/cc/rpi5-sysroot/usr/lib/cmake
```

Fix symlinks:

```bash
sudo apt install -y symlinks
symlinks -cr ~/cc/rpi5-sysroot
```

Verify key cmake configs exist:

```bash
find ~/cc/rpi5-sysroot/usr -name "Qt5Config.cmake"
find ~/cc/rpi5-sysroot/usr -name "KF5ConfigConfig.cmake"
find ~/cc/rpi5-sysroot/usr -name "ECMConfig.cmake"
```

If any are missing, find them on the Pi and rsync manually:
```bash
# On Pi:
find /usr -name "Qt5Config.cmake" 2>/dev/null
```

---

## Step 3.5: Fix host build tools inside the container (REQUIRED, do this every time the container is recreated)

The rsynced sysroot's Qt5/KF5 cmake configs (`Qt5CoreConfigExtras.cmake` etc.) hardcode
`IMPORTED_LOCATION` for `Qt5::moc`, `Qt5::uic`, `Qt5::rcc`, `Qt5::qmake`, and `qdbusxml2cpp`
as absolute paths **inside the sysroot** (e.g.
`rpi5-sysroot/usr/lib/aarch64-linux-gnu/qt5/bin/moc`) — because that's where they live on
the real Pi. Those are aarch64 binaries. If CMake/make ever needs to execute one of them
during the build (moc runs constantly; `qdbusxml2cpp`/`qdbuscpp2xml` run once per DBus
adaptor, e.g. KStars' `focusadaptor.cpp`, `alignadaptor.cpp`, etc.), it tries to exec an
aarch64 ELF on an x86_64 host. Without a working QEMU binfmt + sysroot wiring, this fails as:

```
aarch64-binfmt-P: Could not open '/lib/ld-linux-aarch64.so.1': No such file or directory
gmake[2]: *** [kstars/CMakeFiles/KStarsLib.dir/build.make:423: kstars/focusadaptor.cpp] Error 255
```

**Fix — install native x86 Qt5 tools and symlink over the sysroot copies instead of fighting QEMU:**

```bash
apt install -y qtbase5-dev-tools qttools5-dev-tools qt5-qmake

SYSQT=/home/soo/cc/rpi5-sysroot/usr/lib/aarch64-linux-gnu/qt5/bin
ln -sf /usr/lib/qt5/bin/moc          "$SYSQT/moc"
ln -sf /usr/lib/qt5/bin/uic          "$SYSQT/uic"
ln -sf /usr/lib/qt5/bin/rcc          "$SYSQT/rcc"
ln -sf /usr/lib/qt5/bin/qdbusxml2cpp "$SYSQT/qdbusxml2cpp"
ln -sf /usr/lib/qt5/bin/qdbuscpp2xml "$SYSQT/qdbuscpp2xml"
ln -sf /usr/bin/qmake                "$SYSQT/qmake"
ln -sf /usr/bin/qmake                /home/soo/cc/rpi5-sysroot/usr/lib/qt5/bin/qmake
```

This makes CMake still "find" the tool at the path its config expects, but actually run
the host-native x86 binary — no QEMU/binfmt involved. These are text-generation tools only
(they never link into the Pi binary and never run on the Pi), so this has **zero effect on
target GLIBC versioning** — the GLIBC ceiling is set entirely by the cross-compiler and the
sysroot's own `libc.so.6`/`libstdc++.so.6` (see Potential Issue #3 below).

**Also required — native `gettext` for KF5I18n po-file generation:**

If a previous configure ever set `GETTEXT_MSGFMT_EXECUTABLE`/`GETTEXT_MSGMERGE_EXECUTABLE`
to some other, non-apt gettext build lying around on the host, `CMakeCache.txt` will keep
reusing that stale path forever (cmake caches found-program paths). If that binary is
missing or ABI-incompatible (e.g. a foreign-distro build linked against a `libunistring`
soname bookworm doesn't ship), the KF5I18n po-generation step fails:

```
/path/to/msgfmt: error while loading shared libraries: libgettextsrc-0.21.so: cannot open shared object file
CMake Error at .../KF5I18n/build-pofiles.cmake:24 (message): failed generating .../kstars/po
```

Fix — install Debian's own gettext and force CMake to use it:

```bash
apt install -y gettext

cd /home/soo/cc/kstars/build-rpi5
cmake .. -DGETTEXT_MSGFMT_EXECUTABLE=/usr/bin/msgfmt -DGETTEXT_MSGMERGE_EXECUTABLE=/usr/bin/msgmerge
```

**Both of these fixes are container-instance-local** — they live in packages/symlinks
inside the container's own root filesystem, not in the bind-mounted `~/cc`. Recreating the
container (`docker rm` + `docker run`, or even a `docker restart` after certain host
reboots) wipes them, and the next build will hit the exact same two failures. Re-apply this
step every time before building StellarSolver or KStars in a fresh container.

---

## Step 4: Cross-compile StellarSolver 2.6

StellarSolver is needed for plate-solving. It depends on Qt5, cfitsio, gsl, wcslib — all now in sysroot.

```bash
cd ~/cc
git clone --branch 2.6 --depth 1 https://github.com/rlancaste/stellarsolver.git
mkdir -p stellarsolver/build-rpi5
cd stellarsolver/build-rpi5

cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=/home/soo/cc/rpi5-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_PREFIX_PATH="/home/soo/cc/rpi5-staging-kstars/usr;/home/soo/cc/rpi5-sysroot/usr" \
    -DBUILD_TESTER=OFF

make -j$(nproc) 2>&1 | tee /home/soo/cc/stellarsolver-build.log
make install DESTDIR=/home/soo/cc/rpi5-staging-kstars
```

Verify:
```bash
file ~/cc/rpi5-staging-kstars/usr/lib/libstellarsolver.so*
objdump -p ~/cc/rpi5-staging-kstars/usr/lib/libstellarsolver.so.2.6 | grep GLIBC
```

---

## Step 5: Clone and cross-compile KStars

```bash
cd ~/cc
git clone https://github.com/kde/kstars.git
cd kstars
git checkout stable-3.8.3
```

No fork, no custom code — this is stock upstream KStars, built as-is.

Then cross-compile:

```bash
mkdir -p build-rpi5
cd build-rpi5

cmake .. \
    -DCMAKE_TOOLCHAIN_FILE=/home/soo/cc/rpi5-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_PREFIX_PATH="/home/soo/cc/rpi5-staging-kstars/usr;/home/soo/cc/rpi5-sysroot/usr" \
    -DStellarSolver_DIR=/home/soo/cc/rpi5-staging-kstars/usr/lib/cmake/StellarSolver \
    -DBUILD_WITH_QT6=OFF \
    -DBUILD_TESTING=OFF

make -j$(nproc) 2>&1 | tee /home/soo/cc/kstars-build.log
make install DESTDIR=/home/soo/cc/rpi5-staging-kstars
```

---

## Step 6: Package as .deb

Start from a **fresh** copy of the staging dir and strip build cruft — `make install` puts
things in there that must never ship in a runtime package:

```bash
rm -rf /home/soo/cc/kstars-deb
mkdir -p /home/soo/cc/kstars-deb/DEBIAN
cp -a /home/soo/cc/rpi5-staging-kstars/usr /home/soo/cc/kstars-deb/

# drop build-only artifacts — these are NOT runtime files:
rm -f  /home/soo/cc/kstars-deb/usr/lib/libhtmesh.a   # static lib, never needed at runtime
rm -rf /home/soo/cc/kstars-deb/usr/lib/cmake         # dev-only cmake configs (StellarSolver etc.)
rm -rf /home/soo/cc/kstars-deb/usr/lib/pkgconfig     # dev-only .pc files

# strip debug info — unstripped binaries bloat the package hugely (indi-full-rpi5
# shipped 348/360 ELF files unstripped once and ballooned to 184MB; don't repeat that)
aarch64-linux-gnu-strip /home/soo/cc/kstars-deb/usr/bin/kstars
aarch64-linux-gnu-strip /home/soo/cc/kstars-deb/usr/lib/libstellarsolver.so.2.6
```

**Getting `Depends` right — don't guess, verify against the real Pi.** List every `NEEDED`
soname from the actual binary, then look up which package really owns each one **on the
target Pi itself** (`ssh soo@<pi-ip>`, package names/versions on the build host can differ):

```bash
objdump -p /home/soo/cc/kstars-deb/usr/bin/kstars | grep NEEDED | awk '{print $2}' | sort -u

# for each soname, on the Pi:
ssh soo@<pi-ip> "dpkg -S /usr/lib/aarch64-linux-gnu/<soname>"
```

Two sonames will NOT resolve to a system package — that's expected, handle them differently:
- `libstellarsolver.so.2` — no apt package exists (StellarSolver isn't in Debian/Raspbian).
  It's already bundled in `usr/lib/` above, from our own build. Do **not** add a `Depends`
  for it — a `libstellarsolver2` Debian package doesn't exist, and the version already
  installed on some Pis (StellarSolver 2.4, if built there separately) has a different path
  (`/usr/lib/aarch64-linux-gnu/`) and won't satisfy or conflict with our bundled 2.6 copy.
- `libindiclient.so.2` — this is INDI's own client lib, confirmed via `dpkg -S` on the real
  Pi to be owned by our own `indi-full-rpi5` package (see `CrossCompileGuide.md`). Depend on
  that package directly instead of bundling the `.so` a second time.

```bash
INSTALLED_SIZE=$(du -sk /home/soo/cc/kstars-deb/usr | cut -f1)

cat > /home/soo/cc/kstars-deb/DEBIAN/control << EOF
Package: kstars-custom
Version: 3.8.3
Section: science
Priority: optional
Architecture: arm64
Maintainer: soo
Installed-Size: \$INSTALLED_SIZE
Depends: libqt5core5a, libqt5gui5, libqt5widgets5, libqt5sql5, libqt5svg5, libqt5websockets5, libqt5network5, libqt5dbus5, libqt5printsupport5, libqt5quick5, libqt5qml5, libqt5concurrent5, libqt5datavisualization5, libkf5xmlgui5, libkf5i18n5, libkf5configcore5, libkf5configgui5, libkf5configwidgets5, libkf5coreaddons5, libkf5widgetsaddons5, libkf5notifications5, libkf5notifyconfig5, libkf5kiocore5, libkf5kiowidgets5, libkf5plotting5, libkf5newstuff5, libgsl27, libopencv-core406, libopencv-imgproc406, libopencv-calib3d406, libqt5keychain1, libraw20, libwcs7, libcfitsio10, zlib1g, indi-full-rpi5 (>= 2.2.1)
Description: KStars 3.8.3 custom aarch64 build for RPi5
 Cross-compiled for Raspberry Pi 5 (Debian 12 Bookworm, GCC 12, GLIBC 2.36
 max). Bundles StellarSolver 2.6 for plate-solving. Requires indi-full-rpi5
 for libindiclient.
EOF

cat > /home/soo/cc/kstars-deb/DEBIAN/postinst << 'EOF'
#!/bin/bash
set -e
ldconfig
update-desktop-database /usr/share/applications || true
EOF
chmod 755 /home/soo/cc/kstars-deb/DEBIAN/postinst

cat > /home/soo/cc/kstars-deb/DEBIAN/postrm << 'EOF'
#!/bin/bash
set -e
ldconfig
update-desktop-database /usr/share/applications || true
EOF
chmod 755 /home/soo/cc/kstars-deb/DEBIAN/postrm

dpkg-deb --build --root-owner-group \
    /home/soo/cc/kstars-deb \
    /home/soo/cc/kstars-custom_3.8.3_arm64.deb
```

`postinst`/`postrm` are **not optional** — without them, icon/desktop caches never refresh
and shared libs `kstars` itself installs never get registered via `ldconfig`. A `dpkg-deb -I`
on the built package should always show a `postinst`/`postrm` line, not just `control`.

---

## Step 7: Deploy to Pi

```bash
scp /home/soo/cc/kstars-custom_3.8.3_arm64.deb soo@<pi-ip>:/tmp/
ssh soo@<pi-ip> "sudo apt install /tmp/kstars-custom_3.8.3_arm64.deb"
```

Verify on Pi:
```bash
ssh soo@<pi-ip>
kstars --version
file /usr/bin/kstars
objdump -p /usr/bin/kstars | grep GLIBC
```

---

## Potential Issues

1. **KF5 cmake configs missing after sync** — Most likely failure. Verify with:
   ```bash
   find ~/cc/rpi5-sysroot/usr -name "KF5ConfigConfig.cmake"
   ```
   If missing, rsync from Pi or set `-DCMAKE_FIND_ROOT_PATH` to include Pi's cmake dirs.

2. **Qt5 moc/uic/rcc/qdbusxml2cpp try to exec aarch64 binaries via QEMU and fail** —
   `apt install qtbase5-dev-tools qttools5-dev-tools qt5-qmake` alone is NOT enough — the
   sysroot's Qt5 cmake configs still point at the sysroot's own aarch64 tool copies. You
   must also symlink those sysroot paths over to the newly-installed native tools. See
   **Step 3.5** for the exact commands and the `Could not open '/lib/ld-linux-aarch64.so.1'`
   error this produces if skipped. Container-instance-local — redo after every container
   recreation.

2b. **KF5I18n po-file generation fails with a `libunistring`/`libgettextsrc` error** — a
   stale `CMakeCache.txt` entry for `GETTEXT_MSGFMT_EXECUTABLE` pointing at some old,
   foreign-built gettext. Install Debian's own `gettext` and pass
   `-DGETTEXT_MSGFMT_EXECUTABLE=/usr/bin/msgfmt -DGETTEXT_MSGMERGE_EXECUTABLE=/usr/bin/msgmerge`
   on reconfigure. See Step 3.5.

3. **GLIBC leak** — Verify every built binary:
   ```bash
   objdump -p /path/to/binary | grep GLIBC
   ```
   Max must be GLIBC_2.36 — confirmed via `ssh soo@<pi-ip> "ldd --version"` (Pi runs
   `2.36-9+rpt2+deb12u13`) and by diffing sha256 of the sysroot's `libc.so.6` against the
   Pi's real one (must match byte-for-byte, since that's what actually gets linked against —
   the cross toolchain's own `libc6-dev-arm64-cross` package version number is irrelevant).
   Installing native x86 Qt5/gettext build tools per Step 3.5 has **zero effect** on this —
   those tools run at build time on the host only, never link into or run on the Pi binary.

4. **StellarSolver cmake detection** — If KStars can't find it:
   ```bash
   -DStellarSolver_DIR=/home/soo/cc/rpi5-staging-kstars/usr/lib/cmake/StellarSolver
   ```

5. **kinit DESTDIR issue** — `kinit` may fail during install. Use `make -k install` to continue past errors.

6. **WebSocket support, if a fork is ever built** — not currently in use (see the note at
   the top of this doc — no fork exists yet, stock KStars is what's built today). If/when
   a WebSocket server is added: Qt5 WebSockets is already in the sysroot and linked in
   (`libQt5WebSockets.so.5` is in `kstars-custom`'s `Depends`). Use `QT += websockets` in
   a `.pro` file or `find_package(Qt5WebSockets)` in CMake. The INDI websocket interface
   (`indiweb`) runs separately on port 8080 regardless.
