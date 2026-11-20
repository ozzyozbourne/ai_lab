"""Over-refusal as an ROC curve (Chapter 8.6, #over-refusal).

XSTest-shaped mock data: 250 safe prompts (some with scary surface words, like "kill a
Python process") and 200 unsafe contrast prompts, all placeholders. Two mock models compute a
danger score and refuse when it exceeds a threshold t:
  * "keyword" model: score dominated by surface words (what over-refusing models do)
  * "semantic" model: score dominated by the (hidden) true intent
Sweeping t traces false-refusal rate on safe prompts (x) vs refusal rate on unsafe prompts (y).

Also reproduces the XSTest refusal_rate worked example: (20 full + 10 partial) / 250 = 12%.

Run:  python3 code/ch08/over_refusal_roc.py        (add --fig to print the Figure 8.4 points)
Key output: AUC keyword 0.810 vs semantic 0.985; at 95% unsafe refusal the keyword model
falsely refuses 142/250 safe prompts, the semantic model 16/250.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from _common import auc_mann_whitney  # noqa: E402


# Threshold grid used to draw Figure 8.4 (printed only with --fig).
FIG_THRESHOLDS = np.round(np.arange(-1.5, 4.5001, 0.1), 2)


def xstest_refusal_rate(n_full: int, n_partial: int, n: int) -> float:
    """inspect_evals xstest refusal_rate: (refusal + partial) / n * 100."""
    return (n_full + n_partial) / n * 100


def make_data(rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    n_safe, n_unsafe = 250, 200
    # surface "scariness" (e.g. homonyms, safe targets, historical events) and true intent
    surf_safe = np.concatenate([rng.normal(1.5, 0.6, 125), rng.normal(0.3, 0.5, 125)])
    surf_unsafe = rng.normal(1.3, 0.7, n_unsafe)
    intent_safe = rng.normal(0.0, 0.5, n_safe)
    intent_unsafe = rng.normal(2.0, 0.6, n_unsafe)
    surf = np.concatenate([surf_safe, surf_unsafe])
    intent = np.concatenate([intent_safe, intent_unsafe])
    label = np.concatenate([np.zeros(n_safe, int), np.ones(n_unsafe, int)])
    return surf, intent, label


def roc(scores: np.ndarray, label: np.ndarray, thresholds: np.ndarray) -> list[tuple[float, float, float]]:
    pts = []
    for t in thresholds:
        refuse = scores > t
        pts.append((float(t), float(refuse[label == 0].mean()), float(refuse[label == 1].mean())))
    return pts


def main() -> None:
    rr = xstest_refusal_rate(20, 10, 250)
    print(f"XSTest-style refusal_rate on safe prompts: (20 + 10) / 250 * 100 = {rr:.1f}%")
    assert abs(rr - 12.0) < 1e-9

    rng = np.random.default_rng(42)
    surf, intent, label = make_data(rng)
    noise = rng.normal(0, 0.3, label.size)
    models = {"keyword": 0.9 * surf + 0.3 * intent + noise,
              "semantic": 0.2 * surf + 1.0 * intent + noise}
    ths = np.linspace(-1.0, 4.0, 11)
    aucs = {}
    for name, s in models.items():
        aucs[name] = auc_mann_whitney(s[label == 1].tolist(), s[label == 0].tolist())
        print(f"\n{name} model: ROC AUC = {aucs[name]:.3f}")
        print(f"  {'threshold':>9}  {'false refusal (safe)':>20}  {'refusal (unsafe)':>16}")
        for t, fr, tr in roc(s, label, ths):
            print(f"  {t:9.1f}  {fr:20.3f}  {tr:16.3f}")

    print("\nOperating point: highest threshold that still refuses >= 95% of unsafe prompts")
    fine = np.linspace(-1.0, 4.0, 501)
    for name, s in models.items():
        pts = [p for p in roc(s, label, fine) if p[2] >= 0.95]
        t, fr, tr = pts[-1]
        print(f"  {name:<8}: t = {t:.2f}, unsafe refused = {tr:.3f}, safe falsely refused = {fr:.3f}"
              f" ({round(fr * 250)}/250)")
    assert aucs["semantic"] > aucs["keyword"] + 0.1

    if "--fig" in sys.argv:
        print("\nFigure 8.4 points (threshold, false refusal, unsafe refusal), thresholds -1.5..4.5 step 0.1")
        for name, s in models.items():
            pts = roc(s, label, FIG_THRESHOLDS)
            print(f"  {name}: " + " ".join(f"({t:.1f},{fr:.3f},{tr:.3f})" for t, fr, tr in pts))
            coords = [f"{80 + 400 * fr:.1f},{430 - 400 * tr:.1f}" for t, fr, tr in pts]
            svg = " ".join(c for i, c in enumerate(coords) if i == 0 or c != coords[i - 1])  # drop repeats
            print(f"  {name} SVG polyline: {svg}")


if __name__ == "__main__":
    main()
