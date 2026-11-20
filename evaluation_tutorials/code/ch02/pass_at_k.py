"""The unbiased pass@k estimator (Chen et al. 2021), its numerically stable product form,
and why the plug-in estimator 1 - (1 - c/n)^k is biased low.

Chapter 2, section 2.5 (#pass-at-k) and Figure 2.4.
Run:  python3 code/ch02/pass_at_k.py
Expected key output: pass@5 = 0.9167 for n=10, c=3; n=200, c=10 gives 0.4085 at k=10;
E[plug-in] = 0.3485 vs true 0.4095 at p=0.1, n=10, k=5; a table of pass@k vs k;
greedy pass@1 0.60 vs avg@8 0.40 vs maj@8 0.60 vs pass@8 0.80 on a 5-problem mock (#pass-at-k-reasoning);
a weak test suite passes a buggy function that an extended (EvalPlus-style) test rejects;
the best temperature for pass@1 is lower than for pass@20/pass@100.
"""
from __future__ import annotations

import math
from collections import Counter

import numpy as np


def pass_at_k_comb(n: int, c: int, k: int) -> float:
    """1 - C(n-c, k) / C(n, k): P(at least one of k draws without replacement passes)."""
    if n - c < k:
        return 1.0
    return 1.0 - math.comb(n - c, k) / math.comb(n, k)


def pass_at_k_prod(n: int, c: int, k: int) -> float:
    """Product form used by openai/human-eval; never forms huge binomial coefficients."""
    if n - c < k:
        return 1.0
    return 1.0 - float(np.prod(1.0 - k / np.arange(n - c + 1, n + 1)))


def plug_in(n: int, c: int, k: int) -> float:
    """Biased: treats p_hat = c/n as the truth and samples WITH replacement."""
    return 1.0 - (1.0 - c / n) ** k


def binom_pmf(n: int, c: int, p: float) -> float:
    return math.comb(n, c) * p ** c * (1 - p) ** (n - c)


def expectation(estimator, n: int, k: int, p: float) -> float:
    """Exact E[estimator] when c ~ Binomial(n, p)."""
    return sum(binom_pmf(n, c, p) * estimator(n, c, k) for c in range(n + 1))


# ---------- pass@1 vs avg@n vs maj@k (section 2.5, #pass-at-k-reasoning) ----------
# Per problem: gold answer, the greedy (T=0) answer, and 8 extracted answers sampled at T > 0.
# None = no answer could be extracted (here: the sample hit max_tokens); it is scored as wrong.
MOCK = [
    (12,  12,  [12, 12, 12, 13, 12, 12, 11, 12]),
    (7,   9,   [7, 9, 9, 7, 9, 7, 9, 9]),
    (30,  30,  [30, 28, None, 30, 31, 30, 28, 25]),
    (5,   4,   [4, 4, 4, 4, 6, 4, 4, 4]),
    (100, 100, [100, None, None, 90, 100, None, 100, 100]),
]


def majority(answers: list) -> object:
    """Most frequent extracted answer; unextractable samples (None) do not vote."""
    votes = Counter(a for a in answers if a is not None)
    return votes.most_common(1)[0][0] if votes else None


def reasoning_metrics(mock, k: int) -> dict[str, float]:
    greedy = float(np.mean([g == gold for gold, g, _ in mock]))
    n = len(mock[0][2])
    cs = [sum(a == gold for a in s) for gold, _, s in mock]
    return {
        "greedy pass@1": greedy,
        f"avg@{n} (= unbiased pass@1, c/n)": float(np.mean([c / n for c in cs])),
        f"maj@{n} (cons@{n})": float(np.mean([majority(s) == gold for gold, _, s in mock])),
        f"pass@{k} (unbiased, n={n})": float(np.mean([pass_at_k_comb(n, c, k) for c in cs])),
        f"pass@{n}": float(np.mean([c > 0 for c in cs])),
        "truncation rate": float(np.mean([a is None for _, _, s in mock for a in s])),
    }


# ---------- weak tests inflate pass@k (EvalPlus-style) ----------
def buggy_mean(xs: list[float]) -> float:
    return sum(xs) / len(xs)                  # spec: return 0.0 for an empty list; this crashes


def passes(fn, tests) -> bool:
    try:
        return all(fn(x) == want for x, want in tests)
    except Exception:
        return False


BASE_TESTS = [([1, 2, 3], 2), ([5], 5), ([2, 4], 3)]
PLUS_TESTS = BASE_TESTS + [([], 0.0)]         # one extra edge case


# ---------- best temperature depends on k ----------
def p_at_temperature(T: float, margins: np.ndarray, n_alt: int = 9, n_junk: float = 1e4, junk: float = 8.0):
    """Exact per-problem success probability when sampling at temperature T from one correct
    program (logit = margin), n_alt plausible wrong programs (logit 0) and many junk programs
    (logit -junk) whose share only becomes large at high T."""
    num = np.exp(margins / T)
    return num / (num + n_alt + n_junk * np.exp(-junk / T))


