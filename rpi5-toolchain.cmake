set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# Passed in via -DSYSROOT=... by every scripts/build-*.sh (never $ENV{HOME} —
# that resolves to /root inside the container, not the bind-mounted repo root).
if(NOT DEFINED SYSROOT)
  message(FATAL_ERROR "SYSROOT not set — pass -DSYSROOT=<path-to-rpi5-sysroot>")
endif()

# try_compile() (e.g. compiler ABI detection) re-reads this file in a scratch project that only
# receives the variables listed here — without it a re-detection hits the FATAL_ERROR above.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES SYSROOT)

set(CMAKE_SYSROOT ${SYSROOT})

set(CMAKE_C_COMPILER   /usr/bin/aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER /usr/bin/aarch64-linux-gnu-g++)
set(CMAKE_AR           /usr/bin/aarch64-linux-gnu-ar)
set(CMAKE_STRIP        /usr/bin/aarch64-linux-gnu-strip)

# There are three separate staging trees now (rpi5-staging/{indi,indi-3rdparty,
# kstars}) and no single one is correct for every build — each build passes
# the staging dir(s) IT needs via -DCMAKE_PREFIX_PATH=... on the cmake command
# line (see scripts/build-*.sh). Derive every other search path from THAT
# variable instead of a single hardcoded staging path baked in here — a
# hardcoded path was exactly the bug that broke cross-linking after the
# rpi5-staging split (indi-3rdparty drivers failed with "cannot find -lusbp-1"
# because this file still pointed at a staging layout that no longer existed).
set(CMAKE_FIND_ROOT_PATH ${CMAKE_PREFIX_PATH} ${SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(ENV{PKG_CONFIG_SYSROOT_DIR} ${SYSROOT})

set(_pkgconfig_dirs "")
set(_library_path_dirs "${SYSROOT}/lib/aarch64-linux-gnu" "${SYSROOT}/usr/lib/aarch64-linux-gnu")
set(_rpath_link_flags "")
set(_L_flags "")
foreach(_prefix ${CMAKE_PREFIX_PATH})
  list(APPEND _pkgconfig_dirs "${_prefix}/lib/pkgconfig" "${_prefix}/lib/aarch64-linux-gnu/pkgconfig")
  list(APPEND _library_path_dirs "${_prefix}/lib")
  set(_rpath_link_flags "${_rpath_link_flags} -Wl,-rpath-link,${_prefix}/lib")
  set(_L_flags "${_L_flags} -L${_prefix}/lib")
endforeach()
list(APPEND _pkgconfig_dirs "${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig" "${SYSROOT}/usr/share/pkgconfig")

string(REPLACE ";" ":" _pkgconfig_dirs_str "${_pkgconfig_dirs}")
set(ENV{PKG_CONFIG_LIBDIR} "${_pkgconfig_dirs_str}")

# ENV{LIBRARY_PATH} only affects processes cmake itself spawns during
# configure (e.g. try_compile) — it does NOT persist into the separate,
# later `make` invocation that actually runs the linker, so it's not
# sufficient on its own. Real fix: explicit -L flags baked directly into
# the CACHE STRING linker flags below, which DO get written into every
# generated link rule and so persist across separate make invocations.
string(REPLACE ";" ":" _library_path_str "${_library_path_dirs}")
set(ENV{LIBRARY_PATH} "${_library_path_str}")

set(RPATH_LINK
    "${_L_flags} ${_rpath_link_flags} -L${SYSROOT}/usr/lib/aarch64-linux-gnu -L${SYSROOT}/lib/aarch64-linux-gnu -Wl,-rpath-link,${SYSROOT}/usr/lib/aarch64-linux-gnu -Wl,-rpath-link,${SYSROOT}/lib/aarch64-linux-gnu")

set(SYSROOT_INCLUDE
    "-isystem ${SYSROOT}/usr/include/aarch64-linux-gnu -isystem ${SYSROOT}/usr/include")

set(CMAKE_C_FLAGS
    "--sysroot=${SYSROOT} ${SYSROOT_INCLUDE} -march=armv8.2-a+crypto+fp16 -mtune=cortex-a76 -std=gnu17 -D_GNU_SOURCE"
    CACHE STRING "")
set(CMAKE_CXX_FLAGS
    "--sysroot=${SYSROOT} ${SYSROOT_INCLUDE} -march=armv8.2-a+crypto+fp16 -mtune=cortex-a76 -std=gnu++17 -D_GNU_SOURCE"
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
