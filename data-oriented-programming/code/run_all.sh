#!/usr/bin/env bash
# run_all.sh: lint, build and run every chapter example in --quick mode, in all three languages.
#
#   ./run_all.sh            # every code/ch*/ directory
#   ./run_all.sh ch03 ch04  # only chapter dirs whose name starts with one of these prefixes
#
# Steps:
#   1. cargo clippy (all selected Rust packages) -- -D warnings
#   2. odin check <chapter>/odin -vet -strict-style        (every selected chapter)
#   3. per chapter:  rust: cargo run --release -q -p <pkg> -- --quick
#                    zig:  zig run -O fast main.zig -- --quick           (cwd: <chapter>/zig)
#                    odin: odin run odin -o:speed -vet -strict-style -- --quick   (cwd: <chapter>)
#   4. every "BENCH {...}" line a program prints must be valid JSON with id/label/lang/n/ns.
# Prints a pass/fail table and exits non-zero if anything failed. Logs: code/target/run_all/*.log
#
# Locking: each compile/run takes /tmp/dod-build.lock (shared with other agents). If this script is
# itself started under `flock /tmp/dod-build.lock ./run_all.sh`, it detects that and does not re-lock.
set -uo pipefail

export PATH="$HOME/tools/zig:$HOME/tools/odin:$HOME/.cargo/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
CODE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CODE"
LOGS="$CODE/target/run_all"
mkdir -p "$LOGS"
TIMEOUT="${TIMEOUT:-600}"

LOCK=(flock /tmp/dod-build.lock)
if [ "$(ps -o comm= -p "$PPID" 2>/dev/null)" = "flock" ]; then LOCK=(); fi

# ---- select chapters ----
CHAPTERS=()
for d in ch*/; do
	[ -d "$d" ] || continue
	d="${d%/}"
	if [ $# -eq 0 ]; then CHAPTERS+=("$d"); continue; fi
	for p in "$@"; do [[ "$d" == "$p"* ]] && CHAPTERS+=("$d") && break; done
done
if [ ${#CHAPTERS[@]} -eq 0 ]; then
	echo "run_all.sh: no chapter directories matched (code/ch*/)" >&2
	exit 1
fi

ROWS=()   # "chapter|step|status|seconds"
FAILED=0
record() { ROWS+=("$1|$2|$3|$4"); [ "$3" = "FAIL" ] && FAILED=1; return 0; }

# run <chapter> <step> <workdir> <cmd...>: runs under the lock with a timeout, logs, records result.
run() {
	local ch="$1" step="$2" dir="$3"; shift 3
	local log="$LOGS/$ch-$step.log" t0 rc
	t0=$(date +%s)
	(cd "$dir" && "${LOCK[@]}" timeout "$TIMEOUT" "$@") >"$log" 2>&1
	rc=$?
	local dt=$(( $(date +%s) - t0 ))
	if [ $rc -eq 0 ] && check_bench "$log"; then
		record "$ch" "$step" PASS "$dt"
	else
		[ $rc -ne 0 ] && echo "exit code $rc" >>"$log"
		record "$ch" "$step" FAIL "$dt"
		echo "---- $ch $step FAILED (last 25 lines of $log) ----"
		tail -n 25 "$log"
	fi
}

# Every BENCH line must be one JSON object with the required keys.
check_bench() {
	{ grep -a '^BENCH ' "$1" || true; } | python3 -c '
import json, sys
bad = 0
for line in sys.stdin:
    try:
        o = json.loads(line[6:])
        missing = [k for k in ("id", "label", "lang", "n", "ns") if k not in o]
        if missing: raise ValueError("missing keys %s" % missing)
    except Exception as e:
        print("bad BENCH line (%s): %s" % (e, line.strip()), file=sys.stderr); bad = 1
sys.exit(bad)' 2>>"$1"
}

pkg_of() { sed -n 's/^name *= *"\(.*\)"/\1/p' "$1/rust/Cargo.toml" | head -n1; }

# ---- 1. clippy ----
PKGS=()
for ch in "${CHAPTERS[@]}"; do
	[ -f "$ch/rust/Cargo.toml" ] && PKGS+=(-p "$(pkg_of "$ch")")
done
if [ ${#PKGS[@]} -gt 0 ]; then
	[ $# -eq 0 ] && PKGS=(--workspace)
	run "rust-all" "clippy" "$CODE" cargo clippy -q "${PKGS[@]}" -- -D warnings
fi

# ---- 2. odin check ----
for ch in "${CHAPTERS[@]}"; do
	[ -d "$ch/odin" ] && run "$ch" "odin-check" "$CODE/$ch" odin check odin -vet -strict-style
done

# ---- 3. build + run --quick ----
for ch in "${CHAPTERS[@]}"; do
	if [ -f "$ch/rust/Cargo.toml" ]; then
		run "$ch" "rust" "$CODE" cargo run --release -q -p "$(pkg_of "$ch")" -- --quick
	else record "$ch" "rust" SKIP 0; fi
	if [ -f "$ch/zig/main.zig" ]; then
		run "$ch" "zig" "$CODE/$ch/zig" zig run -O fast main.zig -- --quick
	else record "$ch" "zig" SKIP 0; fi
	if [ -d "$ch/odin" ]; then
		run "$ch" "odin" "$CODE/$ch" odin run odin -o:speed -vet -strict-style -out:"$CODE/target/run_all/$ch-odin.bin" -- --quick
	else record "$ch" "odin" SKIP 0; fi
done

# ---- table ----
echo
printf '%-34s %-11s %-5s %6s\n' "chapter" "step" "result" "sec"
printf '%-34s %-11s %-5s %6s\n' "-------" "----" "------" "---"
for r in "${ROWS[@]}"; do
	IFS='|' read -r a b c d <<<"$r"
	printf '%-34s %-11s %-6s %5s\n' "$a" "$b" "$c" "$d"
done
echo
if [ $FAILED -ne 0 ]; then echo "run_all.sh: FAILURES (logs in $LOGS)"; exit 1; fi
echo "run_all.sh: all passed"
