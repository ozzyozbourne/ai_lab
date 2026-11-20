"""Train/test level splits and sticky actions: a memorising policy vs a reactive one on seeded mazes.

Section 7.7 (#policy-eval) of Chapter 7.  Run:  python3 code/ch07/procgen_split.py

Level generator: seed -> a perfect 6x6 maze (randomised depth-first search), start top-left, goal bottom-right.
  memoriser : during "training" stores the shortest action sequence for each of the 200 training seeds; on a
              level it has stored it replays that sequence open-loop; on any other level it replays the
              sequence of a random training level (it has no idea where the walls are)
  reactive  : a closed-loop wall follower (keep your right hand on the wall); slower, but works on any perfect maze
Evaluation follows the Procgen protocol: success on the training levels vs on 500 held-out levels
(the generalisation gap), with Wilson 95% intervals; then the same with sticky actions (Machado et al.:
with probability 0.25 the environment repeats the previous action instead of the chosen one).
Episode budget: 4x the shortest path. Normalised return R_norm = (R - R_min)/(R_max - R_min), with R = 1 - steps/budget on success.
Expected key output: memoriser 1.000 on train levels, 0.032 held out (gap 0.97), and 0.060 on its own train levels
under sticky actions; the reactive policy scores 0.995 / 0.984 (gap 0.01) and degrades gracefully to 0.94 / 0.92.
"""
from __future__ import annotations

import math
import random
from collections import deque

N = 6
MOVES = [(-1, 0), (0, 1), (1, 0), (0, -1)]          # up, right, down, left


def make_maze(seed: int) -> dict[tuple[int, int], set[int]]:
    """Open passages: cell -> set of directions you can move in."""
    rng = random.Random(seed)
    open_dirs = {(r, c): set() for r in range(N) for c in range(N)}
    stack, seen = [(0, 0)], {(0, 0)}
    while stack:
        r, c = stack[-1]
        nbrs = [(d, (r + dr, c + dc)) for d, (dr, dc) in enumerate(MOVES)
                if 0 <= r + dr < N and 0 <= c + dc < N and (r + dr, c + dc) not in seen]
        if not nbrs:
            stack.pop()
            continue
        d, nxt = rng.choice(nbrs)
        open_dirs[(r, c)].add(d)
        open_dirs[nxt].add((d + 2) % 4)
        seen.add(nxt)
        stack.append(nxt)
    return open_dirs


def shortest_actions(maze) -> list[int]:
    goal, prev = (N - 1, N - 1), {(0, 0): None}
    q = deque([(0, 0)])
    while q:
        cell = q.popleft()
        for d in maze[cell]:
            nxt = (cell[0] + MOVES[d][0], cell[1] + MOVES[d][1])
            if nxt not in prev:
                prev[nxt] = (cell, d)
                q.append(nxt)
    acts, cell = [], goal
    while prev[cell] is not None:
        cell, d = prev[cell]
        acts.append(d)
    return acts[::-1]


def episode(maze, policy, budget: int, sticky: float, rng: random.Random) -> tuple[bool, int]:
    cell, heading, last = (0, 0), 1, None
    state = {"t": 0, "heading": heading}
    for t in range(budget):
        a = policy(cell, maze, state)
        if last is not None and rng.random() < sticky:
            a = last                                     # sticky action: env repeats the previous action
        last = a
        if a in maze[cell]:
            cell = (cell[0] + MOVES[a][0], cell[1] + MOVES[a][1])
            state["heading"] = a
        state["t"] = t + 1
        if cell == (N - 1, N - 1):
            return True, t + 1
    return False, budget


def make_memoriser(train_seeds: list[int], rng: random.Random):
    table = {s: shortest_actions(make_maze(s)) for s in train_seeds}

    def for_level(seed: int):
        seq = table.get(seed) or table[rng.choice(train_seeds)]

        def policy(cell, maze, state):
            return seq[state["t"]] if state["t"] < len(seq) else 1
        return policy
    return for_level


def reactive(cell, maze, state):
    h = state["heading"]
    for d in ((h + 1) % 4, h, (h + 3) % 4, (h + 2) % 4):   # right, straight, left, back
        if d in maze[cell]:
            return d
    return h


def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    p = k / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return centre - half, centre + half


def evaluate(policy_for, seeds, sticky, rng):
    wins, norm = 0, 0.0
    for s in seeds:
        maze = make_maze(s)
        budget = 4 * len(shortest_actions(maze))
        ok, steps = episode(maze, policy_for(s), budget, sticky, rng)
        wins += ok
        norm += (1 - steps / budget) if ok else 0.0       # R_min = 0, R_max = 1, so R_norm = R
    return wins, len(seeds), norm / len(seeds)


def main() -> None:
    rng = random.Random(0)
    train, test = list(range(200)), list(range(10_000, 10_500))
    mem = make_memoriser(train, rng)
    rows = {}
    print(f"{'policy':<10} {'sticky':>6} | {'train success':>22} | {'held-out success':>22} | {'gap':>5} | R_norm test")
    for name, pf in (("memoriser", mem), ("reactive", lambda s: reactive)):
        for sticky in (0.0, 0.25):
            k1, n1, _ = evaluate(pf, train, sticky, rng)
            k2, n2, rn = evaluate(pf, test, sticky, rng)
            lo1, hi1 = wilson(k1, n1)
            lo2, hi2 = wilson(k2, n2)
            rows[(name, sticky)] = (k1 / n1, k2 / n2)
            print(f"{name:<10} {sticky:>6} | {k1 / n1:6.3f} [{lo1:.3f}, {hi1:.3f}] | {k2 / n2:6.3f} [{lo2:.3f}, {hi2:.3f}]"
                  f" | {k1 / n1 - k2 / n2:5.2f} | {rn:.3f}")
    print(f"\nnormalised return worked example: R = 6, R_min = 0, R_max = 10 -> {(6 - 0) / (10 - 0):.1f}")
    assert rows[("memoriser", 0.0)][0] == 1.0 and rows[("memoriser", 0.0)][1] < 0.1
    assert rows[("memoriser", 0.25)][0] < 0.5
    assert rows[("reactive", 0.0)] == (0.995, 0.984)
    assert abs(rows[("reactive", 0.25)][0] - rows[("reactive", 0.25)][1]) < 0.03


if __name__ == "__main__":
    main()
