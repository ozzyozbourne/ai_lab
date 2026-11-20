#!/usr/bin/env bash
# Run every test of the guide, one project at a time.
#
#   ./run_all_tests.sh                 common/, assets self-test, chapters 01..30
#   ./run_all_tests.sh --only 14       one chapter (two digits, or a full directory name)
#   ./run_all_tests.sh --only common   only common/
#   ./run_all_tests.sh --only assets   only `node assets/selftest.js`
#   ./run_all_tests.sh --no-clippy     skip `cargo clippy`
#   ./run_all_tests.sh --keep          keep .zig-cache, zig-out and target
#   ./run_all_tests.sh --clean         delete them after each project (the default)
#   ./run_all_tests.sh --root DIR      run against another copy of the guide
#
# --only may be given several times. Steps per chapter:
#   zig-test    cd zig  && zig build test
#   zig-run     cd zig  && zig build run   stdout compared with expected_output.txt
#   rust-test   cd rust && cargo test
#   clippy      cd rust && cargo clippy --all-targets -- -D warnings
#   rust-run    cd rust && cargo run       stdout compared with expected_output.txt
# common/ has tests only (no run step, no expected output).
#
# Exit status: 0 if every step passed, 1 if any step failed or nothing was run,
# 2 for a usage error. No `set -e`: a failure is recorded and the run continues.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEAN=1
CLIPPY=1
ONLY=()

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      if [ $# -lt 2 ]; then echo "error: --only needs an argument" >&2; exit 2; fi
      ONLY+=("$2"); shift ;;
    --only=*)   ONLY+=("${1#--only=}") ;;
    --no-clippy) CLIPPY=0 ;;
    --clean)    CLEAN=1 ;;
    --keep)     CLEAN=0 ;;
    --root)
      if [ $# -lt 2 ]; then echo "error: --root needs an argument" >&2; exit 2; fi
      ROOT="$(cd "$2" 2>/dev/null && pwd)" || { echo "error: no such directory: $2" >&2; exit 2; }
      shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/btree_tests.XXXXXX")" || { echo "error: mktemp failed" >&2; exit 1; }

# Results, in order: parallel arrays of unit name, step name, status.
R_UNIT=(); R_STEP=(); R_STATUS=()
UNITS=()
FAILED=0

record() { # unit step status [note]
  R_UNIT+=("$1"); R_STEP+=("$2"); R_STATUS+=("$3")
  case " ${UNITS[*]-} " in *" $1 "*) ;; *) UNITS+=("$1") ;; esac
  if [ "$3" = FAIL ]; then FAILED=$((FAILED + 1)); fi
  printf '%-4s  %-38s %-10s %s\n' "$3" "$1" "$2" "${4-}"
}

# run_step unit step dir command...      passes when the command exits 0
run_step() {
  local unit="$1" step="$2" dir="$3"; shift 3
  local log="$LOGDIR/$unit.$step.log"
  local rc=0
  (cd "$dir" && "$@") >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    record "$unit" "$step" PASS
    rm -f "$log"
  else
    record "$unit" "$step" FAIL "(exit $rc; log: $log)"
  fi
}

# run_compare unit step dir expected command...   stdout must equal the file byte for byte
run_compare() {
  local unit="$1" step="$2" dir="$3" expected="$4"; shift 4
  local out="$LOGDIR/$unit.$step.out" err="$LOGDIR/$unit.$step.err" dif="$LOGDIR/$unit.$step.diff"
  if [ ! -f "$expected" ]; then
    record "$unit" "$step" FAIL "(missing $expected)"
    return
  fi
  local rc=0
  (cd "$dir" && "$@") >"$out" 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    record "$unit" "$step" FAIL "(exit $rc; stderr: $err)"
    return
  fi
  if diff -u "$expected" "$out" >"$dif" 2>&1; then
    record "$unit" "$step" PASS
    rm -f "$out" "$err" "$dif"
  else
    record "$unit" "$step" FAIL "(output differs from expected_output.txt; diff: $dif)"
  fi
}

clean_project() { # dir
  [ "$CLEAN" -eq 1 ] || return 0
  rm -rf "$1/zig/.zig-cache" "$1/zig/zig-out" "$1/rust/target"
}

selected() { # name -> 0 if it should run
  [ "${#ONLY[@]}" -eq 0 ] && return 0
  local want
  for want in "${ONLY[@]}"; do
    [ "$1" = "$want" ] && return 0
    # "4" and "04" both select chapter 04-...
    case "$want" in
      [0-9])      case "$1" in "0$want"-*) return 0 ;; esac ;;
      [0-9][0-9]) case "$1" in "$want"-*)  return 0 ;; esac ;;
    esac
  done
  return 1
}

