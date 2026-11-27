#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# run.sh - build and run every Chapter 2 example. Self-cleaning, bounded by
# timeout, unique --file-prefix=ch02-*. Usage:  ./run.sh  [--no-first-look]
#
# Captured output: expected_output.txt   (./run.sh 2>&1 | tee expected_output.txt)
set -u
cd "$(dirname "$0")"
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
source "$ENV_SH"
export ENV_SH
LIBDIR=$(pkg-config --variable=libdir libdpdk)
EAL="--no-pci --no-huge -m 64"          # the minimal sandbox flags used everywhere
T="timeout -s INT -k 5 20"
PMDCOPY=$PWD/.ch02-pmds

cleanup() {
	pkill -INT -f 'file-prefix=ch02-' 2>/dev/null
	rm -rf /var/run/dpdk/ch02-* "$PMDCOPY" mesonapp/build-bad mesonapp/build-shared
	rmdir /run/ch02-tmp 2>/dev/null
	true
}
trap cleanup EXIT
strip_ansi() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
# run: echo the command (with the long paths shortened), run it, print rc
run() {
	echo "\$ $*" | sed "s|$LIBDIR|\$LIBDIR|g"
	stdbuf -oL -eL "$@" 2>&1 | strip_ansi
	echo "[exit code ${PIPESTATUS[0]}]"
}
section() { echo; echo "=================== $* ==================="; }

section "0. build everything (make, -Wall -Wextra)"
make -s clean
make -s all 2>&1 | strip_ansi
echo "[make exit code ${PIPESTATUS[0]}]"
ls -l hello args ports_ok ports_broken hello_shared verbose | awk '{printf "  %-13s %9d bytes\n", $9, $5}'

section "1. hello: helloworld from scratch"
run $T ./hello -l 0-1 $EAL --file-prefix=ch02-hello
run $T ./hello -l 0-1 $EAL --file-prefix=ch02-hello --vdev=net_null0

section "2. args: EAL options -- application options"
run $T ./args -l 0 $EAL --file-prefix=ch02-args -- --count 3 --name demo
echo "--- forgetting the -- separator: EAL sees --count and exits the process"
run $T ./args -l 0 $EAL --file-prefix=ch02-args --count 3 --name demo
echo "--- plain words (no leading dash) are not EAL options: EAL moves them behind its own"
run $T ./args foo -l 0 $EAL --file-prefix=ch02-args bar
echo "--- --help after -- reaches the application, not EAL"
run $T ./args -l 0 $EAL --file-prefix=ch02-args -- --help

section "3. the --whole-archive pitfall"
echo "--- link line difference (first 3 words of each):"
echo "  ports_ok:     $(pkg-config --libs --static libdpdk | tr ' ' '\n' | head -3 | sed "s|$LIBDIR|\$LIBDIR|" | tr '\n' ' ')"
echo "  ports_broken: same list with every -Wl,--whole-archive / -Wl,--no-whole-archive removed"
run $T ./ports_ok -l 0 $EAL --file-prefix=ch02-ok --vdev=net_null0 --vdev=net_ring0
run $T ./ports_broken -l 0 $EAL --file-prefix=ch02-broken --vdev=net_null0 --vdev=net_ring0
run $T ./ports_broken -l 0 $EAL --file-prefix=ch02-broken
echo "--- constructor functions present in each binary (nm, readelf):"
ctors() {
	local b=$1 sz
	sz=$(readelf -SW "$b" | awk '{for (i = 1; i <= NF; i++) if ($i == ".init_array") print $(i + 4)}')
	printf '  %-13s .init_array=%-4d log=%-3d bus=%d class=%d driver=%d\n' "$b" $(( 0x$sz / 8 )) \
		"$(nm "$b" | grep -c ' t __.*logtype$')" "$(nm "$b" | grep -c ' t businitfn_')" \
		"$(nm "$b" | grep -c ' t classinitfn_')" "$(nm "$b" | grep -cE ' t (vdrvinitfn|pcidrvinitfn)_')"
}
ctors ports_ok
ctors ports_broken
nm ports_ok | grep -E ' t (businitfn|vdrvinitfn)_(vdev|pci|pmd_null_drv|pmd_ring_drv)$' | sed 's/^/    /'
echo "--- dpdk-pmdinfo.py (reads the PMD info strings embedded in the binary):"
echo "  ports_ok:     $(dpdk-pmdinfo.py ./ports_ok | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d), "drivers in total; net PMDs:", " ".join(sorted(x["name"] for x in d if x["name"].startswith("net_"))))')"
echo "  ports_broken: $(dpdk-pmdinfo.py ./ports_broken | tr -d '\n')"

