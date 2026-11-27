#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# run.sh - build and run every Chapter 3 example. Self-cleaning, bounded by
# timeout, unique --file-prefix=ch03-*. Takes about 30 s.
#
#   ./run.sh 2>&1 | tee expected_output.txt
set -u
cd "$(dirname "$0")"
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
source "$ENV_SH"
E=$DPDK_SRC/build/examples            # prebuilt samples (not on PATH)
EAL="--no-pci --no-huge -m 64"        # sandbox flags used by every run
T="timeout -s INT -k 5 20"

cleanup() {
	pkill -INT -f 'file-prefix=ch03-' 2>/dev/null
	sleep 0.3
	pkill -KILL -f 'file-prefix=ch03-' 2>/dev/null
	rm -rf /var/run/dpdk/ch03-*
	rm -f /dev/hugepages/ch03-*map_*
	true
}
trap cleanup EXIT
strip() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e "s|$DPDK_SRC|\$DPDK_SRC|g"; }
run() {
	echo "\$ $*" | sed "s|$DPDK_SRC|\$DPDK_SRC|g"
	stdbuf -oL -eL "$@" 2>&1 | strip
	echo "[exit code ${PIPESTATUS[0]}]"
}
section() { echo; echo "=================== $* ==================="; }

section "0. build (make, -Wall -Wextra)"
make -s clean
make -s all 2>&1 | strip
echo "[make exit code ${PIPESTATUS[0]}]"

section "1. eal_tour: launch, roles, states, threads"
run $T ./eal_tour -l 0-2 $EAL --file-prefix=ch03-tour

section "2. a service lcore is counted but not visited by FOREACH"
run $T ./eal_tour -l 0-2 -S 2 $EAL --file-prefix=ch03-svc | sed -n '1,16p;/== 8/,$p'

section "3. the rte_eal_init timeline (helloworld, lib.eal:debug, delta timestamps)"
run $T $E/dpdk-helloworld -l 0-1 $EAL --file-prefix=ch03-init \
	--log-level=lib.eal:debug --log-timestamp=delta

section "4. lcore mapping lab (prebuilt helloworld)"
for m in "-l 0-3" "--lcores=0,(1-3)@(1,2)" "-l 2-3 -R" "-l 1-3 --main-lcore 3" \
	 "--lcores=0@0,(1,2)@(1-3)" "--lcores=(0-3)@0"; do
	# shellcheck disable=SC2086
	run $T $E/dpdk-helloworld $m $EAL --file-prefix=ch03-map --log-level=lib.eal:debug \
		| grep -E '^\$|mapped to|Control threads|is ready|hello from|exit code'
done

section "5. reading EAL errors"
run $T $E/dpdk-helloworld -l 0-5 $EAL --file-prefix=ch03-err | grep -v '^[0-9]*: '
run $T $E/dpdk-helloworld -l 1-2 --main-lcore 0 $EAL --file-prefix=ch03-err | grep -v '^[0-9]*: '
run $T $E/dpdk-helloworld -c 0x3 $EAL --file-prefix=ch03-err

section "6. log_lab: logtypes, levels, patterns, streams"
run $T ./log_lab -l 0 $EAL --file-prefix=ch03-log
echo "--- the same program with a command-line pattern"
run $T ./log_lab -l 0 $EAL --file-prefix=ch03-log --log-level='user.ch03*:debug' | sed -n '1,16p'
echo "--- only the rx sub-type, and EAL quieted to warnings"
run $T ./log_lab -l 0 $EAL --file-prefix=ch03-log --log-level=lib.eal:warning \
	--log-level=user.ch03app.rx:debug | sed -n '1,14p'
echo "--- exercise 3: RTE_LOG_LINE rejects a newline at compile time"
make newline_bad 2>&1 | strip | grep -E 'error|newline_bad.c:[0-9]+:[0-9]+: note' | head -3

section "7. tsc_lab: TSC, clock cost, delays (the measurement recipe)"
run $T ./tsc_lab -l 0 $EAL --file-prefix=ch03-tsc

section "8. thread anatomy of a running DPDK process"
stdbuf -oL ./eal_tour -l 1-2 $EAL --file-prefix=ch03-serve -- --serve 15 > .serve.out 2>&1 &
APP=$!
sleep 1.5
echo "\$ for t in /proc/<pid>/task/*; do comm; Cpus_allowed_list; done"
printf '  %-8s %-16s %s\n' TID NAME CPUS
for t in /proc/$APP/task/*; do
	printf '  %-8s %-16s %s\n' "${t##*/}" "$(cat "$t/comm")" \
		"$(awk '/Cpus_allowed_list/ {print $2}' "$t/status")"
done | sort -k2 | sed "s/^  $APP     /  <pid>    /"
echo "\$ ls /var/run/dpdk/ch03-serve"
ls /var/run/dpdk/ch03-serve | sed 's/^/  /'
echo "\$ kill -INT <pid>"
kill -INT $APP
wait $APP
echo "[exit code $?]"
strip < .serve.out
rm -f .serve.out
echo "\$ ls /var/run/dpdk/ch03-serve   (after a clean exit)"
ls /var/run/dpdk/ch03-serve 2>&1 | sed 's/^/  /'

section "9. exercise solutions"
run $T ./reverse_wait -l 0-3 $EAL --file-prefix=ch03-ex1
echo "--- exercise 4: SIGINT stops every lcore (hugepage run, -m 64)"
./clean_stop -l 0-2 --no-pci -m 64 --file-prefix=ch03-stop > .stop.out 2>&1 &
APP=$!
sleep 2
echo "\$ ls /dev/hugepages | grep ch03-stop | wc -l    (while running)"
ls /dev/hugepages | grep -c '^ch03-stop'
kill -INT $APP; wait $APP; echo "[exit code $?]"
strip < .stop.out
echo "\$ ls /dev/hugepages | grep ch03-stop | wc -l    (after SIGINT + cleanup)"
ls /dev/hugepages | grep -c '^ch03-stop'
echo "--- the same program killed with SIGKILL (no cleanup can run)"
./clean_stop -l 0-2 --no-pci -m 64 --file-prefix=ch03-stop > .stop.out 2>&1 &
APP=$!
sleep 2
kill -KILL $APP; wait $APP 2>/dev/null; echo "[exit code $?]"
echo "\$ ls /dev/hugepages | grep ch03-stop    (leftovers; first 3 and a count)"
ls /dev/hugepages | grep '^ch03-stop' | sort -V | head -3 | sed 's/^/  /'
echo "  ... $(ls /dev/hugepages | grep -c '^ch03-stop') files of 2 MB = the whole -m 64"
echo "\$ ls /var/run/dpdk/ch03-stop"
ls /var/run/dpdk/ch03-stop | sed 's/^/  /'
rm -f .stop.out /dev/hugepages/ch03-stop*map_*
rm -rf /var/run/dpdk/ch03-stop
echo "(run.sh removed them)"