run_common() {
  local dir="$ROOT/common"
  if [ ! -d "$dir" ]; then record common present FAIL "(missing $dir)"; return; fi
  run_step common zig-test "$dir/zig" zig build test
  run_step common rust-test "$dir/rust" cargo test --quiet
  if [ "$CLIPPY" -eq 1 ]; then
    run_step common clippy "$dir/rust" cargo clippy --quiet --all-targets -- -D warnings
  fi
  clean_project "$dir"
}

run_assets() {
  if ! command -v node >/dev/null 2>&1; then record assets selftest FAIL "(node not found)"; return; fi
  run_step assets selftest "$ROOT" node assets/selftest.js
}

run_chapter() { # directory name, e.g. 04-insertion-and-splitting
  local name="$1" dir="$ROOT/chapters/$1"
  local expected="$dir/expected_output.txt"
  if [ -d "$dir/zig" ]; then
    run_step    "$name" zig-test "$dir/zig" zig build test
    run_compare "$name" zig-run  "$dir/zig" "$expected" zig build run
  else
    record "$name" zig-test FAIL "(no zig/ directory)"
  fi
  if [ -d "$dir/rust" ]; then
    run_step "$name" rust-test "$dir/rust" cargo test --quiet
    if [ "$CLIPPY" -eq 1 ]; then
      run_step "$name" clippy "$dir/rust" cargo clippy --quiet --all-targets -- -D warnings
    fi
    run_compare "$name" rust-run "$dir/rust" "$expected" cargo run --quiet
  else
    record "$name" rust-test FAIL "(no rust/ directory)"
  fi
  clean_project "$dir"
}

echo "root:   $ROOT"
echo "zig:    $(zig version 2>/dev/null || echo 'NOT FOUND')"
echo "cargo:  $(cargo --version 2>/dev/null || echo 'NOT FOUND')"
echo "clean:  $([ "$CLEAN" -eq 1 ] && echo 'yes (use --keep to keep build output)' || echo no)   clippy: $([ "$CLIPPY" -eq 1 ] && echo yes || echo no)"
echo "logs:   $LOGDIR (only failed steps leave files)"
echo

START=$(date +%s)

if selected common; then run_common; fi
if selected assets; then run_assets; fi

if [ -d "$ROOT/chapters" ]; then
  for path in "$ROOT"/chapters/[0-9][0-9]-*/; do
    [ -d "$path" ] || continue
    name="$(basename "$path")"
    if selected "$name"; then run_chapter "$name"; fi
  done
fi

ELAPSED=$(( $(date +%s) - START ))

# ---- summary table: one row per unit, one column per step ----
COLS=(zig-test zig-run rust-test clippy rust-run selftest)
echo
echo "Summary"
printf '%-38s' "project"
for c in "${COLS[@]}"; do printf ' %-9s' "$c"; done
echo
printf '%s\n' "------------------------------------------------------------------------------------------------"
PASSED=0
for u in "${UNITS[@]-}"; do
  [ -n "$u" ] || continue
  printf '%-38s' "$u"
  for c in "${COLS[@]}"; do
    cell="-"
    for i in "${!R_UNIT[@]}"; do
      if [ "${R_UNIT[$i]}" = "$u" ] && [ "${R_STEP[$i]}" = "$c" ]; then cell="${R_STATUS[$i]}"; fi
    done
    printf ' %-9s' "$cell"
  done
  echo
done
for s in "${R_STATUS[@]-}"; do [ "$s" = PASS ] && PASSED=$((PASSED + 1)); done
TOTAL=${#R_STATUS[@]}

echo
echo "$PASSED of $TOTAL steps passed, $FAILED failed, in ${ELAPSED}s."

if [ "$TOTAL" -eq 0 ]; then
  echo "Nothing was run: no project matched (--only ${ONLY[*]-})." >&2
  rmdir "$LOGDIR" 2>/dev/null
  exit 1
fi
if [ "$FAILED" -gt 0 ]; then
  echo "Failed steps:"
  for i in "${!R_UNIT[@]}"; do
    [ "${R_STATUS[$i]}" = FAIL ] && echo "  ${R_UNIT[$i]}  ${R_STEP[$i]}"
  done
  echo "Logs: $LOGDIR"
  exit 1
fi
rmdir "$LOGDIR" 2>/dev/null
exit 0
