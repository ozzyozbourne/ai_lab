"""GRPO group-normalised advantages, zero-variance groups, and difficulty filtering.

Section 7.4 (#rlvr) of Chapter 7, Figure 7.4.  Run:  python3 code/ch07/grpo_signal.py

  * A_i = (r_i - mean(r)) / std(r) for a group of G rollouts of one prompt (population std, as in the papers'
    worked examples); a group in which every reward is equal has std 0 and contributes no gradient
  * the probability that a group of G binary rewards is mixed: 1 - p^G - (1 - p)^G  (checked by Monte Carlo)
  * a 2,000-prompt training pool whose pass rates are skewed (many impossible and many trivial prompts):
    the share of prompts that carry signal before and after filtering to an estimated pass-rate band [0.1, 0.9]
Expected key output: [1,0,0,1] -> [1,-1,-1,1]; [1,0,0,0] -> [1.73,-0.58,-0.58,-0.58]; G=8 signal fraction
0.992 / 0.832 / 0.337 at p = 0.5 / 0.2 / 0.05; filtering raises the useful share of a batch from 51.0% to 90.2%.
"""
from __future__ import annotations

import numpy as np

EPS = 1e-6


def grpo_advantages(rewards: np.ndarray) -> np.ndarray:
    r = np.asarray(rewards, dtype=float)
    return (r - r.mean()) / (r.std() + EPS)


def signal_fraction(p: float | np.ndarray, G: int) -> float | np.ndarray:
    p = np.asarray(p, dtype=float)
    return 1 - p ** G - (1 - p) ** G


def make_pool(n: int, rng: np.random.Generator) -> np.ndarray:
    """True per-prompt pass rates: 25% unsolvable (p=0), 25% near-trivial (Beta(20,1)), 50% Beta(2,2)."""
    kind = rng.choice(3, size=n, p=[0.25, 0.25, 0.5])
    p = np.where(kind == 0, 0.0, np.where(kind == 1, rng.beta(20, 1, n), rng.beta(2, 2, n)))
    return p


def batch_signal(p: np.ndarray, G: int, rng: np.random.Generator) -> float:
    """Fraction of prompts whose G sampled rewards are not all equal (non-zero advantage somewhere)."""
    r = rng.random((len(p), G)) < p[:, None]
    mixed = r.any(axis=1) & ~r.all(axis=1)
    return float(mixed.mean())


def main() -> None:
    print("Group-normalised advantages (G = 4)")
    for rw in ([1, 0, 0, 1], [1, 0, 0, 0], [1, 1, 1, 1], [0, 0, 0, 0]):
        a = grpo_advantages(np.array(rw))
        print(f"  rewards {rw} -> advantages {np.round(a, 2).tolist()}")
    assert np.allclose(grpo_advantages(np.array([1, 0, 0, 1])), [1, -1, -1, 1], atol=1e-4)
    assert np.allclose(grpo_advantages(np.array([1, 0, 0, 0])), [1.732, -0.577, -0.577, -0.577], atol=1e-3)
    assert np.allclose(grpo_advantages(np.array([1, 1, 1, 1])), 0)

    rng = np.random.default_rng(0)
    ps = [0.01, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.8, 0.9, 0.95, 0.99]
    print("\nP(group is mixed) = 1 - p^G - (1-p)^G   [Monte Carlo with 200,000 groups in brackets, G = 8]")
    print("   p    " + "".join(f"G={G:<7}" for G in (4, 8, 16)) + "  MC(G=8)")
    for p in ps:
        mc = batch_signal(np.full(200_000, p), 8, rng)
        row = "".join(f"{signal_fraction(p, G):<9.3f}" for G in (4, 8, 16))
        print(f"  {p:<5} {row} [{mc:.3f}]")
        assert abs(mc - signal_fraction(p, 8)) < 0.005
    for p, want in ((0.5, 0.992), (0.2, 0.832), (0.05, 0.337), (0.95, 0.337)):
        assert abs(signal_fraction(p, 8) - want) < 1e-3

    # Fine grid for Figure 7.4 (printed compactly so it can be pasted into the SVG).
    grid = np.linspace(0, 1, 21)
    for G in (4, 8, 16):
        print(f"  fig7.4 G={G}: " + " ".join(f"{v:.3f}" for v in signal_fraction(grid, G)))

    pool = make_pool(2000, rng)
    G = 8
    before = batch_signal(pool, G, rng)
    probe = (rng.random((len(pool), 16)) < pool[:, None]).mean(axis=1)    # 16-sample pass-rate estimate
    keep = (probe >= 0.1) & (probe <= 0.9)
    after = batch_signal(pool[keep], G, rng)
    print(f"\nTraining pool of {len(pool)} prompts, G = {G}")
    print(f"  prompts with true p = 0         : {np.mean(pool == 0):.1%}")
    print(f"  prompts with true p > 0.95      : {np.mean(pool > 0.95):.1%}")
    print(f"  batch share with signal (all)   : {before:.1%}")
    print(f"  kept by 16-sample band [0.1,0.9]: {keep.sum()} prompts ({keep.mean():.1%})")
    print(f"  batch share with signal (kept)  : {after:.1%}")
    print(f"  expected share, formula on kept : {signal_fraction(pool[keep], G).mean():.1%}")
    assert abs(before - 0.510) < 1e-3 and abs(after - 0.902) < 1e-3


if __name__ == "__main__":
    main()
