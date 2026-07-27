# Building & Packaging INDI, INDI 3rd-Party, and KStars for Raspberry Pi 5

Summary of the whole pipeline: cross-compile INDI core, INDI 3rd-party libs/drivers,
StellarSolver, and KStars on an x86_64 host, package each as a `.deb`, deploy to the Pi.
Everything here is now driven by the top-level `Makefile` — run `make help` for the
full target list. This doc explains *why* the Makefile does what it does.

Deeper per-project detail (kept for narrative/history, some paths superseded by the
layout below — the Makefile/scripts are the source of truth for exact paths):
`CrossCompileGuide.md` (INDI), `KStars-Build-Plan.md` (StellarSolver/KStars).

---

## Layout

```
repo/indi, repo/indi-3rdparty, repo/kstars, repo/stellarsolver   plain git clones, gitignored (source) — NOT submodules
patches/                                                          local fixes on top of repo/*, tracked here, self-applied
rpi5-sysroot/                                                     synced Pi filesystem (input)
rpi5-staging/{indi, indi-3rdparty, kstars}                        make install DESTDIR= trees (output)
deb/                                                               final .deb packages
```

`repo/*` are deliberately plain `git clone`s, not git submodules — regenerate with
`make clone-repos` (idempotent, skips any that already exist). Any local fix on top of
upstream lives in `patches/` in *this* repo, never committed inside `repo/*` itself, and
is applied automatically + idempotently by the relevant build script on every run (see
"Local patch" notes below) — so wiping and re-cloning `repo/*` loses nothing.

`rpi5-staging` is split per-component because **INDI now packages as two separate
`.deb`s** — `indi-core-rpi5` and `indi-3rdparty-rpi5` (the latter `Depends:` on the
former) — rather than one combined `indi-full-rpi5`. StellarSolver and KStars still
share one staging dir (`rpi5-staging/kstars`) since KStars links StellarSolver directly
and there's no reason to split a package that's always installed together.

