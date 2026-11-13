#!/usr/bin/env bash
# bench_all.sh: the serial benchmark pass. Builds every chapter program in release mode, then runs the
# full-size programs one at a time (no --quick), pinned with taskset, and collects their BENCH lines.
#
#   ./bench_all.sh            # every code/ch*/ directory
#   ./bench_all.sh ch02 ch04  # only chapter dirs starting with these prefixes (other chapters' data is kept)
#
# Pinning: single-threaded programs run under `taskset -c 2`. A chapter whose programs use threads puts a
# file `code/chNN-<slug>/taskset` containing the CPU list to use instead (e.g. `0,2` = two physical cores).
#
# Writes:
#   code/results/machine.txt          lscpu summary, topology, THP, compiler versions, date
#   code/results/<chapter>-<lang>.txt raw stdout+stderr of each full-size run
#   assets/data/bench.js              Book.data[id] = {...} for every id in code/results/*.txt
#   assets/data/bench-chNN.js         the same records, split per chapter (what chapter pages load)
# Exits non-zero if any build or run failed.
set -uo pipefail

export PATH="$HOME/tools/zig:$HOME/tools/odin:$HOME/.cargo/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
CODE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOK="$(dirname "$CODE")"
cd "$CODE"
BIN="$CODE/target/bench"
RES="$CODE/results"
mkdir -p "$BIN" "$RES" "$BOOK/assets/data"
TIMEOUT="${TIMEOUT:-1800}"

LOCK=(flock /tmp/dod-build.lock)
if [ "$(ps -o comm= -p "$PPID" 2>/dev/null)" = "flock" ]; then LOCK=(); fi

