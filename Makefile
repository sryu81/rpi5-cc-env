# Build & package INDI, INDI 3rd-party, and KStars for Raspberry Pi 5.
#
# Build/package steps run inside the rpi5-builder Docker container (cross
# toolchain, sysroot, cmake all live there). Deploy steps run on the host
# directly (ssh/scp to the Pi). See docs/BUILD-AND-PACKAGE.md for the full
# narrative and rationale behind every step here.
#
# Layout:
#   repo/<name>          - plain independent git clones (indi, indi-3rdparty, kstars,
#                          stellarsolver) — gitignored, NOT submodules of this repo.
#                          `make clone-repos` to (re)clone. Local patches on top live
#                          in patches/ (tracked here) and self-apply on every build.
#   rpi5-sysroot/         - synced copy of the Pi's own libs/headers/cmake configs
#   rpi5-staging/indi          - indi-core install tree (DESTDIR)
#   rpi5-staging/indi-3rdparty - indi-3rdparty install tree (DESTDIR)
#   rpi5-staging/kstars         - stellarsolver + kstars install tree (DESTDIR, shared)
#   deb/                  - final .deb packages (and scratch packaging dirs)
#
# Note: rpi5-sysroot/ is never auto-synced — if it's missing or stale, use
# Makefile.sysroot (a separate file — reproducing the sysroot from the Pi is a
# distinct concern from the day-to-day build/package loop here) to regenerate
# it: `make -f Makefile.sysroot reproduce PI_IP=<ip>`. Build targets in THIS
# Makefile don't check for it; a missing/stale sysroot just fails as a
# cmake/link error, not a Makefile error.
#
# Usage:
#   make bootstrap                 # new machine: create container + clone repos + fix-env
#   make fix-env                  # required after every container recreation
#   make indi-core-deb            # build+package indi-core-rpi5_*.deb
#   make indi-3rdparty-deb        # build+package indi-3rdparty-rpi5_*.deb (needs core)
#   make kstars-deb               # build stellarsolver + kstars, package .deb
#   make all                      # everything above
#   make deploy PI_IP=10.0.0.43
#   make verify                   # check GLIBC ceiling on all three built .debs

# Directory containing this Makefile — NOT hardcoded, so the whole pipeline
# works regardless of where this repo is cloned (was hardcoded /home/soo/cc,
# which broke on any other machine/username/path).
CCDIR      := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
CONTAINER  ?= rpi5-builder
DEXEC      := docker exec $(CONTAINER)
SCRIPTS    := $(CCDIR)/scripts
DEB        := $(CCDIR)/deb

PI_USER    ?= soo
PI_IP      ?= 10.0.0.43
PI         := $(PI_USER)@$(PI_IP)

INDI_CORE_DEB       := $(DEB)/indi-core-rpi5_2.2.1-1nocturne1_arm64.deb
INDI_3RDPARTY_DEB    := $(DEB)/indi-3rdparty-rpi5_2.2.1_arm64.deb
KSTARS_DEB           := $(DEB)/kstars-custom_3.8.3_arm64.deb

.PHONY: help all build package bootstrap docker-container fix-env clone-repos \
        indi-core indi-3rdparty-libs indi-3rdparty-drivers \
        indi-core-deb indi-3rdparty-deb \
        stellarsolver kstars kstars-deb \
        deploy-indi-core deploy-indi-3rdparty deploy-kstars deploy \
        verify clean clean-staging distclean

TOOLCHAIN_PKGS := gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
                   cmake make ninja-build pkg-config rsync file python3

