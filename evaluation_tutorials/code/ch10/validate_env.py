"""Section 10.5: validate the environment before evaluating any agent.

Runs the QA suite (gold, null, determinism, leakage, isolation, user sim) on two builds of ShopDesk-v1:
  1. a buggy build with two seeded defects:
       bug A  get_order() returns a debug field holding the task's gold actions (answer leak)
       bug B  impossible tasks specified as "goal state = initial state, nothing required" (spec v0),
              so the do-nothing agent passes them (the ABC finding about tau-bench)
  2. the fixed build. Two more defects are checked separately: a shallow copy of the DB (isolation) and a
  user simulator that withholds the zip code (user sim; the open-loop gold check cannot see it).
Then shows what each bug does to a leaderboard: the leak-exploiting agent and null agent vs v2.

Run:  python3 code/ch10/validate_env.py      (about 1 s)
Expected: buggy build fails null (all 30 impossible tasks) and leakage; fixed build passes everything.
"""
import copy
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from evalsuite import ENV_ID                         # noqa: E402
from evalsuite.qa import check_gold, check_isolation, check_user_sim, episode, run_qa  # noqa: E402
from evalsuite.agents import make_agent              # noqa: E402
from evalsuite.tasks import build_tasks              # noqa: E402


def report(title, res):
    print(f"\n== {title} ==")
    print(f"{'check':<14}{'tasks':>6}{'failing':>9}  examples")
    for name, val in res.items():
        if name.startswith("_"):
            continue
        n, bad = val
        print(f"{name:<14}{n:>6}{len(bad):>9}  {', '.join(bad[:4])}{' ...' if len(bad) > 4 else ''}")
    print(f"(seed sanity: {res['_seed_variation']:.0%} of sampled tasks give different transcripts across seeds)")


def score(tasks, agent, bugs=frozenset()):
    return sum(episode(t, make_agent(agent), 3, bugs)[0] for t in tasks) / len(tasks)


def main():
    print(f"Environment QA for {ENV_ID}")
    buggy = build_tasks(impossible_spec="v0")
    fixed = build_tasks()
    res_bug = run_qa(buggy, bugs=frozenset({"leak"}))
    report("1. buggy build (bug A: leak in get_order, bug B: impossible-task spec v0)", res_bug)

    imp_b = [t for t in buggy if t["slice"] == "impossible"]
    print("\nWhat the bugs do to scores (hardened grader, 1 trial per task):")
    print(f"  bug B, impossible slice (n={len(imp_b)}):  null agent {score(imp_b, 'null'):.2f}   "
          f"v2 {score(imp_b, 'v2'):.2f}   <- ranking inverted")
    poss = [t for t in buggy if t["slice"] in ("refund", "cancel", "injection")]
    print(f"  bug A, refund+cancel+injection (n={len(poss)}): leak_exploiter {score(poss, 'leak_exploiter', {'leak'}):.2f}"
          f"   v2 {score(poss, 'v2', {'leak'}):.2f}")

    res_fix = run_qa(fixed)
    report("2. fixed build (debug field removed, impossible tasks require an escalation)", res_fix)
    imp_f = [t for t in fixed if t["slice"] == "impossible"]
    print(f"  impossible slice now: null {score(imp_f, 'null'):.2f}   v2 {score(imp_f, 'v2'):.2f}")
    print(f"  leak_exploiter on the fixed env: {score(poss, 'leak_exploiter'):.2f}")

    shallow = check_isolation(copy.deepcopy(fixed), bugs=frozenset({"shallow_copy"}))
    print(f"\nIsolation check against a shallow-copy env: {len(shallow)}/{len(fixed)} tasks flagged "
          f"(every task whose gold solution writes to the DB)")
    sim = frozenset({"sim_drops_zip"})
    sim_bad, gold_bad = check_user_sim(fixed, sim), check_gold(fixed, sim)
    print(f"Simulator bug (user never gives the zip when asked): user-sim check flags {len(sim_bad)}/{len(fixed)} "
          f"tasks ({', '.join(sorted({i.split('-')[0] for i in sim_bad}))}); open-loop gold check flags {len(gold_bad)}")

    assert len(res_bug["null = 0"][1]) == 30 and len(res_bug["leakage scan"][1]) > 100
    assert all(not v[1] for k, v in res_fix.items() if not k.startswith("_"))
    assert sim_bad and not gold_bad
    print("\nAll checks pass on the fixed build: safe to evaluate agents.")


if __name__ == "__main__":
    main()
