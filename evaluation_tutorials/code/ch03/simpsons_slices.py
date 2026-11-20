"""Slices and reporting: Simpson's paradox when two systems are scored on different slice mixes,
and the fix (same items, or direct standardisation to the production mix).

Chapter 3, section 3.8 (#slices).
Run:  python3 code/ch03/simpsons_slices.py
Expected key output: X wins both slices (95% vs 90%, 30% vs 25%) yet loses pooled (51.7% vs 68.3%);
standardised to a 70/30 production mix X = 75.5%, Y = 70.5%.
"""
from __future__ import annotations

# (passes, items) per slice; X was run mostly on the hard slice, Y mostly on the easy one
RESULTS = {"X": {"easy": (95, 100), "hard": (60, 200)},
           "Y": {"easy": (180, 200), "hard": (25, 100)}}
PROD_MIX = {"easy": 0.7, "hard": 0.3}


def rate(k: int, n: int) -> float:
    return k / n


def pooled(r: dict[str, tuple[int, int]]) -> float:
    return sum(k for k, _ in r.values()) / sum(n for _, n in r.values())


def standardised(r: dict[str, tuple[int, int]], w: dict[str, float]) -> float:
    return sum(w[s] * rate(*r[s]) for s in w)


if __name__ == "__main__":
    print(f"{'system':<8}{'easy':>14}{'hard':>14}{'pooled':>9}{'standardised 70/30':>21}")
    out = {}
    for m, r in RESULTS.items():
        e, h = rate(*r["easy"]), rate(*r["hard"])
        out[m] = (e, h, pooled(r), standardised(r, PROD_MIX))
        print(f"{m:<8}{e:7.1%} ({r['easy'][1]:3d}){h:7.1%} ({r['hard'][1]:3d}){out[m][2]:9.1%}{out[m][3]:21.1%}")
    X, Y = out["X"], out["Y"]
    assert X[0] > Y[0] and X[1] > Y[1]           # X wins every slice
    assert X[2] < Y[2]                           # ...and loses the pooled number
    assert X[3] > Y[3]                           # standardisation restores the right order
    assert abs(X[2] - 155 / 300) < 1e-12 and abs(Y[2] - 205 / 300) < 1e-12
    assert abs(X[3] - 0.755) < 1e-12 and abs(Y[3] - 0.705) < 1e-12
    print("\nX wins every slice but loses the pooled score: Simpson's paradox. all checks passed")
