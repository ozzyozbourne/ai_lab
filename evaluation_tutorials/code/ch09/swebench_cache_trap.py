"""The SWE-bench run-id cache trap, reproduced with a toy harness.

Chapter 9, section 9.5 (Agent and environment harnesses). The SWE-bench README warns that results
are cached by run_id and instance_id only, so a *different* patch submitted under the same run_id is
not re-evaluated. This toy harness "applies" a patch (replaces a function in a tiny module), runs the
instance's FAIL_TO_PASS and PASS_TO_PASS tests, and caches exactly like that. It also runs the
`--gold` sanity check (reference patches must resolve every instance).
Run:  python3 code/ch09/swebench_cache_trap.py
Expected key output: gold 3/3; a fixed patch under the old run_id still reports 1/3 (stale);
a new run_id or a content-addressed cache key reports the true 3/3.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass

BASE_REPO = {
    "slugify": "def slugify(s):\n    return s.lower().replace(' ', '_')\n",       # bug: should use '-'
    "clamp": "def clamp(x, lo, hi):\n    return max(lo, x)\n",                     # bug: ignores hi
    "mean": "def mean(xs):\n    return sum(xs) / len(xs)\n",                       # bug: crashes on []
}


@dataclass(frozen=True)
class Instance:
    instance_id: str
    func: str
    fail_to_pass: tuple[str, ...]          # tests the fix must make pass
    pass_to_pass: tuple[str, ...]          # tests that must keep passing
    gold_patch: str


INSTANCES = [
    Instance("toy__slugify-1", "slugify", ("slugify('A B') == 'a-b'",), ("slugify('x') == 'x'",),
             "def slugify(s):\n    return s.lower().replace(' ', '-')\n"),
    Instance("toy__clamp-2", "clamp", ("clamp(9, 0, 5) == 5",), ("clamp(-1, 0, 5) == 0",),
             "def clamp(x, lo, hi):\n    return min(max(lo, x), hi)\n"),
    Instance("toy__mean-3", "mean", ("mean([]) == 0.0",), ("mean([1, 3]) == 2.0",),
             "def mean(xs):\n    return sum(xs) / len(xs) if xs else 0.0\n"),
]


def run_tests(inst: Instance, patch: str | None) -> bool:
    """'Build the container', apply the patch, run FAIL_TO_PASS + PASS_TO_PASS."""
    ns: dict = {}
    exec(patch if patch is not None else BASE_REPO[inst.func], ns)
    try:
        return all(eval(t, ns) for t in inst.fail_to_pass + inst.pass_to_pass)
    except Exception:
        return False


class Harness:
    def __init__(self, key_mode: str = "run_id"):
        self.cache: dict[tuple[str, ...], bool] = {}
        self.key_mode, self.container_runs = key_mode, 0

    def key(self, run_id: str, inst: Instance, patch: str) -> tuple[str, ...]:
        if self.key_mode == "run_id":                        # what the README warns about
            return (run_id, inst.instance_id)
        return (inst.instance_id, hashlib.sha256(patch.encode()).hexdigest()[:12])   # content-addressed

    def evaluate(self, preds: list[dict], run_id: str) -> dict[str, bool]:
        out = {}
        for p in preds:
            inst = next(i for i in INSTANCES if i.instance_id == p["instance_id"])
            k = self.key(run_id, inst, p["model_patch"])
            if k not in self.cache:
                self.container_runs += 1
                self.cache[k] = run_tests(inst, p["model_patch"])
            out[inst.instance_id] = self.cache[k]
        return out


def preds(patches: dict[str, str], model: str) -> list[dict]:
    return [{"instance_id": i, "model_name_or_path": model, "model_patch": p} for i, p in patches.items()]


def report(label: str, res: dict[str, bool]) -> int:
    n = sum(res.values())
    print(f"  {label:<48} resolved {n}/{len(res)}  {json.dumps({k[5:]: int(v) for k, v in res.items()})}")
    return n


if __name__ == "__main__":
    h = Harness("run_id")
    print("sanity checks")
    gold = report("--gold (reference patches)", h.evaluate(preds({i.instance_id: i.gold_patch for i in INSTANCES}, "gold"), "validate-gold"))
    base = report("no-op patch (unpatched repo)", h.evaluate(preds({i.instance_id: BASE_REPO[i.func] for i in INSTANCES}, "noop"), "validate-noop"))
    v1 = {i.instance_id: i.gold_patch if i.func == "slugify" else BASE_REPO[i.func] for i in INSTANCES}
    v2 = {i.instance_id: i.gold_patch for i in INSTANCES}
    print("cache keyed by (run_id, instance_id)")
    a = report("agent v1 under run_id=nightly", h.evaluate(preds(v1, "agent-v1"), "nightly"))
    b = report("agent v2 (fixed) under run_id=nightly  <- stale", h.evaluate(preds(v2, "agent-v2"), "nightly"))
    c = report("agent v2 under run_id=nightly-v2", h.evaluate(preds(v2, "agent-v2"), "nightly-v2"))
    print("cache keyed by (instance_id, sha256(patch))")
    h2 = Harness("content")
    h2.evaluate(preds(v1, "agent-v1"), "nightly")
    d = report("agent v2 under run_id=nightly", h2.evaluate(preds(v2, "agent-v2"), "nightly"))
    print(f"container runs: run_id cache {h.container_runs}, content cache {h2.container_runs}")
    assert (gold, base, a, b, c, d) == (3, 0, 1, 1, 3, 3)
