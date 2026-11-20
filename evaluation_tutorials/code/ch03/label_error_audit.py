"""Label-error audit: flag gold labels that several models confidently contradict, then re-rank.

Chapter 3, section 3.5 (#label-audit). Idea after Northcutt et al. (2021) confident learning.
Run:  python3 code/ch03/label_error_audit.py
Expected key output: 5% of 2,000 four-way MC gold labels are flipped; the consensus flag has high
precision; after human review fixes the flagged items, models A and B swap places.
"""
from __future__ import annotations

import numpy as np

SEED = 11
N, K, FLIP = 2000, 4, 0.05


def mock_model(rng, true_y, acc, copy_errors_of=None, copy_rate=0.0, gold=None):
    """Returns (predicted label, confidence). Correct with prob `acc`; when wrong, picks another
    option. `copy_errors_of`: indices of mislabelled items this model has memorised the wrong
    gold label for (as if it had been fine-tuned on the same noisy source)."""
    pred = true_y.copy()
    wrong = rng.random(N) > acc
    pred[wrong] = (true_y[wrong] + rng.integers(1, K, wrong.sum())) % K
    conf = np.where(wrong, rng.uniform(0.3, 0.75, N), rng.uniform(0.6, 0.99, N))
    if copy_errors_of is not None:
        copy = copy_errors_of[rng.random(len(copy_errors_of)) < copy_rate]
        pred[copy], conf[copy] = gold[copy], 0.95
    return pred, conf


def flag(gold, preds, confs, thr=0.6):
    """Flag items where every auditor predicts the same non-gold label with confidence >= thr."""
    P, C = np.stack(preds), np.stack(confs)
    same = (P == P[0]).all(axis=0)
    return np.flatnonzero(same & (P[0] != gold) & (C.min(axis=0) >= thr))


if __name__ == "__main__":
    rng = np.random.default_rng(SEED)
    true_y = rng.integers(0, K, N)
    gold = true_y.copy()
    flipped = np.flatnonzero(rng.random(N) < FLIP)
    gold[flipped] = (true_y[flipped] + rng.integers(1, K, len(flipped))) % K
    print(f"{N} items, {len(flipped)} gold labels wrong ({len(flipped) / N:.1%})")

    # Two systems we want to compare, plus a third model used only as an auditor.
    pA, cA = mock_model(rng, true_y, 0.86)
    pB, cB = mock_model(rng, true_y, 0.84, copy_errors_of=flipped, copy_rate=0.6, gold=gold)
    pC, cC = mock_model(rng, true_y, 0.80)

    def acc(p, y):
        return float((p == y).mean())

    print(f"\n{'model':<8}{'vs noisy gold':>15}{'vs true labels':>16}")
    for name, p in (("A", pA), ("B", pB), ("C", pC)):
        print(f"{name:<8}{acc(p, gold):15.4f}{acc(p, true_y):16.4f}")

    flags = flag(gold, [pA, pB, pC], [cA, cB, cC])
    hit = np.isin(flags, flipped)
    print(f"\nflagged by all-3 consensus: {len(flags)} items; precision {hit.mean():.2f}; "
          f"recall {hit.sum() / len(flipped):.2f}")
    # Auditing models A and C only (B is a contestant, so it should not vote on its own labels).
    flags2 = flag(gold, [pA, pC], [cA, cC])
    hit2 = np.isin(flags2, flipped)
    print(f"flagged by A+C (contestant excluded): {len(flags2)} items; precision {hit2.mean():.2f}; "
          f"recall {hit2.sum() / len(flipped):.2f}")

    # Human review: a reviewer looks at the flagged items and restores the true label when gold is wrong.
    corrected = gold.copy()
    corrected[flags2] = true_y[flags2]
    print(f"\n{'model':<8}{'noisy gold':>12}{'corrected':>12}{'true':>10}")
    for name, p in (("A", pA), ("B", pB)):
        print(f"{name:<8}{acc(p, gold):12.4f}{acc(p, corrected):12.4f}{acc(p, true_y):10.4f}")

    rank_noisy = "A" if acc(pA, gold) > acc(pB, gold) else "B"
    rank_fixed = "A" if acc(pA, corrected) > acc(pB, corrected) else "B"
    print(f"\nleader on noisy gold: {rank_noisy}; leader after correction: {rank_fixed}")
    assert 0.04 < len(flipped) / N < 0.06
    assert hit2.mean() > 0.9
    assert rank_noisy == "B" and rank_fixed == "A"   # the ranking flips
    print("all checks passed")
