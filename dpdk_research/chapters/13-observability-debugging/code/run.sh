#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13: build and run every example, the exercise solutions, the five
# debug labs and the band 2 project acceptance check. About 90 s.
# To refresh the captured output:
#     ./run.sh 2>&1 | tee expected_output.txt
#
# Every DPDK run: --no-pci, a unique --file-prefix=ch13-*, timeout -s INT.
# Memory: --no-huge -m <=128, except dpdk-ethtool (-m 640, see section 6)
# and the core-dump lab, which uses -m 32 of real hugepages on purpose.
# Interfaces: ch13tap0..2 (net_tap, removed by the PMD on close; the trap
# removes them too). Ports: net_null, net_ring, net_tap. Needs root.
set -u
cd "$(dirname "$0")"
HERE=$PWD
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"
E=$DPDK_SRC/build/examples
TMPD=$(mktemp -d /tmp/ch13.XXXXXX)

cleanup() {
	jobs -p | xargs -r kill -INT 2>/dev/null
	sleep 0.3
	jobs -p | xargs -r kill -KILL 2>/dev/null
	for d in /var/run/dpdk/ch13-*; do rm -rf "$d"; done
	rm -f /dev/hugepages/ch13-*map_* 2>/dev/null
	for i in ch13tap0 ch13tap1 ch13tap2; do ip link del "$i" 2>/dev/null; done
	rm -rf "$TMPD"
}
trap cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }

strip() { sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | sed "s#$TMPD#\$TMPD#g; s#$DPDK_SRC#\$DPDK_SRC#g; s#$DPDK_PREFIX#\$DPDK_PREFIX#g"; }
noeal() { grep -v "^EAL: \(Detected\|Multi-process\|Selected\)"; }
# run <secs> <cmd...>: print the command, run it bounded, show its output
run() {
	local secs=$1; shift
	echo "\$ $*" | strip
	timeout -s INT -k 5 "$secs" stdbuf -oL "$@" 2>&1 | strip | noeal
	local rc=${PIPESTATUS[0]}
	[ "$rc" -ne 0 ] && echo "[exit status $rc]"
	return 0
}
# bg <secs> <logfile> <cmd...>: start in the background, wait for READY
bg() {
	local secs=$1 log=$2; shift 2
	echo "\$ $* &" | strip
	timeout -s INT -k 5 "$secs" stdbuf -oL "$@" > "$log" 2>&1 &
	BGPID=$!
	for _ in $(seq 50); do grep -q READY "$log" 2>/dev/null && break; sleep 0.1; done
}
show() { strip < "$1" | noeal; }
TELPY="dpdk-telemetry.py"

echo "########## 1. telemetry_app: custom endpoints, usage callback, clients, exporter"
bg 20 "$TMPD/tel.log" ./telemetry_app -l 0-1 --no-pci --no-huge -m 128 \
	--file-prefix=ch13-tel --vdev=net_null0 --vdev=net_null1
sleep 1
echo
echo "--- 1a. dpdk-telemetry.py (the shipped client, commands on stdin)"
echo "\$ printf '/ch13/stats\n/ch13/echo,hello world\n/eal/lcore/usage\n/help,/ch13/stats\n/ch13/nothing\n' | $TELPY -f ch13-tel"
printf '/ch13/stats\n/ch13/echo,hello world\n/eal/lcore/usage\n/help,/ch13/stats\n/ch13/nothing\n' |
	$TELPY -f ch13-tel 2>&1
echo "\$ printf 'FOREACH /ethdev/list /ethdev/stats .opackets\nFOREACH i /ethdev/list /ethdev/info,\$i .name\n' | $TELPY -f ch13-tel"
printf 'FOREACH /ethdev/list /ethdev/stats .opackets\nFOREACH i /ethdev/list /ethdev/info,$i .name\n' |
	$TELPY -f ch13-tel 2>&1
echo
echo "--- 1b. telclient.py (25 lines of Python, raw SEQPACKET)"
run 10 python3 -I telclient.py ch13-tel /ch13/stats /eal/lcore/usage \
	/ethdev/xstats,0 /mempool/info,ch13_tel_pool /eal/heap_info,0
echo
echo "--- 1c. dpdk-telemetry-watcher.py (deltas once per second)"
run 8 dpdk-telemetry-watcher.py -f ch13-tel -t 3 -d /ch13/stats.busy_polls /ethdev/stats,0.ipackets
echo
echo "--- 1d. dpdk-telemetry-exporter.py with the shipped 'counters' endpoint and our exporter/ch13.py"
EXPLOG=$TMPD/exp.log
timeout -s INT 10 python3 "$(command -v dpdk-telemetry-exporter.py)" \
	-p "$DPDK_PREFIX/share/dpdk/telemetry-endpoints:$HERE/exporter" -e counters -e ch13 \
	-s /var/run/dpdk/ch13-tel/dpdk_telemetry.v2 -o openmetrics://127.0.0.1:9913 > "$EXPLOG" 2>&1 &
