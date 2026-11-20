"""Why raw agreement is a bad way to validate a judge: the always-PASS judge.

Chapter 1, section 1.4 (Graders). Full treatment of judge validation is in Chapter 4.
Run:  python3 code/ch01/judge_always_pass.py
Expected key output: always-PASS judge on a 95/5 set -> agreement 0.950, kappa 0.000,
TPR(fail) 0.000; realistic judge -> agreement 0.895, kappa 0.388, TPR(fail) 0.800;
with only 10 human FAILs the realistic judge's 95% Wilson CIs are wide:
TPR [0.490, 0.943] (8/10), TNR [0.849, 0.935] (171/190);
dossier example (100 items, 20 fails) -> kappa 0.571.

Convention: the FAIL class is the positive class, because catching failures is the judge's job.
  TPR = share of human-labelled FAILs the judge also calls FAIL (recall on failures)
  TNR = share of human-labelled PASSes the judge also calls PASS
"""
from __future__ import annotations

import random
from dataclasses import dataclass

from wilson_defects import wilson_ci     # same directory; Python puts the script's folder on sys.path


@dataclass
class Agreement:
    n: int
    raw: float
    kappa: float
    tpr: float
    tnr: float
    precision_fail: float


def confusion(human: list[str], judge: list[str]) -> tuple[int, int, int, int]:
    tp = sum(h == "FAIL" and j == "FAIL" for h, j in zip(human, judge))
    fn = sum(h == "FAIL" and j == "PASS" for h, j in zip(human, judge))
    fp = sum(h == "PASS" and j == "FAIL" for h, j in zip(human, judge))
    tn = sum(h == "PASS" and j == "PASS" for h, j in zip(human, judge))
    return tp, fn, fp, tn


def agreement(human: list[str], judge: list[str]) -> Agreement:
    tp, fn, fp, tn = confusion(human, judge)
    n = tp + fn + fp + tn
    p_o = (tp + tn) / n
    # chance agreement: both say FAIL by chance + both say PASS by chance
    p_e = ((tp + fn) / n) * ((tp + fp) / n) + ((fp + tn) / n) * ((fn + tn) / n)
    kappa = 0.0 if p_e == 1 else (p_o - p_e) / (1 - p_e)
    tpr = tp / (tp + fn) if tp + fn else float("nan")
    tnr = tn / (tn + fp) if tn + fp else float("nan")
    prec = tp / (tp + fp) if tp + fp else float("nan")
    return Agreement(n, p_o, kappa, tpr, tnr, prec)


def labelled_set(n_pass: int, n_fail: int, seed: int) -> list[str]:
    labels = ["PASS"] * n_pass + ["FAIL"] * n_fail
    random.Random(seed).shuffle(labels)
    return labels


def judge_with_rates(human: list[str], catch_fails: int, false_alarms: int, seed: int) -> list[str]:
    """A judge that flags exactly `catch_fails` of the true fails and `false_alarms` true passes."""
    rng = random.Random(seed)
    fail_idx = [i for i, h in enumerate(human) if h == "FAIL"]
    pass_idx = [i for i, h in enumerate(human) if h == "PASS"]
    flagged = set(rng.sample(fail_idx, catch_fails)) | set(rng.sample(pass_idx, false_alarms))
    return ["FAIL" if i in flagged else "PASS" for i in range(len(human))]


def report(name: str, a: Agreement) -> None:
    print(f"{name:<28} {a.n:>4} {a.raw:>9.3f} {a.kappa:>7.3f} {a.tpr:>9.3f} {a.tnr:>7.3f} {a.precision_fail:>10.3f}")


if __name__ == "__main__":
    human = labelled_set(n_pass=190, n_fail=10, seed=1)          # 95% PASS / 5% FAIL
    always_pass = ["PASS"] * len(human)
    realistic = judge_with_rates(human, catch_fails=8, false_alarms=19, seed=2)
    print(f"{'judge':<28} {'n':>4} {'agreement':>9} {'kappa':>7} {'TPR(fail)':>9} {'TNR':>7} {'prec(fail)':>10}")
    a0 = agreement(human, always_pass)
    a1 = agreement(human, realistic)
    report("always-PASS (95/5 set)", a0)
    report("realistic (95/5 set)", a1)
    # dossier 01 worked example: 100 items, 20 human fails; TP=15 FN=5 FP=10 TN=70
    human2 = labelled_set(n_pass=80, n_fail=20, seed=3)
    judge2 = judge_with_rates(human2, catch_fails=15, false_alarms=10, seed=4)
    a2 = agreement(human2, judge2)
    report("worked example (80/20 set)", a2)
    tp, fn, fp, tn = confusion(human, realistic)
    tpr_ci, tnr_ci = wilson_ci(a1.tpr, tp + fn), wilson_ci(a1.tnr, tn + fp)
    print(f"\nrealistic judge, 95% Wilson CIs: TPR {tp}/{tp + fn} -> [{tpr_ci[0]:.3f}, {tpr_ci[1]:.3f}],"
          f" TNR {tn}/{tn + fp} -> [{tnr_ci[0]:.3f}, {tnr_ci[1]:.3f}]")
    print("With 10 FAILs the TPR interval runs from about 0.49 to 0.94: validate on 50-100+ FAILs.")
    print("\nThe always-PASS judge has the HIGHEST raw agreement and is useless: it never catches a failure.")

    assert abs(a0.raw - 0.95) < 1e-9 and a0.kappa == 0.0 and a0.tpr == 0.0 and a0.tnr == 1.0
    assert abs(a1.raw - 0.895) < 1e-9 and abs(a1.kappa - 0.388) < 1e-3 and abs(a1.tpr - 0.8) < 1e-9
    assert abs(a2.raw - 0.85) < 1e-9 and abs(a2.kappa - 0.571) < 1e-3
    assert abs(tpr_ci[0] - 0.490) < 1e-3 and abs(tpr_ci[1] - 0.943) < 1e-3
    assert abs(tnr_ci[0] - 0.849) < 1e-3 and abs(tnr_ci[1] - 0.935) < 1e-3
    assert abs(a2.tpr - 0.75) < 1e-9 and abs(a2.tnr - 0.875) < 1e-9
