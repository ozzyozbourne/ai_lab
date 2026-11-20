"""Signal-to-noise of a benchmark under a discrete vs a continuous metric (after Heineman et al. 2025),
and the emergence 'mirage' (after Schaeffer et al. 2023): exact match on a multi-token answer jumps
while per-token accuracy rises smoothly.

Chapter 2, section 2.9 (#noise) and Figure 2.6.
Run:  python3 code/ch02/saturation_and_noise.py
Expected key output: the continuous metric has a higher SNR and ranks model pairs correctly more often;
exact match over 10 tokens stays ~0 while per-token accuracy climbs from 0.23 to 0.61, then 'emerges'.
"""
from __future__ import annotations

import itertools

import numpy as np


def sigmoid(x):
    return 1 / (1 + np.exp(-x))


def checkpoint_scores(rng, ability: float, difficulty: np.ndarray, n_ckpt: int):
    """Scores of the last n_ckpt checkpoints of one training run.
    Each checkpoint jitters the ability a little (training-step noise); accuracy also has
    Bernoulli sampling noise, while the continuous metric (mean NLL of the gold answer) does not."""
    acc, nll = [], []
    for _ in range(n_ckpt):
        a = ability + rng.normal(0, 0.05)
        p = sigmoid(a - difficulty)                       # P(gold answer ranked first)
        acc.append(float(np.mean(rng.random(len(p)) < p)))
        nll.append(float(np.mean(-np.log(p))))           # lower is better
    return np.array(acc), np.array(nll)


def snr(finals: np.ndarray, ckpts: list[np.ndarray]) -> tuple[float, float, float]:
    signal = (finals.max() - finals.min()) / abs(finals.mean())          # relative dispersion
    noise = float(np.mean([c.std(ddof=1) / abs(c.mean()) for c in ckpts]))  # relative std over checkpoints
    return signal, noise, signal / noise


def pairwise_accuracy(ckpts: list[np.ndarray], abilities: np.ndarray, higher_better: bool, rng, trials=2000):
    """Fraction of (pair, random checkpoint) draws where the metric orders the two models correctly."""
    pairs = list(itertools.combinations(range(len(abilities)), 2))
    ok = 0
    for _ in range(trials):
        i, j = pairs[rng.integers(len(pairs))]
        si, sj = ckpts[i][rng.integers(len(ckpts[i]))], ckpts[j][rng.integers(len(ckpts[j]))]
        if not higher_better:
            si, sj = -si, -sj
        ok += int((si > sj) == (abilities[i] > abilities[j]))
    return ok / trials


if __name__ == "__main__":
    rng = np.random.default_rng(5)
    difficulty = rng.normal(0.0, 1.5, size=300)        # a 300-item benchmark
    abilities = np.array([-0.30, -0.25, -0.20, -0.15, -0.10])  # five small models, close together
    accs, nlls = [], []
    for ab in abilities:
        acc, nll = checkpoint_scores(rng, ab, difficulty, n_ckpt=10)
        accs.append(acc)
        nlls.append(nll)
    fin_acc = np.array([c[-1] for c in accs])
    fin_nll = np.array([c[-1] for c in nlls])
    s_a, n_a, r_a = snr(fin_acc, accs)
    s_c, n_c, r_c = snr(fin_nll, nlls)
    pa_a = pairwise_accuracy(accs, abilities, True, np.random.default_rng(0))
    pa_c = pairwise_accuracy(nlls, abilities, False, np.random.default_rng(0))
    print("== Signal and noise, 5 models x 10 final checkpoints, 300 items ==")
    print(f"{'metric':<26}{'signal':>8}{'noise':>8}{'SNR':>7}{'pairs ordered right':>21}")
    print(f"{'accuracy (0/1 per item)':<26}{s_a:>8.3f}{n_a:>8.3f}{r_a:>7.1f}{pa_a:>21.3f}")
    print(f"{'gold-answer NLL (cont.)':<26}{s_c:>8.3f}{n_c:>8.3f}{r_c:>7.1f}{pa_c:>21.3f}")
    assert r_c > r_a and pa_c > pa_a

    print("\n== The emergence mirage: one smooth skill, two metrics ==")
    L = 10                                             # answer is 10 tokens long; EM needs all 10 right
    log_scale = np.arange(7.0, 12.01, 0.5)             # log10(parameters), 1e7 .. 1e12
    p_tok = sigmoid(1.1 * (log_scale - 9.0) + 1.0)     # smooth per-token accuracy
    em_rng = np.random.default_rng(9)
    print(f"{'log10 N':>8}{'per-token acc':>15}{'exact match (p^L)':>19}{'EM measured, 500 items':>24}")
    em_meas = []
    for s, p in zip(log_scale, p_tok):
        tokens_right = em_rng.random((500, L)) < p
        em = float(np.mean(tokens_right.all(axis=1)))
        em_meas.append(em)
        print(f"{s:>8.1f}{p:>15.3f}{p ** L:>19.3f}{em:>24.3f}")
    em_exact = p_tok ** L
    flat = log_scale[em_exact < 0.01]
    print(f"exact match (p^L) stays below 0.01 up to log10 N = {flat.max():.1f}, while per-token accuracy"
          f" climbs {p_tok[0]:.2f} -> {p_tok[len(flat) - 1]:.2f} over the same range")
    assert em_exact[0] < 0.01 and em_exact[-1] > 0.6 and np.all(np.diff(p_tok) > 0)
