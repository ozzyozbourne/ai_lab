"""Section 10.11: CI gate for a candidate agent, plus the hooks into production monitoring.

Gate 1  regression suite: simple dev tasks every shipped version has solved, plus tasks created from
        production failures. Fixed seeds, 3 trials each; every trial must pass (100%).
Gate 2  capability suite: test split, 5 trials per task, paired difference candidate - baseline with a
        cluster bootstrap CI (by template). Non-inferiority: the CI's lower bound must be above -margin.
Exit code 0 when both gates pass, 1 otherwise (so CI blocks the merge).

Also: an A/A run (v2 vs v2, different base seed) that calibrates the margin;
(a) a drift check of the eval set's intent mix against last week's production mix (PSI) and the
production-weighted success estimate; (b) a triaged production failure turned into a regression task.

Run:  python3 code/ch10/ci_gate.py                                  (v2 vs v1, then a regressed v2.1 demo)
      python3 code/ch10/ci_gate.py --candidate v2.1_regressed --baseline v2     (exits 1)
"""
import argparse
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from evalsuite.runner import run_suite                                   # noqa: E402
from evalsuite.stats import paired_cluster_bootstrap, psi                # noqa: E402
from evalsuite.tasks import SLICES, build_tasks, task_from_production_failure  # noqa: E402

MARGIN = 0.02
PROD_MIX = {"refund": 0.30, "lookup": 0.25, "cancel": 0.18, "refund_policy": 0.10, "impossible": 0.08,
            "privacy": 0.05, "injection": 0.04}          # last week's triaged traffic (Section 10.2 sample)
PROD_FAILURE = {"trace_id": "prod-2026-11-18-0412", "date": "2026-11-18", "failure_code": "identity",
                "template": "C1", "note": "cancelled without verifying; customer gave email only"}


def regression_suite(tasks):
    base = [t for t in tasks if t["split"] == "dev" and t["template"] in ("L1", "L2", "R2", "C1")
            and all(not o["notes"] for o in t["db"]["orders"].values())
            and not (t["template"] == "R2" and t["db"]["orders"][t["gold_actions"][1].split("'")[1]]["shipping"])]
    return base + [task_from_production_failure(PROD_FAILURE, PROD_FAILURE["template"], 900)]


def gate(candidate: str, baseline: str, tasks, verbose=True) -> int:
    reg = regression_suite(tasks)
    rr = run_suite(reg, candidate, n_trials=3, base_seed=777, infra_fail_rate=0.05)
    ok = [r for r in rr if r.status == "ok"]
    fails = sorted({r.task_id for r in ok if not r.passed})
    g1 = not fails
    test = [t for t in tasks if t["split"] == "test"]
    rc, rb = run_suite(test, candidate, 5, infra_fail_rate=0.05), run_suite(test, baseline, 5, infra_fail_rate=0.05)

    def per_task(rs):
        d = {}
        for r in rs:
            if r.status == "ok":
                d.setdefault(r.task_id, []).append(r.passed)
        return d
    pc, pb = per_task(rc), per_task(rb)
    ids = [t["id"] for t in test if t["id"] in pc and t["id"] in pb]
    tmpl = [next(t["template"] for t in test if t["id"] == i) for i in ids]
    diff = [np.mean(pc[i]) - np.mean(pb[i]) for i in ids]
    m, lo, hi = paired_cluster_bootstrap(diff, tmpl, B=4000, seed=2)
    g2 = lo > -MARGIN
    print(f"\nGATE  candidate={candidate}  baseline={baseline}")
    print(f"  [1] regression suite: {len(reg)} tasks x 3 trials, {len(ok)} scored, "
          f"{len(rr) - len(ok)} infra_error (rerun, not failed): {len(ok) - sum(r.passed for r in ok)} failing trials"
          f" -> {'PASS' if g1 else 'FAIL'}" + (f"  e.g. {', '.join(fails[:4])}" if fails else ""))
    print(f"  [2] capability (test, {len(ids)} tasks x 5): pass@1 {np.mean([np.mean(pc[i]) for i in ids]):.3f} vs "
          f"{np.mean([np.mean(pb[i]) for i in ids]):.3f}; diff {m:+.3f} [{lo:+.3f}, {hi:+.3f}]; "
          f"needs lower bound > {-MARGIN:+.2f} -> {'PASS' if g2 else 'FAIL'}")
    code = 0 if (g1 and g2) else 1
    print(f"  exit code {code}  ({'ship' if code == 0 else 'block the merge'})")
    return code