help:
	@echo "Targets:"
	@echo "  bootstrap             - one-shot new-machine setup: docker-container + clone-repos + fix-env"
	@echo "  docker-container      - create rpi5-builder container if missing, start it if stopped"
	@echo "  clone-repos           - clone repo/{indi,indi-3rdparty,kstars,stellarsolver} if missing (plain clones, not submodules)"
	@echo "  (sysroot reproduction lives in Makefile.sysroot, not here — see 'make -f Makefile.sysroot help')"
	@echo "  fix-env               - install native Qt5 tools + gettext in the container, fix sysroot symlinks"
	@echo "  indi-core             - configure/build/install INDI core into rpi5-staging/indi"
	@echo "  indi-3rdparty-libs    - configure/build/install INDI 3rd-party libs"
	@echo "  indi-3rdparty-drivers - configure/build/install INDI 3rd-party drivers"
	@echo "  indi-core-deb         - package rpi5-staging/indi into indi-core-rpi5_2.2.1-1nocturne1_arm64.deb"
	@echo "  indi-3rdparty-deb     - package rpi5-staging/indi-3rdparty into indi-3rdparty-rpi5_2.2.1_arm64.deb"
	@echo "  stellarsolver         - configure/build/install StellarSolver 2.6"
	@echo "  kstars                - configure/build/install KStars"
	@echo "  kstars-deb            - package rpi5-staging/kstars into kstars-custom_3.8.3_arm64.deb"
	@echo "  build                 - build+install everything (indi-core, indi-3rdparty, stellarsolver, kstars), NO packaging"
	@echo "  package               - package everything into .debs (builds first if needed)"
	@echo "  all                   - build + package, in dependency order"
	@echo "  deploy-indi-core      - scp+install indi-core .deb on the Pi (PI_IP=$(PI_IP))"
	@echo "  deploy-indi-3rdparty  - scp+install indi-3rdparty .deb on the Pi"
	@echo "  deploy-kstars         - scp+install the KStars .deb on the Pi"
	@echo "  deploy                - all three of the above, in dependency order"
	@echo "  verify                - check GLIBC ceiling on all three built .debs"
	@echo "  clean                 - wipe repo/*/build-* cmake build trees (keeps staging + deb/ output)"
	@echo "  clean-staging         - clean + wipe rpi5-staging/* and deb/*-pkg scratch dirs (keeps final .debs)"
	@echo "  distclean             - clean-staging + wipe deb/ entirely (final .debs too) + build logs"

# build: compile + install everything, no packaging. package: package everything
# into .debs (each package target already depends on its build target, so this
# builds anything not already built — but `build` alone never invokes dpkg-deb).
build: indi-3rdparty-drivers kstars

package: indi-core-deb indi-3rdparty-deb kstars-deb

all: build package

# ---- bootstrap (new machine, runs on the HOST) ---------------------------
# Does NOT reproduce rpi5-sysroot/ — that needs a live Pi (PI_IP) and is a
# separate, rarely-run concern (see Makefile.sysroot). Run after bootstrap:
#   make -f Makefile.sysroot reproduce PI_IP=<ip>

bootstrap: docker-container clone-repos fix-env
	@echo "bootstrap done. Still needed: make -f Makefile.sysroot reproduce PI_IP=<ip>"

docker-container:
	@if [ -z "$$(docker ps -aq -f name=^/$(CONTAINER)$$)" ]; then \
		echo "creating $(CONTAINER) container..."; \
		docker run -d --name $(CONTAINER) -v $(CCDIR):$(CCDIR) debian:bookworm sleep infinity; \
		$(DEXEC) bash -c "apt-get update && apt-get install -y $(TOOLCHAIN_PKGS)"; \
	elif [ -z "$$(docker ps -q -f name=^/$(CONTAINER)$$)" ]; then \
		echo "starting stopped $(CONTAINER) container..."; \
		docker start $(CONTAINER); \
	else \
		echo "$(CONTAINER) container already running"; \
	fi

# ---- source repos (plain git clones, not submodules — runs on the HOST) ----

