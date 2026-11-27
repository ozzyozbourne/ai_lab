# SPDX-License-Identifier: BSD-3-Clause
# lib.sh - helpers shared by the chapter 9 scripts (source it, do not run it).
#
#   tp <secs> <log> <args...>    run dpdk-testpmd bounded by timeout -s INT,
#                                output (ANSI codes stripped) goes to <log>
#   show <log> [egrep]           print a log, optionally only matching lines
#   ch09_cleanup                 remove everything the scripts may create:
#                                background jobs, veths ch09a..d, the
#                                ch09tap* interfaces, sockets, /run/dpdk/ch09-*
#                                and /dev/hugepages/ch09-*map_* files
# Conventions: --no-pci, --no-huge -m 256 at most, a unique --file-prefix=ch09-*,
# every testpmd run passes --total-num-mbufs (8192 or 16384).

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"
TESTPMD=${TESTPMD:-dpdk-testpmd}
# scratch directory for logs, pcap files and sockets
WORK=${WORK:-$(mktemp -d /tmp/ch09.XXXXXX)}
mkdir -p "$WORK"

# Strip colour codes and the "clear screen" sequences testpmd prints before
# each --stats-period block, and drop the empty lines that remain.
strip() { sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/\r//g' | grep -v '^[[:space:]]*$'; }

tp() {
	local secs=$1 log=$2; shift 2
	timeout -s INT -k 5 "$secs" stdbuf -oL "$TESTPMD" "$@" > "$log.raw" 2>&1
	local rc=$?
	strip < "$log.raw" > "$log"
	rm -f "$log.raw"
	return $rc
}

# Print the command line the way a reader would type it.
say() { echo; echo "\$ $*" | sed -e "s#$WORK#\$WORK#g" -e "s#${DPDK_SRC:-@@}#\$DPDK_SRC#g"; }

show() {
	local log=$1; shift
	if [ $# -gt 0 ]; then grep -E -- "$1" "$log"; else cat "$log"; fi
}

ch09_cleanup() {
	local j
	for j in $(jobs -p); do kill -INT "$j" 2>/dev/null; done
	wait 2>/dev/null
	for i in ch09a ch09c ch09tap0 ch09tap1 ch09br; do
		ip link del "$i" 2>/dev/null
	done
	rm -rf /run/dpdk/ch09-* /var/run/dpdk/ch09-* 2>/dev/null
	rm -f /dev/hugepages/ch09-*map_* 2>/dev/null
	rm -f /tmp/ch09-*.sock 2>/dev/null
	[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
}
