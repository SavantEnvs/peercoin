#!/usr/bin/env bash
#
# mayhem/build.sh — build peercoin's libFuzzer fuzz binary (+ standalone reproducer) and the
# boost unit-test runner. Runs inside the commit image as `mayhem` in /mayhem; safe to re-run offline.
#
# Peercoin (a Bitcoin Core fork) ships ONE fuzz binary holding every harness; the harness is selected
# at start-up by the FUZZ environment variable. Each Mayhemfile therefore runs /mayhem/peercoin-fuzz
# with `env: FUZZ: <harness>`.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT=/mayhem

# The generated autotools files are gitignored upstream, so regenerate them when missing (git clean -X).
[ -f configure ] || ./autogen.sh

CONFIG_COMMON=(--disable-wallet --without-gui --disable-bench --disable-man --disable-zmq
               --without-miniupnpc --without-natpmp)

# 1) Test suite with the project's NORMAL flags (out-of-tree, mayhem/build-test is gitignored).
mkdir -p mayhem/build-test
(
  cd mayhem/build-test
  unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  [ -f Makefile ] || ../../configure "${CONFIG_COMMON[@]}" --enable-tests --disable-fuzz-binary \
      CC="$CC" CXX="$CXX" CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" >/dev/null
  make -C src -j"$MAYHEM_JOBS" test/test_peercoin
)

# 2) Fuzz build: whole project sanitized + DWARF 3 + libFuzzer coverage instrumentation.
mkdir -p mayhem/build-fuzz
(
  cd mayhem/build-fuzz
  unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  [ -f Makefile ] || ../../configure "${CONFIG_COMMON[@]}" --enable-fuzz --with-sanitizers=fuzzer \
      CC="$CC" CXX="$CXX" CFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS" >/dev/null
  make -C src -j"$MAYHEM_JOBS" test/fuzz/fuzz
  # Re-derive libtool's link line so the same objects can be relinked with the extra TUs and the
  # standalone driver.
  rm -f src/test/fuzz/fuzz
  make -C src V=1 test/fuzz/fuzz | sed -n 's/^libtool: link: //p' > "$SRC/mayhem/build-fuzz/link.cmd"
)

# 3) Extra TUs: LeakSanitizer off + default harness when FUZZ is unset.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o mayhem/build-fuzz/lsan_off.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/default_target.cc" -o mayhem/build-fuzz/default_target.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o mayhem/build-fuzz/standalone_main.o

link_cmd=$(cat mayhem/build-fuzz/link.cmd)
cd mayhem/build-fuzz/src
# libFuzzer binary
eval "${link_cmd//-o test\/fuzz\/fuzz/-o $OUT/peercoin-fuzz} ../lsan_off.o ../default_target.o"
# standalone reproducer: same objects, run-once driver instead of the libFuzzer runtime
standalone_cmd="${link_cmd//-fsanitize=fuzzer/}"
eval "${standalone_cmd//-o test\/fuzz\/fuzz/-o $OUT/peercoin-fuzz-standalone} ../lsan_off.o ../default_target.o ../standalone_main.o"
