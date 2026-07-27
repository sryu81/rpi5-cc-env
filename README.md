# RPi5 INDI / INDI 3rd-party / KStars cross-compile

Cross-compiles INDI (core + 3rd-party), StellarSolver, and KStars on an x86_64 host for
Raspberry Pi 5 (Debian 12 Bookworm, aarch64), inside a Docker container `rpi5-builder`,
and packages each as a `.deb`.

Full narrative + rationale: **`docs/BUILD-AND-PACKAGE.md`** (start here). Deeper
per-project detail: `docs/CrossCompileGuide.md` (INDI), `docs/KStars-Build-Plan.md`
(StellarSolver/KStars).

## Layout

```
repo/                   git submodules — the actual source trees
  indi/                 github.com/indilib/indi.git
  indi-3rdparty/        github.com/indilib/indi-3rdparty.git
  kstars/                github.com/kde/kstars.git
  stellarsolver/         github.com/rlancaste/stellarsolver.git

rpi5-sysroot/            synced copy of the Pi's own libs/headers/cmake configs (input,
                         not build output — see docs/BUILD-AND-PACKAGE.md)

rpi5-staging/            make install DESTDIR= trees (build output, input to packaging)
  indi/                  indi-core install tree
  indi-3rdparty/         indi-3rdparty install tree
  kstars/                stellarsolver + kstars install tree (shared, kstars links stellarsolver)

deb/                     final .deb packages + scratch packaging dirs

scripts/                 one script per build/package stage, invoked by the Makefiles
Makefile                 orchestrates build/package/deploy — see `make help`
Makefile.sysroot         reproduces rpi5-sysroot/ from the Pi — see `make -f Makefile.sysroot help`

rpi5-toolchain.cmake     cross-compile CMake toolchain file
docs/                    all narrative documentation
```

`rpi5-sysroot/` and `rpi5-staging/` are **gitignored** — several GB of binary blobs
(synced system libs / compiled output), a bad fit for git, and fully regenerable from
what *is* tracked: `rpi5-sysroot/` from the Pi (`Makefile.sysroot`), `rpi5-staging/`
from the `repo/*` submodules (`make build`).

## Quick start

```bash
make help
make submodules                              # git submodule update --init --recursive, if repo/* is empty
make -f Makefile.sysroot reproduce PI_IP=<pi-ip>  # only on first setup, or after installing new -dev pkgs on the Pi
make fix-env                                 # required after every rpi5-builder container recreation
make build                                   # build+install everything, no packaging
make package                                 # package everything into .debs (builds first if needed)
make all                                     # build + package
make verify                                  # check GLIBC ceiling on all three built .debs
make deploy PI_IP=<pi-ip>
```

`rpi5-sysroot/` is **never auto-synced** by any build target — if it's missing (fresh
clone) or stale (new `-dev` package installed on the Pi that a build now needs), run
`make -f Makefile.sysroot reproduce PI_IP=<pi-ip>` yourself first. A missing/stale
sysroot just surfaces as a normal cmake/link error, not a Makefile error telling you to
sync it.
