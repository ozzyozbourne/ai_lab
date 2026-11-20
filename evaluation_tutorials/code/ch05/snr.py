"""Benchmark signal, noise, SNR and decision accuracy (after Heineman et al. 2025), plus monotonicity.

Chapter 5, section 5.11 (#snr).
Run:  python3 code/ch05/snr.py
Shows: 12 mock 'small' models with a known large-scale ranking. Each benchmark (size n) is scored
either as 0/1 accuracy or as a continuous metric (mean probability of the correct answer).
Signal = max pairwise gap / mean score across models; noise = relative sd over a model's final
5 checkpoints; SNR = signal / noise; decision accuracy = share of model pairs ranked as at large scale.
Across 10 benchmark configurations SNR tracks decision accuracy; the continuous metric has higher SNR.
Monotonicity = Kendall tau of the score with training step (Madaan et al. 2024).
"""
from __future__ import annotations

import itertools

import numpy as np

N_MODELS, N_CKPT = 12, 5


def sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def kendall_tau(x: np.ndarray, y: np.ndarray) -> float:
    s = 0.0
    pairs = list(itertools.combinations(range(len(x)), 2))
    for i, j in pairs:
        s += np.sign(x[i] - x[j]) * np.sign(y[i] - y[j])
    return float(s / len(pairs))


def scores(rng: np.random.Generator, skill: np.ndarray, b: np.ndarray, metric: str) -> np.ndarray:
    """Score of each model (rows of skill) on items with difficulty b."""
    p = sigmoid(skill[:, None] - b[None, :])
    if metric == "accuracy":
        return (rng.random(p.shape) < p).mean(axis=1)
    return p.mean(axis=1)  # continuous: probability mass on the correct answer


def evaluate(n_items: int, metric: str, seed: int, reps: int = 200) -> tuple[float, float, float, float]:
    rng = np.random.default_rng(seed)
    true_skill = np.linspace(-0.3, 0.3, N_MODELS)          # large-scale ranking = this order
    b = rng.normal(0.0, 1.5, size=n_items)                 # a fixed benchmark
    sig, noi, da = [], [], []
    for _ in range(reps):
        # final checkpoints jitter around the model's skill (training noise)
        ck = true_skill[:, None] + rng.normal(0, 0.04, size=(N_MODELS, N_CKPT))
        sc = np.stack([scores(rng, ck[:, t], b, metric) for t in range(N_CKPT)], axis=1)
        m = sc.mean(axis=1)
        sig.append((m.max() - m.min()) / m.mean())
        noi.append(np.mean(sc.std(axis=1, ddof=1) / sc.mean(axis=1)))
        last = sc[:, -1]
        agree = [np.sign(last[i] - last[j]) == np.sign(true_skill[i] - true_skill[j])
                 for i, j in itertools.combinations(range(N_MODELS), 2)]
        da.append(np.mean(agree))
    s, n_ = float(np.mean(sig)), float(np.mean(noi))
    return s, n_, s / n_, float(np.mean(da))


def main() -> None:
    print(f"{'benchmark':<22} {'signal':>7} {'noise':>7} {'SNR':>6} {'decision acc':>13}")
    rows = []
    for metric in ("accuracy", "continuous"):
        for k, n in enumerate((30, 100, 300, 1000, 3000)):
            s, no, snr, da = evaluate(n, metric, seed=10 + k)
            rows.append((metric, n, s, no, snr, da))
            print(f"{metric + ', n=' + str(n):<22} {s:7.3f} {no:7.4f} {snr:6.1f} {da:13.3f}")
    snr = np.array([r[4] for r in rows])
    da = np.array([r[5] for r in rows])
    sig = np.array([r[2] for r in rows])
    r_snr = float(np.corrcoef(np.log(snr), da)[0, 1])
    r_sig = float(np.corrcoef(sig, da)[0, 1])
    print(f"\ncorrelation across the 10 configurations: corr(log SNR, DA) = {r_snr:.3f}; corr(signal, DA) = {r_sig:.3f}")
    for n in (30, 100, 300, 1000, 3000):
        acc = next(r for r in rows if r[0] == "accuracy" and r[1] == n)
        con = next(r for r in rows if r[0] == "continuous" and r[1] == n)
        assert con[4] > acc[4] and con[5] >= acc[5] - 0.01
    assert r_snr > 0.9

    # Monotonicity: scores along 20 training steps of one model whose skill rises slowly
    rng = np.random.default_rng(77)
    steps = np.arange(20)
    skill = -0.5 + 0.02 * steps
    b = rng.normal(0, 1.5, size=300)
    acc = [scores(rng, np.array([s]), b, "accuracy")[0] for s in skill]
    con = [scores(rng, np.array([s]), b, "continuous")[0] for s in skill]
    m_acc, m_con = kendall_tau(steps.astype(float), np.array(acc)), kendall_tau(steps.astype(float), np.array(con))
    print(f"monotonicity over 20 checkpoints (n=300): accuracy tau = {m_acc:.2f}, continuous tau = {m_con:.2f}")
    assert m_con > m_acc


if __name__ == "__main__":
    main()
