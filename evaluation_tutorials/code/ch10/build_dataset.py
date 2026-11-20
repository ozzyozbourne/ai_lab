"""Section 10.3: build the ShopDesk task set (templates x slices), splits, canary, hashes, sizing.

Writes code/ch10/data/tasks.jsonl (one task per line, canary in every row) and data/MANIFEST.json.
Every other script regenerates the same tasks in memory from the same seed and can check the hash.

Run:  python3 code/ch10/build_dataset.py      (< 1 s)
Expected: 210 tasks (7 slices x 30), 70 dev / 140 test, 90 negative cases, MDE about 0.08 at n = 140.
"""
import collections
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from evalsuite.stats import mde, n_for_mde                            # noqa: E402
from evalsuite.tasks import (CANARY, CANARY_HEADER, SLICES, TEMPLATES,  # noqa: E402
                             build_tasks, content_hash, dataset_hash)

# Planning assumptions for the v1 -> v2 comparison (checked against real runs in run_suite.py):
VAR_PA, VAR_PB, RHO = 0.08, 0.04, 0.5     # between-task variance of per-task success, and their correlation
SIG_A, SIG_B, K = 0.16, 0.10, 5           # mean within-task Bernoulli variance p(1-p), trials per task


def var_diff(k: int = K) -> float:
    omega2 = VAR_PA + VAR_PB - 2 * RHO * (VAR_PA * VAR_PB) ** 0.5
    return omega2 + SIG_A / k + SIG_B / k


def main():
    tasks = build_tasks()
    assert dataset_hash(build_tasks()) == dataset_hash(tasks), "generator is not deterministic"
    assert all(t["content_hash"] == content_hash(t) for t in tasks)
    print(f"ShopDesk task set: {len(tasks)} tasks, {len(TEMPLATES)} templates, dataset hash {dataset_hash(tasks)}")
    print(f"canary: {CANARY}\n")

    cnt = collections.Counter((t["slice"], t["split"]) for t in tasks)
    print(f"{'slice':<15}{'templates':<12}{'polarity':<10}{'dev':>5}{'test':>6}")
    for s in SLICES:
        temps = ",".join(k for k, v in TEMPLATES.items() if v[0] == s)
        pol = "negative" if s in ("refund_policy", "privacy", "impossible") else "positive"
        print(f"{s:<15}{temps:<12}{pol:<10}{cnt[(s, 'dev')]:>5}{cnt[(s, 'test')]:>6}")
    pol = collections.Counter(t["polarity"] for t in tasks)
    per = collections.Counter(t["persona"] for t in tasks)
    print(f"\npositive {pol['positive']}, negative {pol['negative']} (do NOT act: decline, refuse, escalate)")
    print("personas: " + ", ".join(f"{k} {v}" for k, v in sorted(per.items())))
    notes = sum(1 for t in tasks for o in t["db"]["orders"].values() if o["notes"] and not o["notes"].startswith("["))
    print(f"orders carrying a benign customer note (over-refusal probes): {notes}")

    ex = next(t for t in tasks if t["id"] == "R1-000")
    print("\nexample task R1-000 (db omitted):")
    print(json.dumps({k: v for k, v in ex.items() if k not in ("db", "canary")}, indent=1)[:900])

    print("\nSizing the test split (paired v2 - v1, alpha = 0.05 two-sided, power 0.80)")
    print(f"assumed Var(diff) per task with K={K} trials: {var_diff():.4f}")
    print(f"{'n tasks':>8}{'MDE (K=5)':>11}{'MDE (K=1)':>11}")
    for n in (20, 70, 140, 210, 400):
        print(f"{n:>8}{mde(n, var_diff()):>11.3f}{mde(n, var_diff(1)):>11.3f}")
    need = n_for_mde(0.10, var_diff())
    print(f"tasks needed to detect a 10-point gain: {need}  -> test split of 140 gives MDE "
          f"{mde(140, var_diff()):.3f}; one slice (20 tasks) only {mde(20, var_diff()):.3f}")

    out = HERE / "data"
    out.mkdir(exist_ok=True)
    with open(out / "tasks.jsonl", "w") as f:
        for t in tasks:
            f.write(json.dumps(t, sort_keys=True) + "\n")
    manifest = {"env_id": "ShopDesk-v1", "n_tasks": len(tasks), "dataset_hash": dataset_hash(tasks),
                "canary_header": CANARY_HEADER, "created_at": tasks[0]["created_at"],
                "splits": dict(collections.Counter(t["split"] for t in tasks)),
                "content_hashes": {t["id"]: t["content_hash"] for t in tasks}}
    (out / "MANIFEST.json").write_text(json.dumps(manifest, indent=1))
    print(f"\nwrote data/tasks.jsonl and data/MANIFEST.json")
    assert len(tasks) == 210 and pol["negative"] == 90 and abs(mde(140, var_diff()) - 0.080) < 0.005


if __name__ == "__main__":
    main()
