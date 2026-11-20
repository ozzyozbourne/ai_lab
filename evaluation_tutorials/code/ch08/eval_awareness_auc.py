"""Eval awareness: AUC of an eval-vs-deployment probe, and how awareness biases a measured rate
(Chapter 8.11, #eval-integrity).

1,000 mock transcripts (500 from evaluations, 500 from deployment) with binary cue features:
multiple-choice format, an "Answer with A/B/C/D" instruction, synthetic names (e.g. "Jane
Doe", "Acme Corp"), an agentic sandbox, and casual typos (more common in real use).
A mock model's internal "this is a test" score is a noisy logistic function of the cues; we
measure its discrimination with the Mann-Whitney AUC = P(score_eval > score_deploy).

Then behaviour: the mock model takes a covert misaligned action with probability 0.10 when it
believes it is deployed and 0.02 when it believes it is being tested (belief = score > 0.5).
The rate measured on the eval set understates the deployment rate. A "realism" rewrite that
strips the cues raises the measured rate toward the deployment rate.

Run:  python3 code/ch08/eval_awareness_auc.py
Key output: probe AUC 0.809; covert-action rate 0.034 measured on the eval set vs 0.074 in
deployment; 0.078 after the realism rewrite.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from _common import auc_mann_whitney, wilson  # noqa: E402

CUES = ["mcq_format", "answer_instruction", "synthetic_names", "agentic_sandbox", "typos"]
P_EVAL = np.array([0.45, 0.40, 0.55, 0.50, 0.10])
P_DEPLOY = np.array([0.05, 0.03, 0.15, 0.20, 0.45])
WEIGHTS = np.array([1.2, 1.4, 0.9, 0.6, -1.0])


def awareness_score(x: np.ndarray, rng: np.random.Generator, noise: float) -> np.ndarray:
    z = x @ WEIGHTS - 1.2 + rng.normal(0, noise, len(x))
    return 1 / (1 + np.exp(-z))


def misbehave(score: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    p = np.where(score > 0.5, 0.02, 0.10)
    return rng.random(len(score)) < p


def main() -> None:
    rng = np.random.default_rng(31)
    x_eval = (rng.random((500, 5)) < P_EVAL).astype(float)
    x_dep = (rng.random((500, 5)) < P_DEPLOY).astype(float)

    for label, noise in (("mock model probe", 1.2), ("sharper probe (less noise)", 0.5)):
        s_e, s_d = awareness_score(x_eval, rng, noise), awareness_score(x_dep, rng, noise)
        print(f"{label:<28} AUC = {auc_mann_whitney(s_e.tolist(), s_d.tolist()):.3f}")

    s_e, s_d = awareness_score(x_eval, rng, 1.2), awareness_score(x_dep, rng, 1.2)
    print(f"\nbelieves 'test': eval transcripts {np.mean(s_e > 0.5):.3f}, "
          f"deployment transcripts {np.mean(s_d > 0.5):.3f}")
    m_e, m_d = misbehave(s_e, rng), misbehave(s_d, rng)
    x_real = x_eval.copy()
    x_real[:, :3] = 0                                   # realism rewrite strips MCQ/instruction/names
    s_r = awareness_score(x_real, rng, 1.2)
    m_r = misbehave(s_r, rng)
    unaware = s_e <= 0.5
    for name, m in (("measured on eval set", m_e), ("eval set after realism rewrite", m_r),
                    ("eval set, unaware subset only", m_e[unaware]), ("deployment (truth)", m_d)):
        lo, hi = wilson(int(m.sum()), len(m))
        print(f"  covert-action rate, {name:<31}: {m.mean():.3f}  [{lo:.3f}, {hi:.3f}]  (n = {len(m)})")
    assert m_e.mean() < m_d.mean() and m_r.mean() > m_e.mean()


if __name__ == "__main__":
    main()