def aa_calibration(tasks, agent: str = "v2"):
    """A/A run: the same agent against itself with a different base seed. The CI half-width is the noise
    floor of the non-inferiority test for near-identical candidates; a margin below it fails equivalent ones."""
    test = [t for t in tasks if t["split"] == "test"]
    a = run_suite(test, agent, 5, infra_fail_rate=0.05, base_seed=1)
    b = run_suite(test, agent, 5, infra_fail_rate=0.05, base_seed=0)
    pa, pb = ({r.task_id: [] for r in a}, {r.task_id: [] for r in b})
    for rs, d in ((a, pa), (b, pb)):
        for r in rs:
            if r.status == "ok":
                d[r.task_id].append(r.passed)
    ids = [t["id"] for t in test if pa[t["id"]] and pb[t["id"]]]
    diff = [np.mean(pa[i]) - np.mean(pb[i]) for i in ids]
    m, lo, hi = paired_cluster_bootstrap(diff, [i.split("-")[0] for i in ids], B=4000, seed=2)
    print(f"\nA/A calibration: {agent} (base_seed 1) vs {agent} (base_seed 0), {len(ids)} tasks x 5")
    hw = (hi - lo) / 2
    print(f"  diff {m:+.3f} [{lo:+.3f}, {hi:+.3f}], CI half-width {hw:.3f}, Var(d) {np.var(diff, ddof=1):.4f}")
    print(f"  margin {MARGIN:.2f} {'<' if MARGIN < hw else '>='} half-width: an equivalent candidate passes only when its "
          f"observed diff lands above {hw - MARGIN:+.3f} (this draw: {m:+.3f} -> {'PASS' if lo > -MARGIN else 'FAIL'})")


def monitoring(tasks):
    test = [t for t in tasks if t["split"] == "test"]
    eval_mix = np.array([sum(t["slice"] == s for t in test) / len(test) for s in SLICES])
    prod = np.array([PROD_MIX[s] for s in SLICES])
    print(f"\nDrift check: PSI(eval-set slice mix, production mix) = {psi(prod, eval_mix):.3f}"
          f"  (> 0.25 is usually read as a major shift; here it is by design: rare, severe slices are enriched)")
    rs = run_suite(test, "v2", 5, infra_fail_rate=0.05)
    by = {s: np.mean([r.passed for r in rs if r.slice == s and r.status == "ok"]) for s in SLICES}
    print(f"  v2 pass@1 on the eval mix {np.mean([r.passed for r in rs if r.status == 'ok']):.3f}; "
          f"re-weighted to production mix {sum(PROD_MIX[s] * by[s] for s in SLICES):.3f}")
    new = task_from_production_failure(PROD_FAILURE, PROD_FAILURE["template"], 900)
    print(f"\nProduction failure -> task: {PROD_FAILURE['trace_id']} ({PROD_FAILURE['note']})")
    print(f"  new task {new['id']}  split={new['split']}  source={new['source']}  created_at={new['created_at']}"
          f"  hash={new['content_hash']}  (already in the regression suite above)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate")
    ap.add_argument("--baseline", default="v1")
    args = ap.parse_args()
    tasks = build_tasks()
    if args.candidate:
        sys.exit(gate(args.candidate, args.baseline, tasks))
    code = gate("v2", "v1", tasks)
    demo = gate("v2.1_regressed", "v2", tasks)
    assert code == 0 and demo == 1
    aa_calibration(tasks)
    monitoring(tasks)
    sys.exit(code)


if __name__ == "__main__":
    main()
