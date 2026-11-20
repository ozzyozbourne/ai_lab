"""Twin benchmarks and a simplified ConStat: is a model's benchmark score higher than its twin-set
score predicts, relative to reference models?

Chapter 3, section 3.12 (#prevention). After Zhang et al. 2024 (GSM1k) and Dekoninck et al. 2024
(ConStat: delta = acc_primary(M) - f(acc_reference(M)), with f fitted on reference models).
Run:  python3 code/ch03/twin_gap_constat.py
Expected key output: the worked twin gap (8 points, SE 0.0174, z ~ 4.6); the naive two-proportion
z-test flags every model because the twin set is a bit harder; the ConStat-style test flags only
the model whose primary score is inflated.
"""
from __future__ import annotations

import math

import numpy as np

SEED, N_A, N_B = 8, 1319, 1000            # GSM8K test size and a GSM1k-sized twin


def two_prop_z(pa: float, na: int, pb: float, nb: int) -> tuple[float, float]:
    se = math.sqrt(pa * (1 - pa) / na + pb * (1 - pb) / nb)
    return (pa - pb) / se, se


def p_one_sided(z: float) -> float:
    return 0.5 * math.erfc(z / math.sqrt(2))


def true_primary_from_twin(b: np.ndarray) -> np.ndarray:
    """For clean models the twin is ~3-4 points harder, a little more so for weak models."""
    return np.clip(b + 0.035 + 0.03 * (0.7 - b), 0, 1)


if __name__ == "__main__":
    z, se = two_prop_z(0.82, N_A, 0.74, N_B)
    print(f"worked twin gap: 82% vs 74% -> gap 8 points, SE {se:.4f}, z = {z:.2f}")
    assert abs(se - 0.0174) < 1e-4 and abs(z - 4.6) < 0.05

    rng = np.random.default_rng(SEED)
    b_true = np.linspace(0.40, 0.88, 10)                       # 10 reference models on the twin
    a_true = true_primary_from_twin(b_true)
    a_obs = rng.binomial(N_A, a_true) / N_A                    # finite-sample noise on both sets
    b_obs = rng.binomial(N_B, b_true) / N_B
    slope, intercept = np.polyfit(b_obs, a_obs, 1)            # f: twin accuracy -> expected primary
    resid = a_obs - (slope * b_obs + intercept)
    s_resid = float(np.std(resid, ddof=2))
    print(f"\nf(b) = {slope:.3f} * b + {intercept:+.3f}, residual SD over 10 reference models {s_resid:.4f}")

    suspects = {"clean newcomer": (0.778, 0.74), "inflated (memorised)": (0.86, 0.74)}
    print(f"\n{'model':<24}{'A':>6}{'B':>6}{'naive z':>9}{'naive p':>10}{'delta':>8}{'ConStat z':>11}{'p':>9}")
    out = {}
    rows = [(f"ref-{i}", a, b) for i, (a, b) in enumerate(zip(a_obs, b_obs))]
    for name, (a_t, b_t) in suspects.items():
        rows.append((name, rng.binomial(N_A, a_t) / N_A, rng.binomial(N_B, b_t) / N_B))
    for name, a, b in rows:
        zn, _ = two_prop_z(a, N_A, b, N_B)
        delta = a - (slope * b + intercept)
        se_d = math.sqrt(s_resid**2 + a * (1 - a) / N_A + slope**2 * b * (1 - b) / N_B)
        zc = delta / se_d
        out[name] = (p_one_sided(zn), p_one_sided(zc))
        if name.startswith("ref-") and name not in ("ref-0", "ref-5", "ref-9"):
            continue                                             # print a few reference rows only
        print(f"{name:<24}{a:6.3f}{b:6.3f}{zn:9.2f}{p_one_sided(zn):10.4f}{delta:+8.3f}{zc:11.2f}{p_one_sided(zc):9.4f}")

    n_ref_naive = sum(out[f"ref-{i}"][0] < 0.05 for i in range(10))
    n_ref_constat = sum(out[f"ref-{i}"][1] < 0.05 for i in range(10))
    print(f"\nreference models flagged at p < 0.05: naive {n_ref_naive}/10, ConStat-style {n_ref_constat}/10")
    assert n_ref_naive >= 5 and n_ref_constat == 0
    assert out["clean newcomer"][1] > 0.05
    assert out["inflated (memorised)"][1] < 0.01
    print("all checks passed")