EXPID=$!
sleep 1
echo "\$ dpdk-telemetry-exporter.py -p \$DPDK_PREFIX/share/dpdk/telemetry-endpoints:./exporter -e counters -e ch13 -s /var/run/dpdk/ch13-tel/dpdk_telemetry.v2 -o openmetrics://127.0.0.1:9913 &"
echo "\$ python3 -c 'urllib.request.urlopen(\"http://127.0.0.1:9913/metrics\")' | grep -v '^# HELP'"
python3 -I -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:9913/metrics').read().decode())" |
	grep -v "^# HELP" | grep -E "TYPE|ch13|rx_packets|tx_packets" | head -24
kill -INT $EXPID 2>/dev/null; wait $EXPID 2>/dev/null
sed 's/^[0-9-]* [0-9:]* //' "$EXPLOG" | strip | sed 's#/home/[^ ]*/code/#./#'
kill -INT $BGPID; wait $BGPID 2>/dev/null
echo "--- telemetry_app's own output:"
show "$TMPD/tel.log"

echo
echo "########## 2. exercise solutions 1 and 2: /ch13/port_rates and a pps poller"
bg 15 "$TMPD/rates.log" ./port_rates -l 0-1 --no-pci --no-huge -m 128 \
	--file-prefix=ch13-rates --vdev=net_null0 --vdev=net_null1 -- --seconds 5
sleep 0.5
echo "\$ printf '/ch13/port_rates\n/ch13/port_rates,1\n' | $TELPY -f ch13-rates   (twice, 1 s apart)"
printf '/ch13/port_rates\n/ch13/port_rates,1\n' | $TELPY -f ch13-rates
sleep 1
printf '/ch13/port_rates\n' | $TELPY -f ch13-rates
run 8 solutions/poll_pps.sh ch13-rates 0 4
wait $BGPID 2>/dev/null
show "$TMPD/rates.log"

echo
echo "########## 3. latency_metrics: latencystats + bitratestats + rte_metrics -> /ch13/latency"
for w in 0 5000; do
	bg 15 "$TMPD/lat.log" ./latency_metrics -l 0 --no-pci --no-huge -m 128 \
		--file-prefix=ch13-lat --vdev=net_null0 --vdev=net_null1 -- --seconds 3 --work-ns $w
	sleep 2.2
	echo "\$ echo /ch13/latency | $TELPY -f ch13-lat"
	echo /ch13/latency | $TELPY -f ch13-lat
	wait $BGPID 2>/dev/null
	show "$TMPD/lat.log"
done
echo "--- pitfall: the same program on a net_ring loopback (mbufs are recycled with their timestamp flag)"
run 10 ./latency_metrics -l 0 --no-pci --no-huge -m 128 --file-prefix=ch13-lat \
	--vdev=net_ring0 --vdev=net_ring1 -- --seconds 2

echo
echo "########## 4. trace_demo: application tracepoints, CTF output"
echo "--- pitfall: --trace-dir whose parent does not exist"
run 10 ./trace_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-tr --vdev=net_null0 \
	--trace='ch13\..*' --trace-dir="$TMPD/no/such/dir"
mkdir -p "$TMPD/trace"
for b in trace_demo trace_demo_fp; do
	run 10 ./$b -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-tr --vdev=net_null0 \
		--trace='ch13\..*' --trace='lib\.eal\.generic\.str' --trace-dir="$TMPD/trace/$b"
	d=$(ls -d "$TMPD"/trace/$b/*/)
	echo "\$ ls -l <trace dir>; python3 -I ctf_peek.py <trace dir> 5"
	(cd "$d" && ls -l | tail -n +2 | awk '{print "  " $5 "\t" $9}')
	python3 -I ctf_peek.py "$d" 5 | strip
done
echo "--- the TSDL metadata for our two events:"
grep -B2 -A8 '"ch13\.' "$(ls -d "$TMPD"/trace/trace_demo_fp/*/)metadata"

echo
echo "########## 5. logdp: RTE_LOG_DP vs RTE_LOG"
run 30 ./logdp -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-logdp \
	--log-level=user.ch13:debug --log-timestamp=delta
echo "\$ strings logdp | grep -c 'compiled out, never printed'   (is message 4 in the binary?)"
strings logdp | grep -c 'compiled out, never printed'

