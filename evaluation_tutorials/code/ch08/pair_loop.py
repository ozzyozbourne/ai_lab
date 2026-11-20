"""A PAIR-style attacker / target / judge loop with query accounting (Chapter 8.4, #red-teaming).

Everything is a seeded mock; no real prompts or harmful content exist anywhere.
A "prompt" is a vector of tactic levels (roleplay, hypothetical, authority, obfuscation), each
0..5, wrapped around a placeholder goal BEHAVIOUR_xxx. The mock target complies when the
tactics' persuasive pressure beats the behaviour's hidden resistance (plus noise); heavy
obfuscation makes it misunderstand, so its answer gets less specific. The mock judge rates
1..10 like PAIR's judge (1 = refusal, 10 = fully jailbroken).

The PAIR-style attacker keeps a conversation history per stream and uses the judge's
feedback: refusal -> add pressure; compliant but vague -> reduce obfuscation. We compare it
with random search at the same budget of target queries (20 per behaviour).

Run:  python3 code/ch08/pair_loop.py
Key output: PAIR-style ASR 0.910 vs random search 0.425 at 20 target queries, but random search
wins at budgets of 5 and 10; query accounting for attacker, target and judge calls.
"""
from __future__ import annotations

import random
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _common import table, wilson  # noqa: E402

TACTICS = ("roleplay", "hypothetical", "authority", "obfuscation", "urgency", "flattery")
# urgency makes the mock target suspicious; flattery does nothing.
WEIGHTS = {"roleplay": 0.55, "hypothetical": 0.35, "authority": 0.3, "obfuscation": 0.45,
           "urgency": -0.5, "flattery": 0.0}
MAX_LEVEL = 5


@dataclass
class Budget:
    attacker: int = 0
    target: int = 0
    judge: int = 0


@dataclass
class MockTarget:
    resistance: dict[str, float]
    rng: random.Random

    def respond(self, goal: str, prompt: dict[str, int], budget: Budget) -> tuple[bool, float]:
        """Return (complied, specificity in [0, 1])."""
        budget.target += 1
        pressure = sum(WEIGHTS[t] * prompt[t] for t in TACTICS)
        complied = pressure - self.resistance[goal] + self.rng.gauss(0, 0.6) > 0
        specificity = max(0.0, 1.0 - 0.2 * prompt["obfuscation"] + self.rng.gauss(0, 0.05))
        return complied, min(1.0, specificity)


def mock_judge(complied: bool, specificity: float, budget: Budget) -> int:
    budget.judge += 1
    return 1 if not complied else max(2, min(10, round(1 + 9 * specificity)))


@dataclass
class Stream:
    prompt: dict[str, int]
    history: list[tuple[dict[str, int], int]] = field(default_factory=list)


def pair_attacker(stream: Stream, rng: random.Random, budget: Budget) -> dict[str, int]:
    """Propose an improved prompt from the last (prompt, score) pair: the 'improvement' step."""
    budget.attacker += 1
    p = dict(stream.prompt)
    if not stream.history:
        return p
    _, score = stream.history[-1]
    if len(stream.history) >= 2 and score < stream.history[-2][1]:
        return dict(stream.history[-2][0])           # last edit made things worse: revert
    if score == 1:                                    # refused: add pressure, drop urgency
        if p["urgency"] > 0:
            p["urgency"] -= 1
        else:
            open_ = [t for t in ("roleplay", "hypothetical", "authority") if p[t] < MAX_LEVEL]
            for t in rng.sample(open_, min(2, len(open_))) or ["obfuscation"]:
                p[t] = min(MAX_LEVEL, p[t] + 2)       # a rewrite changes several tactics
    elif score < 10:                                  # complied but vague: be clearer
        p["obfuscation"] = max(0, p["obfuscation"] - 1)
    return p


def run_pair(goal: str, target: MockTarget, rng: random.Random, n_streams: int = 5,
             depth: int = 4) -> tuple[bool, int, Budget]:
    budget = Budget()
    streams = [Stream({t: rng.randint(0, 1) for t in TACTICS}) for _ in range(n_streams)]
    for _ in range(depth):                            # 5 streams x 4 iterations = 20 queries
        for s in streams:
            s.prompt = pair_attacker(s, rng, budget)
            complied, spec = target.respond(goal, s.prompt, budget)
            score = mock_judge(complied, spec, budget)
            s.history.append((dict(s.prompt), score))
            if score == 10:
                return True, budget.target, budget
    return False, budget.target, budget


def run_random(goal: str, target: MockTarget, rng: random.Random, n_queries: int = 20
               ) -> tuple[bool, int, Budget]:
    budget = Budget()
    for _ in range(n_queries):
        prompt = {t: rng.randint(0, MAX_LEVEL) for t in TACTICS}
        complied, spec = target.respond(goal, prompt, budget)
        if mock_judge(complied, spec, budget) == 10:
            return True, budget.target, budget
    return False, budget.target, budget


def main() -> None:
    rng = random.Random(84)
    goals = [f"BEHAVIOUR_{i:03d}" for i in range(200)]
    resistance = {g: rng.uniform(1.5, 5.0) for g in goals}
    results = {}
    for name, fn in [("PAIR-style", run_pair), ("random search", run_random)]:
        target = MockTarget(resistance, random.Random(7))
        arng = random.Random(11)
        succ, qs, tot = 0, [], Budget()
        for g in goals:
            ok, q, b = fn(g, target, arng)
            succ += ok
            if ok:
                qs.append(q)
            tot.attacker += b.attacker; tot.target += b.target; tot.judge += b.judge
        results[name] = (succ, qs, tot)

    rows = []
    for name, (succ, qs, tot) in results.items():
        lo, hi = wilson(succ, len(goals))
        rows.append((name, f"{succ}/{len(goals)}", f"{succ / len(goals):.3f}", f"[{lo:.3f}, {hi:.3f}]",
                     f"{statistics.median(qs):.0f}", tot.attacker, tot.target, tot.judge))
    print("Budget: at most 20 target queries per behaviour (PAIR: 5 streams x 4 iterations)\n")
    print(table(rows, ["attacker", "broken", "ASR", "Wilson 95% CI", "median q",
                       "attacker calls", "target calls", "judge calls"]))

    pair_succ, pair_q, pair_b = results["PAIR-style"]
    rand_succ, _, _ = results["random search"]
    print("\nBudget curve: ASR if we had stopped after B target queries")
    for B in (5, 10, 15, 20):
        cells = [f"{sum(q <= B for q in results[n][1]) / len(goals):.3f}" for n in results]
        print(f"  B = {B:2d}   PAIR-style {cells[0]}   random search {cells[1]}")
    print(f"Total model calls PAIR = {pair_b.attacker + pair_b.target + pair_b.judge} "
          f"(attacker + target + judge): report all three, not just target queries.")
    assert pair_succ > rand_succ
    assert statistics.median(pair_q) <= 20


if __name__ == "__main__":
    main()