clone-repos:
	@mkdir -p $(CCDIR)/repo
	test -d $(CCDIR)/repo/indi          || git clone https://github.com/sryu81/indi.git $(CCDIR)/repo/indi
	test -d $(CCDIR)/repo/indi-3rdparty || git clone https://github.com/sryu81/indi-3rdparty.git $(CCDIR)/repo/indi-3rdparty
	test -d $(CCDIR)/repo/kstars        || (git clone https://github.com/sryu81/kstars.git $(CCDIR)/repo/kstars && git -C $(CCDIR)/repo/kstars checkout stable-3.8.3)
	test -d $(CCDIR)/repo/stellarsolver || git clone https://github.com/sryu81/stellarsolver.git $(CCDIR)/repo/stellarsolver

# ---- environment ------------------------------------------------------

fix-env:
	$(DEXEC) bash $(SCRIPTS)/fix-env.sh

# ---- INDI ---------------------------------------------------------------

indi-core: fix-env
	$(DEXEC) bash $(SCRIPTS)/build-indi-core.sh

indi-3rdparty-libs: indi-core
	$(DEXEC) bash $(SCRIPTS)/build-indi-3rdparty-libs.sh

indi-3rdparty-drivers: indi-3rdparty-libs
	$(DEXEC) bash $(SCRIPTS)/build-indi-3rdparty-drivers.sh

indi-core-deb: indi-core
	@mkdir -p $(DEB)
	$(DEXEC) bash $(SCRIPTS)/package-indi-core.sh

indi-3rdparty-deb: indi-3rdparty-drivers indi-core-deb
	@mkdir -p $(DEB)
	$(DEXEC) bash $(SCRIPTS)/package-indi-3rdparty.sh

# ---- StellarSolver + KStars ----------------------------------------------

stellarsolver: fix-env
	$(DEXEC) bash $(SCRIPTS)/build-stellarsolver.sh

kstars: stellarsolver
	$(DEXEC) bash $(SCRIPTS)/build-kstars.sh

kstars-deb: kstars
	@mkdir -p $(DEB)
	$(DEXEC) bash $(SCRIPTS)/package-kstars.sh

# ---- verify -------------------------------------------------------------

verify:
	@rm -rf /tmp/verify-indi-core /tmp/verify-indi-3rdparty /tmp/verify-kstars
	@dpkg-deb -x $(INDI_CORE_DEB) /tmp/verify-indi-core
	@dpkg-deb -x $(INDI_3RDPARTY_DEB) /tmp/verify-indi-3rdparty
	@dpkg-deb -x $(KSTARS_DEB) /tmp/verify-kstars
	@bash $(SCRIPTS)/verify-glibc.sh /tmp/verify-indi-core/usr/bin/indiserver
	@bash $(SCRIPTS)/verify-glibc.sh /tmp/verify-indi-3rdparty/usr/bin/indi_pentax
	@bash $(SCRIPTS)/verify-glibc.sh /tmp/verify-kstars/usr/bin/kstars
	@rm -rf /tmp/verify-indi-core /tmp/verify-indi-3rdparty /tmp/verify-kstars

# ---- deploy (runs on the HOST — needs ssh/scp to the Pi, not the container) ----

deploy-indi-core:
	scp $(INDI_CORE_DEB) $(PI):/tmp/
	ssh $(PI) "sudo apt install -y /tmp/$(notdir $(INDI_CORE_DEB))"

deploy-indi-3rdparty: deploy-indi-core
	scp $(INDI_3RDPARTY_DEB) $(PI):/tmp/
	ssh $(PI) "sudo apt install -y /tmp/$(notdir $(INDI_3RDPARTY_DEB))"

deploy-kstars: deploy-indi-core
	scp $(KSTARS_DEB) $(PI):/tmp/
	ssh $(PI) "sudo apt install -y /tmp/$(notdir $(KSTARS_DEB))"

deploy: deploy-indi-3rdparty deploy-kstars

# ---- cleanup --------------------------------------------------------------
# Three tiers, each stricter than the last:
#   clean         - cmake build trees only (repo/*/build-*). Cheapest to regenerate
#                   for a single component (reconfigure + make), keeps everything else.
#   clean-staging - clean + install (DESTDIR) trees + packaging scratch dirs. Needs a
#                   full rebuild of whichever component you touch before repackaging,
#                   but keeps already-built final .debs around.
#   distclean     - clean-staging + deb/ wiped entirely (final .debs too) + build logs.
#                   Back to source-only. Does NOT touch rpi5-sysroot/ (that's synced
#                   input from the Pi, not build output — see docs/BUILD-AND-PACKAGE.md).

clean:
	$(DEXEC) rm -rf $(CCDIR)/repo/indi/build-rpi5 \
	                 $(CCDIR)/repo/indi-3rdparty/build-libs-rpi5 \
	                 $(CCDIR)/repo/indi-3rdparty/build-drivers-rpi5 \
	                 $(CCDIR)/repo/stellarsolver/build-rpi5 \
	                 $(CCDIR)/repo/kstars/build-rpi5

clean-staging: clean
	$(DEXEC) rm -rf $(CCDIR)/rpi5-staging/indi $(CCDIR)/rpi5-staging/indi-3rdparty $(CCDIR)/rpi5-staging/kstars \
	                 $(DEB)/indi-core-rpi5-pkg $(DEB)/indi-3rdparty-rpi5-pkg $(DEB)/kstars-custom-pkg

distclean: clean-staging
	$(DEXEC) rm -rf $(DEB)
	rm -f $(CCDIR)/*.log
