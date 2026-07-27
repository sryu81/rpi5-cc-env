# RPi5 INDI / INDI 3rd-party / KStars cross-compile

Cross-compiles INDI (core + 3rd-party), StellarSolver, and KStars on an x86_64 host for
Raspberry Pi 5 (Debian 12 Bookworm, aarch64), inside a Docker container `rpi5-builder`,
and packages each as a `.deb`.

Full narrative + rationale: **`docs/BUILD-AND-PACKAGE.md`** (start here). Deeper
per-project detail: `docs/CrossCompileGuide.md` (INDI), `docs/KStars-Build-Plan.md`
(StellarSolver/KStars).

## Layout

```
repo/                   plain independent git clones (NOT submodules) — the source trees
  indi/                 github.com/indilib/indi.git, tag v2.2.1.1
  indi-3rdparty/        github.com/indilib/indi-3rdparty.git, master
  kstars/                github.com/kde/kstars.git, stable-3.8.3 branch
  stellarsolver/         github.com/rlancaste/stellarsolver.git, tag 2.6

patches/                 local fixes on top of repo/*, tracked here (never inside
                         repo/* itself) — applied automatically + idempotently by the
                         relevant build script on every run, see docs/BUILD-AND-PACKAGE.md

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

`rpi5-sysroot/`, `rpi5-staging/`, and `repo/` are all **gitignored** — several GB of
binary blobs / third-party source, a bad fit for git, and fully regenerable: `repo/`
via plain `git clone` (`make clone-repos`), `rpi5-sysroot/` from the Pi
(`Makefile.sysroot`), `rpi5-staging/` by building `repo/*` (`make build`). Local fixes
on top of `repo/*` live in `patches/` (tracked, applied automatically) so nothing is
lost by re-cloning.

## Quick start

```bash
make help
make clone-repos                             # clone repo/{indi,indi-3rdparty,kstars,stellarsolver}, if missing
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