echo
echo "########## 6. dpdk-ethtool on net_tap"
echo "--- with only one lcore:"
run 10 sh -c "echo quit | $E/dpdk-ethtool -l 0 --no-pci --no-huge -m 640 --file-prefix=ch13-eth --vdev=net_tap0,iface=ch13tap0"
echo "--- with -m 256 (its pool is sized from desc_lim.nb_max):"
run 10 sh -c "echo quit | $E/dpdk-ethtool -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch13-eth --vdev=net_tap0,iface=ch13tap0"
echo "--- working run (-l 0-1, -m 640), kernel view checked while it runs:"
echo "\$ (printf 'drvinfo\nlink\nmacaddr 0\nmtu 0 1400\n'; sleep 1.5; printf 'portstats 0\nringparam 0\nvalidate 02:13:00:00:00:01\nquit\n') | dpdk-ethtool -l 0-1 --no-pci --no-huge -m 640 --file-prefix=ch13-eth --vdev=net_tap0,iface=ch13tap0"
( printf 'drvinfo\nlink\nmacaddr 0\nmtu 0 1400\n'; sleep 1.5; printf 'portstats 0\nringparam 0\nvalidate 02:13:00:00:00:01\nquit\n' ) |
	timeout -s INT -k 5 12 stdbuf -oL "$E/dpdk-ethtool" -l 0-1 --no-pci --no-huge -m 640 \
	--file-prefix=ch13-eth --vdev=net_tap0,iface=ch13tap0 > "$TMPD/eth.log" 2>&1 &
sleep 1.2
echo "\$ ip link show ch13tap0   (kernel side, while dpdk-ethtool runs)"
ip link show ch13tap0 | head -1 | sed 's/^[0-9]*: //'
wait
show "$TMPD/eth.log"

echo
echo "########## 7. gdb on a live DPDK process (panic_demo)"
echo "\$ gdb -batch -x gdb_live.gdb --args ./panic_demo -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch13-gdb --vdev=net_null0"
timeout -s KILL 60 gdb -q -batch -nx -x gdb_live.gdb --args ./panic_demo -l 0-1 --no-pci --no-huge -m 64 \
	--file-prefix=ch13-gdb --vdev=net_null0 2>&1 | strip | noeal |
	grep -vE "^\[(New |Thread debugging|Inferior)|libthread_db|^warning: [0-9]+\s" |
	sed "s#$HERE/##g"
echo "\$ addr2line -f -e panic_demo 0xb2f73   (frame 2 of rte_dump_stack has no symbol: a static function)"
addr2line -f -e panic_demo "$(timeout 10 ./panic_demo -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch13-gdb \
	--vdev=net_null0 2>&1 | sed -n 's/^2: .*+\(0x[0-9a-f]*\)).*/\1/p')" | sed "s#$HERE/##"

echo
echo "########## 8. AddressSanitizer (gcc) on a DPDK app"
run 10 ./asan_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-asan
echo "\$ ./asan_demo_asan -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-asan   (start of the report)"
timeout 30 ./asan_demo_asan -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-asan 2>&1 | strip | noeal |
	sed "s#$HERE/##g; s/==[0-9]\+==/==PID==/; s/0x[0-9a-f]\{12\}/0x.../g" | head -24 | grep -v "^\s*#[4-9]"

echo
echo "########## 9. crash_postmortem.sh: what is in a core file"
"$HERE/crash_postmortem.sh" 2>&1 | strip | sed 's/0x[0-9a-f]\{12\}/0x.../g'

echo
echo "########## 10. exercise 3 solution: find the pool and refcnt in a 0x7f core"
"$HERE/solutions/find_pool.sh" 2>&1 | strip

echo
echo "########## 11. debug labs"
"$HERE/debug_labs/run_all.sh" 2>&1 | strip

echo
echo "########## 12. band 2 project acceptance check"
"$HERE/band2_project/run.sh" 2>&1 | strip

echo
echo "########## 13. more startup / tooling errors for the consolidated table"
echo "\$ echo /info | dpdk-telemetry.py -f ch13-nosuch   (no process with that prefix)"
echo /info | $TELPY -f ch13-nosuch 2>&1 | tail -1
bg 10 "$TMPD/notel.log" ./telemetry_app -l 0-1 --no-pci --no-huge -m 128 --file-prefix=ch13-notel \
	--no-telemetry --vdev=net_null0 --vdev=net_null1 -- --seconds 2
echo "\$ echo /info | dpdk-telemetry.py -f ch13-notel   (the app runs with --no-telemetry)"
echo /info | $TELPY -f ch13-notel 2>&1 | tail -1
wait $BGPID 2>/dev/null
run 10 ./trace_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-tr2 --vdev=net_null0 --trace='['

echo
echo "stale runtime dirs left by crashed runs: $(ls -d /var/run/dpdk/ch13-* 2>/dev/null | wc -l) (removed now)"
for d in /var/run/dpdk/ch13-*; do rm -rf "$d"; done
echo "run.sh done; leftover ch13 interfaces: $(ip -o link | grep -c ch13)"
