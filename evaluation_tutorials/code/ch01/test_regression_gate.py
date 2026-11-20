"""pytest version of the gate checks (optional; the same asserts run in regression_gate.py).

Run:  python3 -m pytest code/ch01/test_regression_gate.py -q      (if pytest is installed)
  or: python3 code/ch01/test_regression_gate.py                    (plain asserts, no pytest)
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from regression_gate import load_jsonl, run_gate  # noqa: E402

TASKS = load_jsonl(HERE / "data" / "golden.jsonl")
FLOOR = json.loads((HERE / "data" / "baseline.json").read_text())["capability_floor"]


def test_shipped_and_good_candidate_pass():
    assert run_gate("v1", TASKS, FLOOR).passed
    assert run_gate("v2", TASKS, FLOOR).passed


def test_any_regression_failure_blocks_merge():
    r = run_gate("v3", TASKS, FLOOR)
    assert not r.passed and all(t.startswith("reg-format") for t in r.regression_failures)


def test_capability_floor_blocks_merge():
    r = run_gate("v4", TASKS, FLOOR)
    assert not r.passed and not r.regression_failures and r.cap_lower < FLOOR


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok  {name}")
