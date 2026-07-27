#!/bin/bash
# Runs on the HOST (plain objdump reads foreign-arch ELF headers fine).
# Usage: verify-glibc.sh <path-to-binary-or-.so>
set -euo pipefail

BIN="$1"
echo "== $BIN =="
file "$BIN"
MAXGLIBC=$(objdump -p "$BIN" | grep -oE "GLIBC_[0-9.]+" | sort -V -u | tail -1 || true)
MAXCXX=$(objdump -p "$BIN" | grep -oE "GLIBCXX_[0-9.]+" | sort -V -u | tail -1 || true)
echo "Max GLIBC symbol:   ${MAXGLIBC:-none}"
echo "Max GLIBCXX symbol: ${MAXCXX:-none}"
echo "Ceiling (real Pi, ssh-verified): GLIBC_2.36"