CHAPTERS=()
for d in ch*/; do
	[ -d "$d" ] || continue
	d="${d%/}"
	if [ $# -eq 0 ]; then CHAPTERS+=("$d"); continue; fi
	for p in "$@"; do [[ "$d" == "$p"* ]] && CHAPTERS+=("$d") && break; done
done
if [ ${#CHAPTERS[@]} -eq 0 ]; then
	echo "bench_all.sh: no chapter directories matched (code/ch*/)" >&2
	exit 1
fi

RUSTV="$(rustc --version)"
ZIGV="zig $(zig version)"
ODINV="$(odin version)"

# ---- machine.txt ----
{
	echo "# Machine used for the serial benchmark pass"
	echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "kernel: $(uname -srm)"
	echo
	echo "## lscpu"
	lscpu | grep -E '^(Architecture|CPU\(s\)|On-line|Thread|Core|Socket|NUMA node\(s\)|Model name|CPU max MHz|CPU MHz|BogoMIPS|L1d|L1i|L2|L3|Hypervisor|Virtualization)' || lscpu
	echo
	echo "## topology (lscpu -e)"
	lscpu -e=CPU,CORE,SOCKET,NODE,L1d:L1i:L2:L3 2>/dev/null || lscpu -e
	echo
	echo "## cache line / page"
	echo "coherency_line_size: $(cat /sys/devices/system/cpu/cpu0/cache/index0/coherency_line_size 2>/dev/null || echo '?') B"
	echo "page size: $(getconf PAGESIZE) B"
	echo "transparent_hugepage: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '?')"
	echo "SIMD flags: $(grep -o -w -E 'sse4_2|avx|avx2|fma|avx512f|avx512bw|avx512vl' /proc/cpuinfo | sort -u | tr '\n' ' ')"
	echo
	echo "## compilers"
	echo "$RUSTV"
	echo "$ZIGV"
	echo "$ODINV"
	echo
	echo "## pinning"
	echo "single-threaded: taskset -c 2; chapters with a 'taskset' file use its CPU list"
} >"$RES/machine.txt"

FAILED=0
ROWS=()
note() { ROWS+=("$1|$2|$3"); [ "$3" = "FAIL" ] && FAILED=1; return 0; }
pkg_of() { sed -n 's/^name *= *"\(.*\)"/\1/p' "$1/rust/Cargo.toml" | head -n1; }

# ---- build everything first (not pinned, not timed) ----
for ch in "${CHAPTERS[@]}"; do
	rm -f "$RES/$ch-"{rust,zig,odin}.txt   # no stale results from an earlier pass if this build fails
	if [ -f "$ch/rust/Cargo.toml" ]; then
		if "${LOCK[@]}" cargo build --release -q -p "$(pkg_of "$ch")" >"$BIN/$ch-rust.build.log" 2>&1; then
			cp "target/release/$(pkg_of "$ch")" "$BIN/$ch-rust"
		else note "$ch" rust FAIL; cat "$BIN/$ch-rust.build.log"; fi
	fi
	if [ -f "$ch/zig/main.zig" ]; then
		(cd "$ch/zig" && "${LOCK[@]}" zig build-exe -O fast main.zig -femit-bin="$BIN/$ch-zig") >"$BIN/$ch-zig.build.log" 2>&1 \
			|| { note "$ch" zig FAIL; cat "$BIN/$ch-zig.build.log"; }
	fi
	if [ -d "$ch/odin" ]; then
		(cd "$ch" && "${LOCK[@]}" odin build odin -o:speed -vet -strict-style -out:"$BIN/$ch-odin") >"$BIN/$ch-odin.build.log" 2>&1 \
			|| { note "$ch" odin FAIL; cat "$BIN/$ch-odin.build.log"; }
	fi
done

# ---- run serially, pinned ----
for ch in "${CHAPTERS[@]}"; do
	cpus=2
	[ -f "$ch/taskset" ] && cpus="$(tr -d ' \n' <"$ch/taskset")"
	for lang in rust zig odin; do
		exe="$BIN/$ch-$lang"
		[ -x "$exe" ] || continue
		out="$RES/$ch-$lang.txt"
		echo "== $ch $lang (taskset -c $cpus)"
		t0=$(date +%s)
		if (cd "$CODE/$ch" && "${LOCK[@]}" timeout "$TIMEOUT" taskset -c "$cpus" "$exe") >"$out" 2>&1; then
			note "$ch" "$lang" "PASS $(( $(date +%s) - t0 ))s"
		else
			note "$ch" "$lang" FAIL; tail -n 20 "$out"
		fi
		rm -f "$exe"
	done
done

# ---- aggregate BENCH lines -> assets/data/bench.js + bench-chNN.js ----
# Every key of a BENCH line except "id" is kept in the run (e.g. ch05-memory/ch11-bytes "value" + "unit").
# Records are rebuilt from code/results/chNN-*-<lang>.txt. Nothing a page depends on is dropped: an id (or an
# id+language) present in the old bench-chNN.js but not produced by this pass (failed or skipped run, chapter
# not selected) is carried over and flagged "carried over" in its note, and the script prints a warning.
# The old files are read with node, because hand-written dev files are JS, not strict one-line JSON.
node -e '
global.window = global; global.Book = { data: {} };
const fs = require("fs"), d = process.argv[1];
for (const f of fs.readdirSync(d).filter((f) => /^bench-ch\d\d\.js$/.test(f))) {
  try { require(d + "/" + f); } catch (e) { console.error("bench_all.sh: cannot read " + f + ": " + e.message); }
}
fs.writeFileSync(process.argv[2], JSON.stringify(Book.data));' "$BOOK/assets/data" "$BIN/old-bench.json" || echo '{}' >"$BIN/old-bench.json"
python3 - "$RES" "$BOOK/assets/data" "$RUSTV" "$ZIGV" "$ODINV" "$CODE" "$BIN/old-bench.json" <<'PY' || FAILED=1
import datetime, glob, json, os, re, sys
res, data_dir, rustv, zigv, odinv, code, old_path = sys.argv[1:8]
machine_txt = open(os.path.join(res, "machine.txt")).read()
model = re.search(r"Model name:\s*(.+)", machine_txt)
cpu = (model.group(1).strip() if model else "unknown CPU") + " (Ice Lake-SP, KVM), Linux"
date = datetime.date.today().isoformat()
# pinning per chapter, from code/chNN-*/taskset (default CPU 2)
pin = {}
for d in glob.glob(os.path.join(code, "ch[0-9][0-9]-*")):
    ch = os.path.basename(d)[:4]
    t = os.path.join(d, "taskset")
    cpus = open(t).read().strip() if os.path.exists(t) else "2"
    pin[ch] = "taskset -c %s" % cpus + (" (single core)" if cpus == "2" else " (separate physical cores)" if cpus == "0,2" else "")
recs = {}
for path in sorted(glob.glob(os.path.join(res, "ch[0-9][0-9]-*.txt"))):
    for line in open(path, errors="replace"):
        if not line.startswith("BENCH "):
            continue
        try:
            o = json.loads(line[6:])
        except ValueError:
            print("bench_all.sh: bad BENCH line in %s: %s" % (path, line.strip()[:120]), file=sys.stderr); continue
        rid = o.pop("id")
        ch = rid[:4]
        r = recs.setdefault(rid, {"id": rid, "machine": cpu + ", " + pin.get(ch, "taskset -c 2"), "date": date,
                                  "source": "measured", "compilers": {"rust": rustv, "zig": zigv, "odin": odinv}, "runs": []})
        r["runs"].append(o)
try:
    old = json.load(open(old_path))
except Exception:
    old = {}
for rid, orec in old.items():
    if not re.match(r"ch\d\d-", rid) or not isinstance(orec, dict):
        continue
    if rid not in recs:
        orec = dict(orec)
        orec["note"] = ((orec.get("note") or "") + " carried over: not produced by this bench pass").strip()
        recs[rid] = orec
        print("bench_all.sh: WARNING %s not produced by this pass; kept the previous record (%s)" % (rid, orec.get("source", "?")), file=sys.stderr)
        continue
    have = {str(x.get("lang", "")).lower() for x in recs[rid]["runs"]}
    miss = [x for x in orec.get("runs", []) if str(x.get("lang", "")).lower() not in have]
    if miss:
        langs = sorted({str(x.get("lang", "")).lower() for x in miss})
        recs[rid]["runs"].extend(dict(x, stale=True) for x in miss)
        recs[rid]["note"] = ("%s runs carried over from the previous file (%s)" % ("/".join(langs), orec.get("source", "?"))).strip()
        print("bench_all.sh: WARNING %s has no %s runs in this pass; kept the previous ones" % (rid, "/".join(langs)), file=sys.stderr)
def write(path, ids, what):
    with open(path, "w") as f:
        f.write("/* Generated by code/bench_all.sh on %s (%s). Do not edit by hand. */\n" % (date, what))
        f.write("window.Book = window.Book || {}; Book.data = Book.data || {};\n")
        for rid in ids:
            f.write("Book.data[%s] = %s;\n" % (json.dumps(rid), json.dumps(recs[rid], separators=(",", ":"))))
by_ch = {}
for rid in recs:
    by_ch.setdefault(rid[:4], []).append(rid)
for ch, ids in sorted(by_ch.items()):
    write(os.path.join(data_dir, "bench-%s.js" % ch), sorted(ids), ch)
write(os.path.join(data_dir, "bench.js"), sorted(recs), "all chapters")
print("wrote %d bench ids (%d runs) to bench.js and %d bench-chNN.js files in %s" %
      (len(recs), sum(len(r["runs"]) for r in recs.values()), len(by_ch), data_dir))
PY

echo
printf '%-34s %-6s %s\n' chapter lang result
for r in "${ROWS[@]}"; do IFS='|' read -r a b c <<<"$r"; printf '%-34s %-6s %s\n' "$a" "$b" "$c"; done
echo
if [ $FAILED -ne 0 ]; then echo "bench_all.sh: FAILURES"; exit 1; fi
echo "bench_all.sh: done. See code/results/ and assets/data/bench.js"
