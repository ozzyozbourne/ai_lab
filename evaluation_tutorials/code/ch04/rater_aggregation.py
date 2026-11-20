"""Turning several raters' labels into one: majority vote, attention checks, Dawid-Skene (Chapter 4.2, #human-eval).

400 items with a hidden binary truth (1 = PASS). Six crowd raters label every item: five honest raters with
accuracies 0.90 / 0.85 / 0.80 / 0.70 / 0.60 and one spammer who answers at random (accuracy 0.50).
5% of the items (20) are attention checks with known answers. We compare, against the hidden truth:

  (a) majority vote over all six raters;
  (b) majority vote after excluding raters who fail the pre-registered attention-check rule
      ("exclude a rater who gets fewer than 13 of the 20 checks right"; written down before labelling);
  (c) Dawid & Skene (1979) EM: estimate each rater's 2x2 confusion matrix and the class prior jointly,
      then label each item by its posterior. No attention checks are needed, but they can seed it.

Dawid, A. P. & Skene, A. M. (1979). Maximum Likelihood Estimation of Observer Error-Rates Using the
EM Algorithm. Journal of the Royal Statistical Society, Series C, 28(1), 20-28.

Run: python3 code/ch04/rater_aggregation.py
"""
from __future__ import annotations

import numpy as np

N_ITEMS, N_CHECKS, PASS_RATE = 400, 20, 0.65
ACCURACY = [0.90, 0.85, 0.80, 0.70, 0.60, 0.50]      # rater 6 is a random spammer
NAMES = ["r1", "r2", "r3", "r4", "r5", "spammer"]
CHECK_RULE = 13   # pre-registered: >= 13/20 checks correct. Aimed at spammers: a random rater passes with p = 0.13,
                  # a rater with accuracy 0.85 passes with p = 0.998


def simulate(rng) -> tuple[np.ndarray, np.ndarray]:
    truth = (rng.random(N_ITEMS) < PASS_RATE).astype(int)
    labels = np.empty((N_ITEMS, len(ACCURACY)), int)
    for r, acc in enumerate(ACCURACY):
        correct = rng.random(N_ITEMS) < acc
        labels[:, r] = np.where(correct, truth, 1 - truth)
    return truth, labels


def majority(labels: np.ndarray) -> np.ndarray:
    """Majority vote; ties (possible with an even number of raters) go to FAIL, the conservative label."""
    return (labels.mean(1) > 0.5).astype(int)


def dawid_skene(labels: np.ndarray, iters: int = 100, tol: float = 1e-8):
    """Binary Dawid-Skene EM. Returns P(true = 1 | labels) per item, the prior, and per-rater confusion
    matrices conf[r, true, given] = P(rater r says `given` | true class)."""
    n, R = labels.shape
    post = labels.mean(1)                                   # initialise with the soft majority vote
    for _ in range(iters):
        # M-step: class prior and each rater's confusion matrix (with a tiny pseudo-count)
        prior = post.mean()
        conf = np.empty((R, 2, 2))
        for r in range(R):
            for t, w in ((1, post), (0, 1 - post)):
                said1 = (w * labels[:, r]).sum() + 0.01
                conf[r, t, 1] = said1 / (w.sum() + 0.02)
                conf[r, t, 0] = 1 - conf[r, t, 1]
        # E-step: posterior of the true class given all raters' labels
        log1 = np.log(prior) + sum(np.log(conf[r, 1, labels[:, r]]) for r in range(R))
        log0 = np.log(1 - prior) + sum(np.log(conf[r, 0, labels[:, r]]) for r in range(R))
        new = 1 / (1 + np.exp(log0 - log1))
        if np.max(np.abs(new - post)) < tol:
            post = new
            break
        post = new
    return post, prior, conf


def main() -> None:
    rng = np.random.default_rng(42)
    truth, labels = simulate(rng)
    checks = np.arange(N_CHECKS)                            # the first 20 items are attention checks
    scored = np.arange(N_CHECKS, N_ITEMS)                   # report accuracy on the other 380
    check_correct = (labels[checks] == truth[checks][:, None]).sum(0)
    keep = check_correct >= CHECK_RULE

    print(f"{N_ITEMS} items ({N_CHECKS} attention checks), true PASS rate {truth.mean():.3f}; 6 raters label every item")
    print(f"{'rater':<9}{'true acc':>9}{'observed acc':>14}{'checks right':>14}{f'kept (>={CHECK_RULE}/{N_CHECKS})':>16}")
    for r in range(len(ACCURACY)):
        obs = (labels[scored, r] == truth[scored]).mean()
        print(f"{NAMES[r]:<9}{ACCURACY[r]:>9.2f}{obs:>14.3f}{check_correct[r]:>11d}/20{str(bool(keep[r])):>16}")

    mv_all = majority(labels[scored])
    mv_kept = majority(labels[scored][:, keep])
    post, prior, conf = dawid_skene(labels)
    ds = (post[scored] > 0.5).astype(int)
    acc = {k: (v == truth[scored]).mean() for k, v in
           (("(a) majority vote, all 6 raters", mv_all), ("(b) majority vote, raters passing checks", mv_kept),
            ("(c) Dawid-Skene EM, all 6 raters", ds), ("best single rater (r1)", labels[scored, 0]))}
    print(f"\nAccuracy against the hidden truth on the {len(scored)} non-check items")
    for k, v in acc.items():
        print(f"  {k:<44}{v:.3f}")

    print(f"\nDawid-Skene estimates: prior P(PASS) = {prior:.3f}; per-rater confusion matrices P(says | true)")
    print(f"{'rater':<9}{'P(PASS|PASS)':>14}{'P(FAIL|FAIL)':>14}{'est. accuracy':>15}{'weight log-odds':>17}")
    est_acc = prior * conf[:, 1, 1] + (1 - prior) * conf[:, 0, 0]
    for r in range(len(ACCURACY)):
        # the evidence one PASS vote adds, log P(PASS|PASS)/P(PASS|FAIL); ~0 means the rater carries no information
        w = np.log(conf[r, 1, 1] / conf[r, 0, 1])
        print(f"{NAMES[r]:<9}{conf[r, 1, 1]:>14.3f}{conf[r, 0, 0]:>14.3f}{est_acc[r]:>15.3f}{w:>17.2f}")

    assert not keep[5] and keep[:5].all(), "the spammer fails the attention-check rule; honest raters pass"
    assert abs(np.log(conf[5, 1, 1] / conf[5, 0, 1])) < 0.3, "Dawid-Skene gives the spammer ~zero weight"
    observed = (labels == truth[:, None]).mean(0)
    assert np.all(np.abs(est_acc - observed) < 0.03), "estimated rater accuracies match the realised ones"
    assert acc["(c) Dawid-Skene EM, all 6 raters"] > acc["(a) majority vote, all 6 raters"] + 0.02
    assert acc["(b) majority vote, raters passing checks"] > acc["(a) majority vote, all 6 raters"]
    assert acc["(c) Dawid-Skene EM, all 6 raters"] >= acc["(b) majority vote, raters passing checks"]


if __name__ == "__main__":
    main()
