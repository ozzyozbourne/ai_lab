"""pass@k vs pass^k in three numbers (sidebar in section 1.5).

Full derivations: Chapter 2 (pass@k) and Chapter 5 / 6 (pass^k).
pass@k  = 1 - C(n-c, k) / C(n, k)   unbiased estimator, Chen et al. 2021 (openai/human-eval)
pass^k  = C(c, k) / C(n, k)         unbiased estimator, Yao et al. 2024 (sierra-research/tau-bench)
Run:  python3 code/ch01/passk_preview.py
Expected key output: n=10, c=3 -> pass@3 = 0.708, pass^3 = 0.008; 0.75^3 = 0.422.
"""
from math import comb


def pass_at_k(n: int, c: int, k: int) -> float:
    """P(at least one of k samples passes), samples drawn without replacement from n."""
    if n - c < k:
        return 1.0
    return 1.0 - comb(n - c, k) / comb(n, k)


def pass_hat_k(n: int, c: int, k: int) -> float:
    """P(all k samples pass), drawn without replacement from n."""
    return comb(c, k) / comb(n, k)


if __name__ == "__main__":
    n, c = 10, 3
    print(f"one task, n={n} trials, c={c} passed (per-trial rate {c / n:.2f})")
    print(f"{'k':>3} {'pass@k':>8} {'pass^k':>8} {'naive (c/n)^k':>14}")
    for k in (1, 2, 3, 5, 10):
        print(f"{k:>3} {pass_at_k(n, c, k):>8.3f} {pass_hat_k(n, c, k):>8.4f} {(c / n) ** k:>14.4f}")
    print(f"\nAnthropic's example: 75% per-trial success, 3 trials all pass = {0.75 ** 3:.3f}")
    assert abs(pass_at_k(10, 3, 3) - 0.708) < 1e-3
    assert abs(pass_hat_k(10, 3, 3) - 0.00833) < 1e-4
    assert abs(0.75 ** 3 - 0.422) < 1e-3
