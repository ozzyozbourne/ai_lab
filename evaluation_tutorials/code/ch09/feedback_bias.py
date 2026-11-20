"""Thumbs feedback is sparse and self-selected: measure the bias, correct it with inverse-propensity weights.

Chapter 9, section 9.14 (User feedback signals). 100,000 simulated conversations from three user
segments (new, regular, power) whose satisfaction rates and feedback propensities differ.
  MAR case : the chance of giving feedback depends only on the (observed) segment -> IPW fixes it.
  MNAR case: within a segment, unhappy users are 3x more likely to click -> IPW by segment does not;
             a small random survey (everyone sampled is asked and answers) does.
IPW estimate = sum(w_i * thumbs_up_i) / sum(w_i) over feedback-givers, w_i = 1 / P(feedback | segment_i).
Run:  python3 code/ch09/feedback_bias.py
Expected key output: true satisfaction 0.685; MAR: raw thumbs-up 0.783, IPW 0.687;
MNAR: raw 0.535, IPW 0.445 (worse: the weights amplify the biased segment), random 1% survey 0.680.
"""
from __future__ import annotations

import numpy as np

SEGMENTS = {          # share, P(satisfied), P(feedback) for a satisfied user
    "new": (0.40, 0.55, 0.02),
    "regular": (0.50, 0.75, 0.05),
    "power": (0.10, 0.90, 0.20),
}


def simulate(n: int, unhappy_mult: float, rng):
    names = list(SEGMENTS)
    seg = rng.choice(len(names), size=n, p=[SEGMENTS[s][0] for s in names])
    p_sat = np.array([SEGMENTS[s][1] for s in names])[seg]
    sat = rng.random(n) < p_sat
    p_fb = np.array([SEGMENTS[s][2] for s in names])[seg] * np.where(sat, 1.0, unhappy_mult)
    gave = rng.random(n) < p_fb
    return seg, sat, gave


def ipw(seg, sat, gave) -> float:
    est_prop = np.array([gave[seg == k].mean() for k in range(len(SEGMENTS))])   # observed rate per segment
    w = 1.0 / est_prop[seg[gave]]
    return float((w * sat[gave]).sum() / w.sum())


if __name__ == "__main__":
    rng = np.random.default_rng(5)
    true_rate = sum(s * p for s, p, _ in SEGMENTS.values())
    print(f"true satisfaction rate (population) = {true_rate:.3f}")
    for label, mult in (("MAR  (propensity depends on segment only)", 1.0),
                        ("MNAR (unhappy users 3x likelier to click)", 3.0)):
        seg, sat, gave = simulate(100_000, mult, rng)
        raw = sat[gave].mean()
        corrected = ipw(seg, sat, gave)
        survey = rng.random(len(sat)) < 0.01                       # ask a random 1%, all answer
        print(f"\n{label}")
        print(f"  feedback rate {gave.mean():.3f} ({gave.sum()} of {len(gave)} conversations)")
        print(f"  realised satisfaction {sat.mean():.3f} | raw thumbs-up {raw:.3f} | IPW {corrected:.3f}"
              f" | random 1% survey {sat[survey].mean():.3f} (n={survey.sum()})")
        for k, name in enumerate(SEGMENTS):
            m = seg == k
            print(f"    {name:<8} share of feedback {gave[m].sum() / gave.sum():.2f} vs share of users {m.mean():.2f}")
        if mult == 1.0:
            assert abs(raw - 0.776) < 0.015 and abs(corrected - sat.mean()) < 0.015
        else:
            assert abs(corrected - sat.mean()) > 0.08 and abs(sat[survey].mean() - sat.mean()) < 0.03
    assert abs(true_rate - 0.685) < 1e-9