`rpi5-toolchain.cmake` does **not** hardcode any of these staging paths — it derives
its `-rpath-link`/`LIBRARY_PATH`/`PKG_CONFIG_LIBDIR`/`CMAKE_FIND_ROOT_PATH` search paths
from whatever `CMAKE_PREFIX_PATH` each `scripts/build-*.sh` passes in on the `cmake`
command line. This matters: there are three separate staging trees and no single one is
correct for every build (indi-3rdparty needs both its own staging *and* indi-core's).
An earlier version hardcoded one staging path and broke cross-linking silently — see
Potential Issue below.

---

## 0. Environment (one-time, host)

- Docker container `rpi5-builder`, image `debian:bookworm` — gives GCC 12 / GLIBC 2.36,
  matching the Pi exactly (Ubuntu 24.04 host GCC 13 would silently emit GLIBC 2.38 symbols).
  ```bash
  docker run -it --name rpi5-builder -v $HOME/cc:/home/soo/cc debian:bookworm bash
  ```
- Cross toolchain in container: `gcc-aarch64-linux-gnu g++-aarch64-linux-gnu
  binutils-aarch64-linux-gnu cmake make ninja-build pkg-config rsync file python3`
- Sysroot at `rpi5-sysroot/`: reproduced from the real Pi via a **separate** Makefile —
  `make -f Makefile.sysroot reproduce PI_IP=<ip>` (installs every `-dev` package the
  build needs on the Pi, then rsyncs libs/headers/cmake configs, fixes symlinks, and
  patches the blas/lapack alternatives gap — see `make -f Makefile.sysroot help`). Kept
  separate from the main `Makefile` on purpose: reproducing the sysroot is a distinct,
  rarely-run concern from the day-to-day build/package loop, and `rpi5-sysroot/` is
  gitignored (multi-GB binary blobs, fully regenerable — this is how you regenerate it).
- Toolchain file `rpi5-toolchain.cmake` — absolute paths only (never `$ENV{HOME}`,
  it resolves to `/root` inside the container).

### GLIBC ceiling — verified against the real Pi, not assumed

The Pi runs **GLIBC 2.36** (`Debian GLIBC 2.36-9+rpt2+deb12u13`, confirmed via
`ssh soo@<pi-ip> "ldd --version"`). Every cross-compiled binary must stay at or below
`GLIBC_2.36`/`GLIBCXX_3.4.30` — `make verify` checks this automatically.
The sysroot's `lib/aarch64-linux-gnu/libc.so.6` is a byte-for-byte copy of the Pi's real
`libc.so.6` (sha256 verified) — that's what actually gets linked against, so it's the
authoritative source of truth, not the version number of the container's generic
`libc6-dev-arm64-cross` package.

### Required after every container recreation — `make fix-env`

Both fixes below live in the container's own root filesystem, **not** the bind-mounted
`~/cc` — so recreating `rpi5-builder` wipes them silently, and the next build hits the
same two failures. `scripts/fix-env.sh`:

1. **Native Qt5 build tools.** The sysroot's Qt5 cmake configs hardcode
   `Qt5::moc`/`uic`/`rcc`/`qmake`/`qdbusxml2cpp` as the sysroot's own **aarch64**
   binaries. Executing one during the build tries to run an aarch64 ELF on x86_64 via
   QEMU/binfmt and fails: `Could not open '/lib/ld-linux-aarch64.so.1'`. Fix: install
   native tools (`qtbase5-dev-tools qttools5-dev-tools qt5-qmake`), symlink the
   sysroot's tool paths over to them — these only generate `.cpp` source at build time,
   never linked into or run on the Pi binary, so **no effect on the GLIBC ceiling**.
2. **Native gettext.** A stale `CMakeCache.txt` entry for `GETTEXT_MSGFMT_EXECUTABLE`
   pointing at some other, foreign-built gettext breaks KF5I18n po-file generation
   (`libunistring`/`libgettextsrc` load error). Fix: `apt install gettext`, pass
   `-DGETTEXT_MSGFMT_EXECUTABLE=/usr/bin/msgfmt -DGETTEXT_MSGMERGE_EXECUTABLE=/usr/bin/msgmerge`
   on reconfigure (`scripts/build-kstars.sh` already does this).
3. **Git "dubious ownership".** `repo/*` (plain clones) are bind-mounted from the host
   (owned by the host UID) but accessed as root inside the container — git refuses to
   run anything against a repo it doesn't consider "owned" by the current user,
   including the `git describe` call INDI's `CMakeLists.txt` uses for its version
   string (`fatal: detected dubious ownership in repository at '/home/soo/cc/repo/indi'`).
   Fix: `git config --global --add safe.directory '*'`.

---

## 1. INDI core — `make indi-core` / `make indi-core-deb`

`scripts/build-indi-core.sh` builds `repo/indi` into `rpi5-staging/indi`.
`scripts/package-indi-core.sh` packages it as `deb/indi-core-rpi5_2.2.1_arm64.deb` —
`indiserver`, `libindi`, `libindiclient`, and the bundled simulator/basic drivers. Drops
`usr/include`, `*.a` static libs, and `usr/lib/pkgconfig` first — `make install` puts
dev-only artifacts in the same staging tree as the runtime files; never ship them.

**Local patch on top of the pinned `v2.2.1.1` tag:** `drivers/auxiliary/wandererbox_plus_v3.cpp`
and `wandererbox_pro_v3.cpp` call bare `isnan(...)` — GCC 12 with `<cmath>` doesn't inject
that into the global namespace, only `std::isnan`, so it fails to compile
(`'isnan' was not declared in this scope`). This is a real upstream bug, not a
cross-compile artifact. Tracked as `patches/indi-glibc-isnan.patch` (in this repo, NOT
committed inside `repo/indi`, which is a plain clone not a submodule) and applied
automatically + idempotently by `scripts/build-indi-core.sh` via `scripts/apply-patch.sh`
before every configure — a `repo/indi` reset/re-clone no longer loses the fix, the next
build self-heals it.

`Depends` derived from an `objdump -p` `NEEDED` scan of every binary in
`rpi5-staging/indi`, cross-checked against the real Pi's `dpkg` database
(`ssh soo@<pi-ip> "dpkg -S <path>"`) — not guessed:
```
libcfitsio10, libcurl4, libev4, libfftw3-double3, libgslcblas0, libgsl27,
libjpeg62-turbo, libnova-0.16-0, libogg0, librtlsdr0, libtheora0, libudev1, libusb-1.0-0
```

## 2. INDI 3rd-party — `make indi-3rdparty-drivers` / `make indi-3rdparty-deb`

Libs then drivers, in that order (drivers link against the libs), both against
`indi-core`'s already-installed headers/libs in `rpi5-staging/indi`:
```bash
make indi-3rdparty-libs      # scripts/build-indi-3rdparty-libs.sh
make indi-3rdparty-drivers   # scripts/build-indi-3rdparty-drivers.sh (depends on the above)
```
`setcap` is not `DESTDIR`-aware and fails during install if attempted here — deferred to
`postinst` on the Pi instead (`indi_pentax` lives in 3rd-party, not core).

`scripts/package-indi-3rdparty.sh` packages `rpi5-staging/indi-3rdparty` as
`deb/indi-3rdparty-rpi5_2.2.1_arm64.deb`, `Depends: indi-core-rpi5 (>= 2.2.1), ...`.
Same dev-artifact stripping as indi-core (`usr/include`, `*.a`, `usr/lib/pkgconfig`).
The ~40 closed-source vendor camera SDKs (`libASICamera2.so`, `libqhyccd.so.20`,
`libtoupcam.so`, etc.) are **bundled** inside this tree, not system deps — confirmed by
checking each `NEEDED` soname against files actually present in the staging tree before
looking it up on the Pi. Only genuine external libs get a `Depends` entry:
```
indi-core-rpi5 (>= 2.2.1), libcfitsio10, libcurl4, libdc1394-25, libftdi1-2,
libgphoto2-6, libgphoto2-port12, libgps28, libjpeg62-turbo, liblimesuite22.09-1,
libnova-0.16-0, libraw20, libudev1, libusb-1.0-0, libzmq5
```

## 3. StellarSolver 2.6 — `make stellarsolver`

Needed for plate-solving, installs into `rpi5-staging/kstars` (shared with KStars):
```bash
make stellarsolver   # scripts/build-stellarsolver.sh, depends on fix-env
```

**Local patch:** `CMakeLists.txt`'s default `qsort_r` feature detection uses `try_run()`,
which can't execute a cross-compiled test binary on the build host. Tracked as
`patches/stellarsolver-cross-compile-qsort_r.patch` (adds a `CMAKE_CROSSCOMPILING`
branch with hardcoded, known-correct values instead of guessing; also covers the
generated `os-features-config.h` and an `ioutils.c` include guard) — applied
automatically + idempotently by the build script, same mechanism as INDI's `isnan` fix.
This one predates this session's work (found already applied, not authored by Claude).

## 4. KStars — `make kstars` / `make kstars-deb`

```bash
make kstars       # scripts/build-kstars.sh, depends on stellarsolver
make kstars-deb   # scripts/package-kstars.sh
```
Stock upstream KStars (`repo/kstars`, `stable-3.8.3` branch) — no fork, no custom
WebSocket code (that's still-unstarted future work, see project memory). If the build
fails with the QEMU/binfmt or gettext errors from §0, run `make fix-env` and retry —
don't debug it as a KStars-specific problem, it isn't one.

**Local patch:** `kstars/auxiliary/rectangleoverlap.cpp` is missing `#include <limits>` —
same class of bug as INDI's `isnan` fix (GCC 12 not transitively pulling in a header
another translation unit used to provide). Tracked as
`patches/kstars-rectangleoverlap-limits.patch`, applied automatically + idempotently.
Also predates this session (found already applied, not authored by Claude).

`scripts/package-kstars.sh` drops build-only artifacts before packaging
(`libhtmesh.a`, dev `cmake`/`pkgconfig` dirs) and strips the binary + bundled
`libstellarsolver.so.2.6` — an unstripped build here once produced a 184MB package.
`Depends: ..., indi-core-rpi5 (>= 2.2.1)` for `libindiclient.so.2`.

---

## 5. Deploy — `make deploy PI_IP=<pi-ip>`

INDI core installs first (both 3rd-party and KStars `Depends` on it):
```bash
make deploy-indi-core
make deploy-indi-3rdparty   # depends on deploy-indi-core
make deploy-kstars          # depends on deploy-indi-core
# or just: make deploy
```

Verify on the Pi:
```bash
ssh soo@<pi-ip>
file /usr/bin/indiserver /usr/bin/kstars
objdump -p /usr/bin/indiserver | grep GLIBC
objdump -p /usr/bin/kstars     | grep GLIBC
indiserver -v indi_simulator_telescope
kstars --version
```

---

## Getting `Depends` right for a new/changed package — don't guess

```bash
objdump -p <staging-dir>/usr/bin/<binary> | grep NEEDED | awk '{print $2}' | sort -u
ssh soo@<pi-ip> "dpkg -S /usr/lib/aarch64-linux-gnu/<soname>"   # per soname, on the REAL Pi
```
Two classes of soname will NOT resolve to a system package on the Pi — check the
staging tree itself before concluding a lib is missing:
- **Bundled vendor libs** (StellarSolver, the INDI 3rd-party camera SDKs) — already
  shipped inside the same staging tree; don't add a `Depends`, don't bundle twice.
- **Our own other packages** (`libindiclient.so.2` from `indi-core-rpi5`) — depend on
  the package name directly, confirmed via `dpkg -S` on the real Pi.

---

## Potential issue: `ld: cannot find -l<something>` when building indi-3rdparty-drivers

Hit this once after the `rpi5-staging` split: `rpi5-toolchain.cmake` used to hardcode a
single `STAGING` path baked into its `RPATH_LINK`/`PKG_CONFIG_LIBDIR`/`LIBRARY_PATH`. Once
staging split into three separate trees, that hardcoded path stopped being valid for any
of them, and the linker silently couldn't find libraries built into the *other* two
staging trees a given driver needs (e.g. `indi-ticfocuser-ng` linking against
`libusbp-1` from `indi-3rdparty`'s own staging while also needing `indi-core`'s libs).

Fixed by deriving all of the toolchain file's search paths from `${CMAKE_PREFIX_PATH}`
(which each `scripts/build-*.sh` already passes correctly) instead of a hardcoded path.
If this class of error reappears, check `rpi5-toolchain.cmake` hasn't regressed back to
a hardcoded staging path — **and remember `CACHE STRING` toolchain variables are
sticky**: editing the toolchain file does NOT retroactively fix an already-configured
build dir. Run `make clean` (wipes `repo/*/build-*`) before rebuilding, every time the
toolchain file itself changes.

Note also: `-Wl,-rpath-link,...` and `set(ENV{LIBRARY_PATH} ...)` are **not** sufficient
to fix a bare `-l<name>` failure — the former only resolves *transitive* dependencies of
already-found libraries, the latter only affects processes `cmake` spawns during
configure, not the later separate `make`/link step. Real `-L<dir>` flags baked into the
`CACHE STRING` linker flags are what actually persist into every generated link rule.

## Potential issue: `ld: cannot find .../libc.so.6 inside <sysroot>` (file exists!)

If the sysroot's linker-script stub files (`usr/lib/aarch64-linux-gnu/libc.so`,
`libstdc++.so`, `libbsd.so` — tiny `GROUP(...)` text files, not the real `.so.N`
binaries) ever contain the local absolute `/home/soo/cc/rpi5-sysroot/...` prefix baked
into their `GROUP()` paths instead of sysroot-relative paths (`/lib/aarch64-linux-gnu/libc.so.6`),
`--sysroot=` double-prefixes them at link time and this exact confusing error results —
even though the target file genuinely exists. Check with:
```bash
grep -l "/home/soo/cc/rpi5-sysroot" rpi5-sysroot/usr/lib/aarch64-linux-gnu/*.so rpi5-sysroot/lib/aarch64-linux-gnu/*.so 2>/dev/null
```
Fix: `sed -i 's|/home/soo/cc/rpi5-sysroot||g'` on any matching file. A fresh
`make -f Makefile.sysroot sync` also fixes it (overwrites with unprefixed copies from the Pi).