section "4. shared build: the insecure plugin path"
echo "\$ ldd ./hello_shared | grep librte"
ldd ./hello_shared | grep librte
run $T ./hello_shared -l 0 $EAL --in-memory --vdev=net_null0
run env LD_LIBRARY_PATH="$LIBDIR" $T ./hello_shared -l 0 $EAL --in-memory --vdev=net_null0
echo "--- -d with a driver copied to a safe directory does not help: the compiled-in"
echo "--- RTE_EAL_PMD_PATH ($(grep -o '"[^"]*"' "$DPDK_PREFIX/include/rte_build_config.h" | grep pmds | sed "s|$LIBDIR|\$LIBDIR|")) is still checked"
mkdir -p "$PMDCOPY" && chmod 755 "$PMDCOPY" && cp "$LIBDIR/dpdk/pmds-27.0/librte_net_null.so.27.0" "$PMDCOPY/"
run env LD_LIBRARY_PATH="$LIBDIR" $T ./hello_shared -l 0 $EAL --in-memory -d "$PMDCOPY/librte_net_null.so.27.0" --vdev=net_null0
echo "--- fix for this lab only: a private mount namespace where /tmp is a 0755 tmpfs"
echo "--- and only our own (0700) /tmp/claude-0 tree is bind-mounted back"
echo "\$ ls -ld /tmp /tmp/claude-0"
ls -ld /tmp /tmp/claude-0 | awk '{print "  "$1, $NF}'
echo "\$ unshare -m sh -c 'mount --make-rprivate / && ... && ./hello_shared -l 0 $EAL --in-memory --vdev=net_null0'"
LIBDIR=$LIBDIR timeout -k 5 30 unshare -m sh -c '
	mount --make-rprivate / &&
	mkdir -p /run/ch02-tmp && mount --bind /tmp /run/ch02-tmp &&
	mount -t tmpfs -o mode=0755 tmpfs /tmp &&
	mkdir -p /tmp/claude-0 && mount --bind /run/ch02-tmp/claude-0 /tmp/claude-0 &&
	echo "  inside: $(ls -ld /tmp | cut -c1-10) /tmp" &&
	LD_LIBRARY_PATH=$LIBDIR stdbuf -oL ./hello_shared -l 0 --no-pci --no-huge -m 64 --in-memory --vdev=net_null0' 2>&1 | strip_ansi
echo "[exit code ${PIPESTATUS[0]}]"

section "5. mesonapp: a two-file meson project"
( cd mesonapp &&
  rm -rf build &&
  echo "\$ meson setup build && ninja -C build" &&
  meson setup build 2>&1 | grep -E 'Project name|Run-time dependency|Build targets' &&
  ninja -C build 2>&1 | strip_ansi | grep -v '^ninja: Entering' )
run $T ./mesonapp/build/app -l 0-1 $EAL --file-prefix=ch02-meson --vdev=net_null0
echo "--- the pitfall variant: declare_dependency(link_args: ...) reorders the flags"
( cd mesonapp &&
  echo "\$ meson setup build-bad -Dlink_mode=declare_dep && ninja -C build-bad" &&
  meson setup build-bad -Dlink_mode=declare_dep > /dev/null 2>&1 &&
  ninja -C build-bad > /dev/null 2>&1 &&
  echo "  link args meson generated: $(grep -m1 -o 'LINK_ARGS = .\{0,110\}' build-bad/build.ninja)..." )
run $T ./mesonapp/build-bad/app -l 0 $EAL --file-prefix=ch02-mesonbad --vdev=net_null0
run $T ./mesonapp/build-bad/app -l 0 $EAL --file-prefix=ch02-mesonbad
echo "--- an experimental API without -DALLOW_EXPERIMENTAL_API:"
echo "\$ gcc -Wall -c mesonapp/util.c \$(pkg-config --cflags libdpdk)"
gcc -Wall -c mesonapp/util.c -o /dev/null $(pkg-config --cflags libdpdk) 2>&1 | head -3 | sed "s|$DPDK_PREFIX|\$DPDK_PREFIX|g"

section "6. exercise 1 solution: --verbose after --"
run $T ./verbose -l 0-2 $EAL --file-prefix=ch02-verbose -- --verbose
section "6b. exercise 2 solution: dpdk-pmdinfo.py on the static binary"
run ./solutions/pmdinfo.sh ./hello

if [ "${1:-}" != "--no-first-look" ]; then
	section "7. first_look.sh"
	./first_look.sh
fi
echo
echo "run.sh: done"
