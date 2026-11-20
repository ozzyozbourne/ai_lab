"""Shared helpers for Chapter 8 (not run directly by code/run_all.py).

Wilson intervals, Cohen's kappa, McNemar's exact test, two-proportion z-test,
Mann-Whitney AUC and a tiny table printer. Standard library only.
"""
from __future__ import annotations

import math
from typing import Sequence


def wilson(k: int, n: int, z: float = 1.959964) -> tuple[float, float]:
    """Wilson score interval for a binomial proportion k/n."""
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))


def cohen_kappa(a: Sequence[int], b: Sequence[int]) -> float:
    """Cohen's kappa for two binary label sequences."""
    n = len(a)
    po = sum(x == y for x, y in zip(a, b)) / n
    pa, pb = sum(a) / n, sum(b) / n
    pe = pa * pb + (1 - pa) * (1 - pb)
    return (po - pe) / (1 - pe) if pe < 1 else 1.0


def mcnemar_exact(b: int, c: int) -> float:
    """Two-sided exact McNemar p-value from the discordant counts b and c."""
    n, m = b + c, min(b, c)
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(m + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def two_prop_z(k1: int, n1: int, k2: int, n2: int) -> tuple[float, float]:
    """Unpaired two-proportion z-test (pooled). Returns (z, two-sided p)."""
    p = (k1 + k2) / (n1 + n2)
    se = math.sqrt(p * (1 - p) * (1 / n1 + 1 / n2))
    z = (k2 / n2 - k1 / n1) / se
    return z, math.erfc(abs(z) / math.sqrt(2))


def auc_mann_whitney(pos: Sequence[float], neg: Sequence[float]) -> float:
    """AUC = P(score_pos > score_neg) + 0.5 P(tie), computed via ranks (Mann-Whitney U)."""
    allv = sorted([(v, 1) for v in pos] + [(v, 0) for v in neg])
    ranks = [0.0] * len(allv)
    i = 0
    while i < len(allv):
        j = i
        while j + 1 < len(allv) and allv[j + 1][0] == allv[i][0]:
            j += 1
        for t in range(i, j + 1):
            ranks[t] = (i + j) / 2 + 1  # average rank, 1-based
        i = j + 1
    r_pos = sum(r for r, (_, lab) in zip(ranks, allv) if lab == 1)
    n1, n0 = len(pos), len(neg)
    u = r_pos - n1 * (n1 + 1) / 2
    return u / (n1 * n0)


def table(rows: list[Sequence[object]], header: Sequence[str]) -> str:
    """Render rows as an aligned plain-text table."""
    cells = [[str(h) for h in header]] + [[str(c) for c in r] for r in rows]
    widths = [max(len(r[i]) for r in cells) for i in range(len(header))]
    lines = ["  ".join(c.ljust(w) for c, w in zip(r, widths)) for r in cells]
    lines.insert(1, "  ".join("-" * w for w in widths))
    return "\n".join(lines)