## Potential issue: KF5 build tool "does not exist" at a sysroot path (KStars configure)

Same class of problem as the Qt5 moc/uic fix in §0, different tools:
`kconfig_compiler_kf5`, `meinproc5`, `checkXML5`, `desktoptojson`, `kauth-policy-gen`,
`kconf_update`. `fix-env.sh` installs native versions
(`libkf5config-dev-bin kdoctools5 libkf5coreaddons-dev libkf5auth-dev libkf5config-bin`)
and symlinks them over the sysroot's aarch64 paths. If one of these ever regresses
(e.g. because whatever they were symlinked to got cleaned up — this happened once when
a `host-tools/` dir was deleted as apparent cruft, but it was also a symlink target),
check with `find rpi5-sysroot -xtype l` **run inside the container** — running it on the
host gives false positives for every symlink pointing at a native container-only path.

## Potential issue: `CMake Error ... Imported target "StellarSolver::stellarsolver" includes non-existent path`

StellarSolver uses `install(EXPORT ...)`, which bakes the literal `CMAKE_INSTALL_PREFIX`
into its generated `StellarSolverTargets.cmake` — `DESTDIR` only relocates where files
physically land, it does NOT change what path gets recorded in exported config files.
Fix (already in `scripts/build-stellarsolver.sh`): `-DCMAKE_STAGING_PREFIX=$STAGE/usr`
instead of `make install DESTDIR=...` — this is the CMake mechanism built specifically
for cross-compile + staged installs, and makes exported configs point at the staging
path directly. If any other component ever adopts `install(EXPORT ...)`, it needs the
same treatment.