if __name__ == "__main__":
    print("== Worked examples ==")
    for n, c, k in [(10, 3, 1), (10, 3, 5), (200, 10, 1), (200, 10, 10), (200, 10, 100)]:
        a, b = pass_at_k_comb(n, c, k), pass_at_k_prod(n, c, k)
        assert abs(a - b) < 1e-12
        print(f"n={n:<4} c={c:<3} k={k:<4} pass@k = {a:.4f}   (product form {b:.4f})")
    assert abs(pass_at_k_comb(10, 3, 5) - 0.9167) < 1e-4
    assert abs(pass_at_k_comb(200, 10, 10) - 0.4085) < 1e-4
    assert abs(pass_at_k_comb(200, 10, 100) - 0.9992) < 1e-4
    # all (n, c, k) small cases agree
    assert all(abs(pass_at_k_comb(n, c, k) - pass_at_k_prod(n, c, k)) < 1e-12
               for n in range(1, 40) for c in range(n + 1) for k in range(1, n + 1))

    print("\n== Bias: exact expectation over c ~ Binomial(n=10, p=0.1), k=5 ==")
    n, k, p = 10, 5, 0.1
    truth = 1 - (1 - p) ** k
    e_unb = expectation(pass_at_k_comb, n, k, p)
    e_plug = expectation(plug_in, n, k, p)
    print(f"true pass@5         = {truth:.4f}")
    print(f"E[unbiased]         = {e_unb:.4f}")
    print(f"E[plug-in]          = {e_plug:.4f}   (bias {e_plug - truth:+.4f})")
    assert abs(e_unb - truth) < 1e-12 and abs(e_plug - 0.3485) < 1e-4 and abs(truth - 0.4095) < 1e-4

    print("\n== Simulation: 164 problems, per-problem p ~ Beta(0.3, 0.7), n = 20 samples each ==")
    rng = np.random.default_rng(2021)
    p_true = rng.beta(0.3, 0.7, size=164)
    n = 20
    c = rng.binomial(n, p_true)
    print(f"{'k':>3} {'true':>7} {'unbiased':>9} {'plug-in':>8} {'naive-k':>8}")
    rows = []
    for k in [1, 2, 3, 5, 10, 15, 20]:
        true_k = float(np.mean(1 - (1 - p_true) ** k))
        unb = float(np.mean([pass_at_k_prod(n, ci, k) for ci in c]))
        plg = float(np.mean([plug_in(n, ci, k) for ci in c]))
        # naive: draw exactly k samples per problem and count any success (unbiased but high variance)
        naive = float(np.mean(rng.binomial(k, p_true) > 0))
        rows.append((k, true_k, unb, plg))
        print(f"{k:>3} {true_k:>7.3f} {unb:>9.3f} {plg:>8.3f} {naive:>8.3f}")
    assert all(plg <= unb + 1e-12 for _, _, unb, plg in rows)   # plug-in never exceeds unbiased here

    print("\n== Variance: naive k-sample estimate vs unbiased from n=20, k=5, 2000 repeats, one problem p=0.2 ==")
    reps = 2000
    naive_est = (rng.binomial(5, 0.2, size=reps) > 0).astype(float)
    unb_est = np.array([pass_at_k_prod(20, ci, 5) for ci in rng.binomial(20, 0.2, size=reps)])
    print(f"truth {1 - 0.8 ** 5:.4f} | naive mean {naive_est.mean():.4f} sd {naive_est.std():.3f}"
          f" | unbiased mean {unb_est.mean():.4f} sd {unb_est.std():.3f}")
    assert unb_est.std() < naive_est.std()

    print("\n== pass@1 vs avg@n vs maj@k: 5 problems, greedy answer + 8 samples at T > 0 ==")
    met = reasoning_metrics(MOCK, k=4)
    for name, v in met.items():
        print(f"{name:<34} {v:.4f}")
    vals = list(met.values())
    assert [round(v, 4) for v in vals] == [0.6, 0.4, 0.6, 0.7686, 0.8, 0.1], vals
    # majority voting picks one answer, so it can never beat coverage on any problem
    assert all((majority(s) == gold) <= any(a == gold for a in s) for gold, _, s in MOCK)

    print("\n== Weak tests: a buggy mean() that crashes on [] ==")
    print(f"passes 3 base tests: {passes(buggy_mean, BASE_TESTS)}   passes base + edge case []: "
          f"{passes(buggy_mean, PLUS_TESTS)}")
    assert passes(buggy_mean, BASE_TESTS) and not passes(buggy_mean, PLUS_TESTS)

    print("\n== Best temperature depends on k: 15 problems, exact pass@k on a temperature grid ==")
    margins = np.linspace(-4, 3, 15)
    grid = np.round(np.arange(0.1, 1.51, 0.1), 1)
    table = {k: [float(np.mean(1 - (1 - p_at_temperature(T, margins)) ** k)) for T in grid] for k in (1, 20, 100)}
    print(f"{'T':<9}" + " ".join(f"{T:>5.1f}" for T in grid))      # all 15 grid points
    for k, row in table.items():
        print(f"{'pass@' + str(k):<9}" + " ".join(f"{v:>5.3f}" for v in row))
    best = {k: float(grid[int(np.argmax(row))]) for k, row in table.items()}
    print("best T (argmax over the full 0.1-step grid): " + ", ".join(f"pass@{k} -> {t:.1f}" for k, t in best.items()))
    assert best[1] < best[20] <= best[100], best
