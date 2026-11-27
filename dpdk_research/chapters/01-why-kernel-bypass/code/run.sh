#!/usr/bin/env bash
# run.sh - build and run every chapter 01 example. Run as root.
#   ./run.sh                 # everything (about 50 s)
#   ./run.sh | tee my_output.txt ; diff my_output.txt expected_output.txt
# Numbers will differ from expected_output.txt; the shape should not.
set -u
cd "$(dirname "$0")"

# --- environment: DPDK_ENV, else the course's common/env.sh -----------------
if [ -n "${DPDK_ENV:-}" ] && [ -f "$DPDK_ENV" ]; then . "$DPDK_ENV"
elif [ -f ../../../common/env.sh ]; then . ../../../common/env.sh
elif [ -f /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh ]; then
	. /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh
fi
pkg-config --exists libdpdk || { echo "libdpdk not found: set DPDK_ENV or create common/env.sh"; exit 1; }
E=${E:-$DPDK_SRC/build/examples}

# --- cleanup on any exit ------------------------------------------------------
cleanup() {
	jobs -p | xargs -r kill 2>/dev/null
	ip link del ch01tap0 2>/dev/null
	rm -rf /var/run/dpdk/ch01-* 2>/dev/null
	rm -f /dev/hugepages/ch01-*map_* 2>/dev/null
}
trap cleanup EXIT INT TERM

T="timeout -s INT -k 5"
show() { echo; echo "\$ $*"; }
# strip ANSI colours and keep stdout line-buffered
clean() { sed 's/\x1b\[[0-9;]*m//g'; }

echo "== build =="
make -s 2>&1 | grep -v '^$' || true
ls hello_dpdk bypass_bench intr_vs_poll >/dev/null || exit 1
echo "built: hello_dpdk bypass_bench intr_vs_poll"

echo; echo "== 1. hello_dpdk: EAL init, version, lcores, ports, TSC =="
show ./hello_dpdk -l 0 --no-pci --no-huge -m 64 --file-prefix=ch01-hello --vdev=net_null0 --vdev=net_ring0
$T 20 ./hello_dpdk -l 0 --no-pci --no-huge -m 64 --file-prefix=ch01-hello \
	--vdev=net_null0 --vdev=net_ring0 2>&1 | clean

echo; echo "== 2. prebuilt dpdk-helloworld on 4 lcores (run twice: order changes) =="
for i in 1 2; do
	show \$E/dpdk-helloworld -l 0-3 --no-huge -m 64 --no-pci --file-prefix=ch01-hw
	$T 10 "$E/dpdk-helloworld" -l 0-3 --no-huge -m 64 --no-pci --file-prefix=ch01-hw 2>&1 | clean | grep -v '^EAL'
done

echo; echo "== 3. PEEK AHEAD: bypass_bench, kernel syscall path vs DPDK burst path =="
show ./bypass_bench -l 1 --no-pci --no-huge -m 128 --file-prefix=ch01-bb --vdev=net_null0
$T 30 ./bypass_bench -l 1 --no-pci --no-huge -m 128 --file-prefix=ch01-bb --vdev=net_null0 2>&1 | clean
echo "# exercise 2: the same with bursts of 1, 8 and 32"
show ./bypass_bench -l 1 --no-pci --no-huge -m 128 --file-prefix=ch01-bb --vdev=net_null0 -- 1 8 32
$T 30 ./bypass_bench -l 1 --no-pci --no-huge -m 128 --file-prefix=ch01-bb --vdev=net_null0 -- 1 8 32 2>&1 | clean | grep -v '^EAL'

echo; echo "== 4. PEEK AHEAD: intr_vs_poll on net_tap, offered rate 0..10000 pkt/s =="
echo "# each run: 4 s; inject.py writes frames into ch01tap0 from t=1.0 s to t=3.5 s"
for rate in 0 100 1000 10000; do
	for mode in poll intr; do
		show ./intr_vs_poll -l 1 --no-pci --no-huge -m 128 --file-prefix=ch01-ivp --vdev=net_tap0,iface=ch01tap0 -- $mode 4 "  # offered $rate pkt/s"
		$T 20 stdbuf -oL ./intr_vs_poll -l 1 --no-pci --no-huge -m 128 --file-prefix=ch01-ivp \
			--vdev=net_tap0,iface=ch01tap0 -- $mode 4 > ivp.out 2>&1 &
		pid=$!
		sleep 1
		ip link set ch01tap0 up 2>/dev/null   # tap must be up to carry frames
		[ "$rate" -gt 0 ] && taskset -c 3 python3 -I ./inject.py ch01tap0 "$rate" 2.5 >/dev/null
		wait $pid
		clean < ivp.out | grep -v '^EAL'
	done
done
rm -f ivp.out

echo; echo "== 5. the skeleton x-ray: dpdk-skeleton (examples/skeleton/basicfwd.c) on two net_null ports =="
show \$E/dpdk-skeleton -l 1 --no-huge -m 128 --no-pci --file-prefix=ch01-sk --vdev=net_null0 --vdev=net_null1
$T 4 stdbuf -oL "$E/dpdk-skeleton" -l 1 --no-huge -m 128 --no-pci --file-prefix=ch01-sk \
	--vdev=net_null0 --vdev=net_null1 > sk.out 2>&1 &
pid=$!
sleep 2.5
echo "# ps while it runs (an idle-or-busy DPDK loop always shows ~100% CPU):"
skpid=$(pgrep -f '^[^ ]*dpdk-skeleton .*ch01-sk' | head -1)
[ -n "$skpid" ] && ps -o pcpu=,comm= -p "$skpid" | awk '{print "  %CPU " $1 "  " $2}'
wait $pid
clean < sk.out | grep -v '^EAL'
rm -f sk.out

echo; echo "== 6. the library map in numbers =="
show ls \$DPDK_SRC/lib \| wc -l
ls "$DPDK_SRC/lib" | grep -v meson.build | wc -l
show "pkg-config --libs --static libdpdk | tr ' ' '\n' | grep -c 'l:librte_'"
pkg-config --libs --static libdpdk | tr ' ' '\n' | grep -c 'l:librte_'
show "ls \$DPDK_SRC/drivers/net | wc -l   # Ethernet PMDs in the tree"
ls -d "$DPDK_SRC"/drivers/net/*/ | wc -l

echo; echo "== 7. exercise 1 solution: the budget arithmetic (plain C, no DPDK) =="
show gcc -O2 -Wall solutions/ex1_budget.c -o solutions/ex1_budget \&\& ./solutions/ex1_budget
gcc -O2 -Wall solutions/ex1_budget.c -o solutions/ex1_budget && ./solutions/ex1_budget
rm -f solutions/ex1_budget

echo; echo "== done =="
