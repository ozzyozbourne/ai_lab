"""Cost-accuracy Pareto frontier for agent strategies (after Kapoor et al., "AI Agents That Matter").

Section 6.7 (#cost) of Chapter 6.  Run:  python3 code/ch06/pareto.py

300 synthetic coding tasks with a latent difficulty.  Three mock models (cheap, mid, strong)
with per-call prices.  Strategies:
  single      one attempt
  retry5      up to 5 attempts, stop when the task's *visible* tests pass (they can be fooled)
  escalate    cheap -> mid -> strong, move up only when visible tests fail
  "complex"   a fixed 8-call reflect-and-revise loop on the strong model (cost does not adapt)
We report accuracy on hidden tests (with a 95% CI), mean $ per task, $ per resolved task,
mean model calls (a proxy for latency), and which strategies are on the Pareto frontier.
Expected key output: escalation is on the frontier; strong retry5 dominates the complex agent.
Exercise 6.4:  --fooled 0.5  (common random numbers: the complex agent's score does not change).
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from math import sqrt

import numpy as np

N_TASKS = 300
MODELS = {"cheap": (0.0, 0.002), "mid": (1.0, 0.010), "strong": (2.0, 0.040)}   # (skill, $ per call)
P_VISIBLE_FOOLED = 0.15          # a wrong solution passes the visible tests 15% of the time


def p_solve(skill: float, difficulty: np.ndarray) -> np.ndarray:
    return 1 / (1 + np.exp(-(skill - difficulty)))


@dataclass
class Result:
    name: str
    acc: float
    cost: float
    calls: float

    @property
    def ci(self) -> float:
        return 1.96 * sqrt(self.acc * (1 - self.acc) / N_TASKS)

    @property
    def cost_per_resolved(self) -> float:
        return self.cost / self.acc


def run_strategy(name: str, plan: list[str], difficulty: np.ndarray, u: dict[str, np.ndarray],
                 adaptive: bool = True) -> Result:
    """plan = sequence of models to call; stop early on visible-test pass if adaptive.

    u holds common random numbers shared by every strategy (u["ok"][task, attempt],
    u["fool"][task, attempt], u["final"][task]), so strategies are compared on the same luck and
    changing one parameter cannot shift another strategy's draws."""
    correct, cost, calls = 0, 0.0, 0
    for i, d in enumerate(difficulty):
        final_ok = False
        for j, m in enumerate(plan):
            skill, price = MODELS[m]
            cost += price
            calls += 1
            ok = u["ok"][i, j] < p_solve(skill, np.array([d]))[0]
            visible_pass = ok or u["fool"][i, j] < P_VISIBLE_FOOLED
            final_ok = ok
            if adaptive and visible_pass:
                break
        if not adaptive:   # complex agent: answer quality improves with its own reflection loop
            final_ok = u["final"][i] < p_solve(MODELS["strong"][0] + 0.6, np.array([d]))[0]
        correct += final_ok
    return Result(name, correct / len(difficulty), cost / len(difficulty), calls / len(difficulty))


def pareto_front(results: list[Result]) -> set[str]:
    front = set()
    for r in results:
        dominated = any((o.cost <= r.cost and o.acc >= r.acc) and (o.cost < r.cost or o.acc > r.acc)
                        for o in results)
        if not dominated:
            front.add(r.name)
    return front


def main() -> None:
    global P_VISIBLE_FOOLED
    ap = argparse.ArgumentParser()
    ap.add_argument("--fooled", type=float, default=P_VISIBLE_FOOLED,
                    help="P(wrong solution passes visible tests); Exercise 6.4 uses 0.5")
    P_VISIBLE_FOOLED = ap.parse_args().fooled
    default = P_VISIBLE_FOOLED == 0.15
    if not default:
        print(f"P_VISIBLE_FOOLED = {P_VISIBLE_FOOLED}")
    rng = np.random.default_rng(3)
    difficulty = rng.normal(1.0, 1.5, size=N_TASKS)
    max_calls = 8
    u = {"ok": rng.random((N_TASKS, max_calls)), "fool": rng.random((N_TASKS, max_calls)),
         "final": rng.random(N_TASKS)}
    strategies = [
        ("cheap single", ["cheap"], True),
        ("mid single", ["mid"], True),
        ("strong single", ["strong"], True),
        ("cheap retry5", ["cheap"] * 5, True),
        ("strong retry5", ["strong"] * 5, True),
        ("escalate c->m->s", ["cheap", "mid", "strong"], True),
        ("escalate+retry", ["cheap", "cheap", "mid", "mid", "strong", "strong"], True),
        ("complex agent", ["strong"] * 8, False),
    ]
    results = [run_strategy(n, plan, difficulty, u, adaptive=a) for n, plan, a in strategies]
    front = pareto_front(results)
    print(f"{'strategy':<18} {'accuracy':>8} {'95% CI':>8} {'$/task':>8} {'$/resolved':>10} {'calls':>6}  frontier")
    for r in sorted(results, key=lambda r: r.cost):
        print(f"{r.name:<18} {r.acc:>8.3f} {'+/-' + format(r.ci, '.3f'):>8} {r.cost:>8.4f} "
              f"{r.cost_per_resolved:>10.4f} {r.calls:>6.2f}  {'*' if r.name in front else ''}")
    by = {r.name: r for r in results}
    print("\nFigure 6.4 points (cost, accuracy):",
          ", ".join(f"{r.name}=({r.cost:.4f}, {r.acc:.3f})" for r in results))
    if default:
        assert "escalate c->m->s" in front or "escalate+retry" in front
        assert "complex agent" not in front
    cx, sr = by["complex agent"], by["strong retry5"]
    print(f"\ncomplex agent: {cx.cost / sr.cost:.1f}x the cost of strong retry5 for "
          f"{100 * (cx.acc - sr.acc):+.1f} points (CI half-width about {100 * cx.ci:.1f} points); "
          f"{cx.cost / by['escalate+retry'].cost:.1f}x escalate+retry for {100 * (cx.acc - by['escalate+retry'].acc):+.1f}")
    if default:
        assert sr.cost < cx.cost and sr.acc > cx.acc

if __name__ == "__main__":
    main()
