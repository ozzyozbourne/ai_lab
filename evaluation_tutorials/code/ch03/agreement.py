"""Inter-annotator agreement: Cohen's kappa (worked 0.66), Fleiss' kappa, and an adjudication queue.

Chapter 3, section 3.5 (#labelling), Figure 3.2.
Run:  python3 code/ch03/agreement.py
Expected key output: p_o = 0.85, p_e = 0.56, kappa = 0.659; a calibration round with three
mock raters where Fleiss' kappa rises after the guide is revised; the disputed items listed.
"""
from __future__ import annotations

import random
from collections import Counter

LABELS = ("Pass", "Fail")


def confusion(a: list[str], b: list[str]) -> dict[tuple[str, str], int]:
    return Counter(zip(a, b))


def cohen_kappa(a: list[str], b: list[str]) -> tuple[float, float, float]:
    n = len(a)
    p_o = sum(x == y for x, y in zip(a, b)) / n
    ca, cb = Counter(a), Counter(b)
    p_e = sum((ca[k] / n) * (cb[k] / n) for k in set(a) | set(b))
    return p_o, p_e, (p_o - p_e) / (1 - p_e)


def fleiss_kappa(table: list[list[int]]) -> float:
    """table[i][k] = number of raters who put item i in category k (same rater count per item)."""
    N, r = len(table), sum(table[0])
    p_k = [sum(row[k] for row in table) / (N * r) for k in range(len(table[0]))]
    P_i = [(sum(c * c for c in row) - r) / (r * (r - 1)) for row in table]
    P_bar, P_e = sum(P_i) / N, sum(p * p for p in p_k)
    return (P_bar - P_e) / (1 - P_e)


def mock_raters(rng: random.Random, truth: list[int], ambiguous: set[int], noise_amb: float,
                n_raters: int = 3, noise: float = 0.05) -> list[list[int]]:
    """Each rater flips the true label with prob `noise`, or `noise_amb` on ambiguous items."""
    out = []
    for _ in range(n_raters):
        out.append([1 - t if rng.random() < (noise_amb if i in ambiguous else noise) else t
                    for i, t in enumerate(truth)])
    return out


def to_table(ratings: list[list[int]]) -> list[list[int]]:
    return [[sum(r[i] == k for r in ratings) for k in (0, 1)] for i in range(len(ratings[0]))]


if __name__ == "__main__":
    # Worked example (dossier 03): A says Pass 70 times, B 65 times; they agree on 85 of 100.
    a = ["Pass"] * 60 + ["Pass"] * 10 + ["Fail"] * 5 + ["Fail"] * 25
    b = ["Pass"] * 60 + ["Fail"] * 10 + ["Pass"] * 5 + ["Fail"] * 25
    cm = confusion(a, b)
    print("confusion table (rows = rater A, columns = rater B)")
    print(f"{'':>8}{'B:Pass':>8}{'B:Fail':>8}")
    for la in LABELS:
        print(f"{'A:' + la:>8}{cm[(la, 'Pass')]:>8}{cm[(la, 'Fail')]:>8}")
    p_o, p_e, k = cohen_kappa(a, b)
    print(f"p_o = {p_o:.2f}  p_e = {p_e:.3f}  Cohen's kappa = {k:.3f}")
    assert abs(p_o - 0.85) < 1e-12 and abs(p_e - 0.56) < 1e-12 and abs(k - 0.659) < 1e-3

    # Same p_o, different prevalence: kappa punishes agreement that chance alone would produce.
    a2 = ["Pass"] * 84 + ["Pass"] * 8 + ["Fail"] * 7 + ["Fail"] * 1
    b2 = ["Pass"] * 84 + ["Fail"] * 8 + ["Pass"] * 7 + ["Fail"] * 1
    p_o2, p_e2, k2 = cohen_kappa(a2, b2)
    print(f"skewed labels: p_o = {p_o2:.2f}  p_e = {p_e2:.3f}  kappa = {k2:.3f}  (same p_o, kappa collapses)")
    assert abs(p_o2 - 0.85) < 1e-12 and k2 < 0.1

    # Calibration rounds: 60 items, 3 raters; 15 items are ambiguous under guide v1.
    rng = random.Random(3)
    truth = [int(rng.random() < 0.35) for _ in range(60)]   # 1 = Fail
    ambiguous = set(rng.sample(range(60), 15))
    rounds = {"guide v1 (no edge cases)": 0.45, "guide v2 (+edge cases, examples)": 0.12}
    print(f"\n{'calibration round':<34}{'Fleiss kappa':>13}{'pairwise Cohen (mean)':>23}{'disputed':>10}")
    results = {}
    for name, amb_noise in rounds.items():
        R = mock_raters(rng, truth, ambiguous, amb_noise)
        fk = fleiss_kappa(to_table(R))
        pair = [cohen_kappa(R[i], R[j])[2] for i in range(3) for j in range(i + 1, 3)]
        disputed = [i for i in range(60) if len({r[i] for r in R}) > 1]
        results[name] = (fk, disputed)
        print(f"{name:<34}{fk:13.3f}{sum(pair) / 3:23.3f}{len(disputed):10d}")
    (fk1, d1), (fk2, d2) = results.values()
    assert fk2 > fk1 + 0.2 and fk2 > 0.6
    amb_share = sum(i in ambiguous for i in d1) / len(d1)
    print(f"\nadjudication queue after v1: {len(d1)} items, {amb_share:.0%} of them from the ambiguous set")
    print("first disputed ids after v2:", d2[:10])
    print("\nall checks passed")
