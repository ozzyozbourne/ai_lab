"""Mini SWE-bench: FAIL_TO_PASS / PASS_TO_PASS grading in isolated subprocesses.

Section 6.3 (#outcome) of Chapter 6.  Run:  python3 code/ch06/mini_swebench.py

A tiny "repository" has one buggy function, `median`, that returns the upper middle element for
even-length lists (the "issue").  Five candidate patches are graded the SWE-bench way:

  * each candidate is written into a fresh temporary directory (fresh environment per trial),
  * the tests run in a separate Python process with a wall-clock timeout,
  * FAIL_TO_PASS tests must all pass (the issue is fixed) and PASS_TO_PASS tests must all still
    pass (nothing else broke); this gives FULL / PARTIAL / NO exactly as in swebench's grading.py.

The weak test suite (one F2P test written on an already-sorted list) is fooled by a patch that
forgets to sort.  Adding a seeded property-based (fuzz) test against an oracle exposes it.
Expected key output: the "no-sort" patch is FULL under weak tests and only PARTIAL (= not resolved) under strong tests.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import textwrap
from dataclasses import dataclass
from pathlib import Path

TIMEOUT_S = 2.0

BUGGY = """
def median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2]          # BUG: wrong for even-length lists
"""

PATCHES: dict[str, str] = {
    "no-op (unchanged)": BUGGY,
    "gold": """
def median(xs):
    xs = sorted(xs)
    n = len(xs)
    mid = n // 2
    if n % 2 == 1:
        return xs[mid]
    return (xs[mid - 1] + xs[mid]) / 2
""",
    "no-sort (wrong)": """
def median(xs):
    n = len(xs)
    mid = n // 2
    if n % 2 == 1:
        return sorted(xs)[mid]
    return (xs[mid - 1] + xs[mid]) / 2   # forgot to sort on the even branch
""",
    "mean (breaks odd)": """
def median(xs):
    return sum(xs) / len(xs)
""",
    "infinite loop": """
def median(xs):
    while True:
        pass
""",
}

# Test bodies.  F2P fail on the buggy code and pass on gold; P2P pass on both.
F2P = {"test_even_length": "assert median([1, 2, 3, 4]) == 2.5"}
P2P = {
    "test_odd_length": "assert median([3, 1, 2]) == 2",
    "test_single": "assert median([5]) == 5",
    "test_skewed": "assert median([1, 2, 10]) == 2",
}
# Strengthening: a seeded property test against an independent oracle (statistics.median).
F2P_FUZZ = {"test_property_vs_oracle": textwrap.dedent("""
    import random, statistics
    rng = random.Random(0)
    for _ in range(300):
        xs = [rng.randint(-50, 50) for _ in range(rng.randint(1, 9))]
        assert median(list(xs)) == statistics.median(xs), xs
""")}

RUNNER = """
import json, sys, traceback
sys.path.insert(0, ".")
from repo import median
TESTS = json.load(open("tests.json"))
results = {}
for name, body in TESTS.items():
    try:
        exec(body, {"median": median})
        results[name] = "PASSED"
    except AssertionError:
        results[name] = "FAILED"
    except Exception:
        results[name] = "ERROR"
print(json.dumps(results))
"""


@dataclass
class Report:
    f2p: dict[str, str]
    p2p: dict[str, str]
    status: str


def run_tests(module_src: str, tests: dict[str, str]) -> dict[str, str]:
    """Run tests against module_src in a fresh temp dir and a separate interpreter."""
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        (root / "repo.py").write_text(textwrap.dedent(module_src))
        (root / "tests.json").write_text(json.dumps(tests))
        (root / "runner.py").write_text(RUNNER)
        try:
            proc = subprocess.run([sys.executable, "-I", "runner.py"], cwd=root, capture_output=True,
                                  text=True, timeout=TIMEOUT_S)
            lines = proc.stdout.strip().splitlines()
            return json.loads(lines[-1]) if lines else {name: "ERROR" for name in tests}  # e.g. import failed
        except subprocess.TimeoutExpired:
            return {name: "TIMEOUT" for name in tests}


def resolution_status(f2p: dict[str, str], p2p: dict[str, str]) -> str:
    """Mirror of swebench.harness.grading.get_resolution_status."""
    f = sum(v == "PASSED" for v in f2p.values()) / len(f2p)
    p = sum(v == "PASSED" for v in p2p.values()) / len(p2p)
    if f == 1 and p == 1:
        return "FULL"
    if 0 < f < 1 and p == 1:
        return "PARTIAL"
    return "NO"


def grade(patch_src: str, f2p_tests: dict[str, str]) -> Report:
    res = run_tests(patch_src, {**f2p_tests, **P2P})
    f2p = {k: res[k] for k in f2p_tests}
    p2p = {k: res[k] for k in P2P}
    return Report(f2p, p2p, resolution_status(f2p, p2p))


def frac(d: dict[str, str]) -> str:
    return f"{sum(v == 'PASSED' for v in d.values())}/{len(d)}"


def main() -> None:
    # Validate the task first: F2P must fail on the buggy code and pass on gold (the "--gold" check).
    gold_weak, buggy_weak = grade(PATCHES["gold"], F2P), grade(BUGGY, F2P)
    assert gold_weak.status == "FULL" and buggy_weak.status == "NO", "task is invalid"
    strong_tests = {**F2P, **F2P_FUZZ}
    assert grade(PATCHES["gold"], strong_tests).status == "FULL"

    print(f"{'patch':<20} {'weak F2P':>8} {'P2P':>5} {'weak status':>11} | {'strong F2P':>10} {'strong status':>13}")
    results = {}
    for name, src in PATCHES.items():
        weak, strong = grade(src, F2P), grade(src, strong_tests)
        results[name] = (weak.status, strong.status)
        note = " (timeout)" if "TIMEOUT" in weak.p2p.values() else ""
        print(f"{name:<20} {frac(weak.f2p):>8} {frac(weak.p2p):>5} {weak.status:>11} | "
              f"{frac(strong.f2p):>10} {strong.status:>13}{note}")

    resolved_weak = sum(w == "FULL" for w, _ in results.values())
    resolved_strong = sum(s == "FULL" for _, s in results.values())
    print(f"\nresolved with weak tests:   {resolved_weak}/5")
    print(f"resolved with strong tests: {resolved_strong}/5")
    assert results["no-sort (wrong)"] == ("FULL", "PARTIAL")  # PARTIAL is not "resolved"
    assert results["mean (breaks odd)"] == ("NO", "NO")
    assert results["gold"] == ("FULL", "FULL")
    assert resolved_weak == 2 and resolved_strong == 1


if __name__ == "__main__":
    main()
