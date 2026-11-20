"""CoastRunners-lite: tabular Q-learning finds the respawning-checkpoint loop (Goodhart in 100 lines).

Section 7.5 (#reward-hacking) of Chapter 7, Figure 7.5.  Run:  python3 code/ch07/coastrunners_lite.py

A 1-D race track, cells 0..9, start at 0, finish line at 9 (terminal). Actions: 0 = left, 1 = right.
Cell 4 holds a "turbo" target that respawns: every time the boat ENTERS cell 4 the proxy pays +1.
  proxy reward : +1 per turbo hit, +3 for crossing the finish line         (what the designer wrote)
  true reward  : +1 for finishing the race, 0 otherwise                       (what the designer wanted)
Episodes are truncated after 40 steps. Q-learning (alpha 0.05, gamma 0.95, epsilon 0.05) starts from a
"pretrained" prior that races to the right (Q[s, right] = 1, like starting RL from an SFT policy) and is
trained on the proxy; every 25 episodes the greedy policy is rolled out and scored on both rewards.
Averaged over 20 training seeds. The fix: the turbo pays once per episode (state = (cell, turbo_taken)).
Expected key output: for ~800 episodes proxy (4.0) and true (1.0) agree; then exploration finds the
3 <-> 4 loop, the proxy climbs to 19.0 and the true return collapses to 0.0. The fixed reward finishes 100%.
"""
from __future__ import annotations

import numpy as np

N_CELLS, TURBO, FINISH, HORIZON = 10, 4, 9, 40
TURBO_PAY, FINISH_PAY = 1.0, 3.0
ALPHA, GAMMA, EPS, Q0 = 0.05, 0.95, 0.05, 1.0
EPISODES, EVAL_EVERY, SEEDS = 1500, 25, 20


def step(cell: int, taken: bool, action: int, respawning: bool):
    nxt = max(0, min(N_CELLS - 1, cell + (1 if action == 1 else -1)))
    proxy = 0.0
    if nxt == TURBO and nxt != cell and (respawning or not taken):
        proxy += TURBO_PAY
        taken = True
    done = nxt == FINISH
    true = 1.0 if done else 0.0
    if done:
        proxy += FINISH_PAY
    return nxt, taken, proxy, true, done


def state_index(cell: int, taken: bool, respawning: bool) -> int:
    return cell if respawning else cell + N_CELLS * int(taken)


def greedy_returns(q: np.ndarray, respawning: bool) -> tuple[float, float]:
    cell, taken, P, T = 0, False, 0.0, 0.0
    for _ in range(HORIZON):
        a = int(np.argmax(q[state_index(cell, taken, respawning)]))
        cell, taken, p, t, done = step(cell, taken, a, respawning)
        P, T = P + p, T + t
        if done:
            break
    return P, T


def train(seed: int, respawning: bool) -> np.ndarray:
    rng = np.random.default_rng(seed)
    q = np.zeros((2 * N_CELLS, 2))
    q[:, 1] = Q0                     # "pretrained" prior: prefers racing to the right (like an SFT start)
    q[FINISH] = q[FINISH + N_CELLS] = 0.0
    curve = []
    for ep in range(EPISODES + 1):
        if ep % EVAL_EVERY == 0:
            curve.append(greedy_returns(q, respawning))
        cell, taken = 0, False
        for _ in range(HORIZON):
            s = state_index(cell, taken, respawning)
            a = int(rng.integers(2)) if rng.random() < EPS else int(np.argmax(q[s] + 1e-9 * rng.random(2)))
            cell, taken, p, _, done = step(cell, taken, a, respawning)
            s2 = state_index(cell, taken, respawning)
            target = p + (0.0 if done else GAMMA * q[s2].max())   # truncation (t = 40) still bootstraps
            q[s, a] += ALPHA * (target - q[s, a])
            if done:
                break
    return np.array(curve)


def main() -> None:
    hacked = np.mean([train(s, respawning=True) for s in range(SEEDS)], axis=0)
    fixed = np.mean([train(s, respawning=False) for s in range(SEEDS)], axis=0)
    eps = np.arange(0, EPISODES + 1, EVAL_EVERY)
    print("Greedy-policy returns during training (mean of 20 seeds)")
    print(f"{'episode':>7} | {'proxy':>6} {'true':>5}  (respawning turbo) | {'proxy':>6} {'true':>5}  (turbo pays once)")
    for i in range(0, len(eps), 4):
        print(f"{eps[i]:>7} | {hacked[i, 0]:6.2f} {hacked[i, 1]:5.2f}                     | "
              f"{fixed[i, 0]:6.2f} {fixed[i, 1]:5.2f}")
    first_drop = int(np.argmax(hacked[:, 1] < 1.0))
    print(f"\nrespawning turbo: true return first drops below 1.0 at episode {eps[first_drop]}, "
          f"ends at {hacked[-1, 1]:.2f}; proxy ends at {hacked[-1, 0]:.2f}")
    print(f"turbo pays once : true return ends at {fixed[-1, 1]:.2f}; proxy ends at {fixed[-1, 0]:.2f}")
    print("fig7.5 episodes: " + " ".join(str(e) for e in eps[::2]))
    print("fig7.5 proxy   : " + " ".join(f"{v:.2f}" for v in hacked[::2, 0]))
    print("fig7.5 true    : " + " ".join(f"{v:.2f}" for v in hacked[::2, 1]))
    assert hacked[0, 1] == 1.0 and hacked[0, 0] == 4.0
    assert hacked[-1, 1] <= 0.05 and hacked[-1, 0] >= 18.5
    assert fixed[-1, 1] == 1.0 and fixed[-1, 0] == 4.0


if __name__ == "__main__":
    main()
