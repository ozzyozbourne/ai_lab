"""Section 10.6: validate the mock LLM tone judge against human labels, then use it online with PPI.

1. 150 human-labelled agent replies (balanced PASS/FAIL), split train 20 / dev 65 / test 65.
   A second annotator labels 50 of them: human-human kappa is the ceiling for the judge.
2. Judge v1 (first prompt) vs v2 (after reading dev errors): TPR/TNR/kappa on dev, then the chosen
   judge once on test with bootstrap CIs. Positive class = FAIL (bad tone), the thing to catch.
3. Swap test: a pairwise judge asked both orders, to measure position bias.
4. Online: estimate the production tone pass rate from 2,000 judged replies + 200 human labels with
   prediction-powered inference (PPI), and check CI coverage over 500 repeated samples.

Run:  python3 code/ch10/validate_judge.py      (under 1 s)
"""
import pathlib
import random
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from evalsuite.agents import CORE, render                                  # noqa: E402
from evalsuite.graders import pairwise_tone_judge, tone_judge                # noqa: E402
from evalsuite.stats import bootstrap_ci, cohen_kappa, mean_se, ppi_mean_ci, tpr_tnr, wilson, Z95  # noqa: E402

KINDS = [k for k in CORE if k != "ask_identity"]
NOISE = 0.04            # annotators disagree with the rubric on ~4% of items


def reply(rng, polite):
    kind = rng.choice(KINDS)
    kw = dict(amount=rng.uniform(10, 90), oid=f"O-{rng.randint(1000, 9999)}", item="kite",
              name="Sam Lee", status="shipped")
    return render(kind, polite, rng, **kw)


def human(rng, polite):
    """Human label: True = FAIL (bad tone). Rubric says curt -> FAIL; a few labels disagree."""
    fail = not polite
    return (not fail) if rng.random() < NOISE else fail


def metrics(y, yhat):
    tpr, tnr = tpr_tnr(y, yhat)
    return tpr, tnr, cohen_kappa(y, yhat)


def main():
    rng = random.Random(4)
    polite = [i % 2 == 0 for i in range(150)]
    rng.shuffle(polite)
    texts = [reply(rng, p) for p in polite]
    y = np.array([human(rng, p) for p in polite])
    y2 = np.array([human(rng, p) for p in polite[:50]])
    tr, dev, te = slice(0, 20), slice(20, 85), slice(85, 150)
    print(f"150 labelled replies: {int(y.sum())} FAIL / {int((~y).sum())} PASS; train 20, dev 65, test 65")
    print(f"human-human agreement on 50 double-labelled items: kappa = {cohen_kappa(y[:50], y2):.2f}\n")

    print(f"{'judge':<10}{'split':<6}{'TPR(FAIL)':>10}{'TNR(PASS)':>10}{'kappa':>7}")
    for v in ("v1", "v2"):
        yhat = np.array([tone_judge(t, v) == "FAIL" for t in texts])
        print(f"{v:<10}{'dev':<6}" + "".join(f"{m:>10.2f}" if i < 2 else f"{m:>7.2f}"
                                           for i, m in enumerate(metrics(y[dev], yhat[dev]))))
    dev_errors = [t for t, a, b in zip(texts[dev], y[dev], [tone_judge(t, "v1") == "FAIL" for t in texts[dev]]) if a != b]
    print(f"  e.g. a v1 dev error: {dev_errors[0]!r}")

    yhat = np.array([tone_judge(t, "v2") == "FAIL" for t in texts])
    yt, ht = y[te], yhat[te]
    tpr, tnr, kap = metrics(yt, ht)
    cis = [bootstrap_ci(lambda idx, j=j: metrics(yt[idx], ht[idx])[j], len(yt), B=2000, seed=j) for j in range(3)]
    print(f"\njudge v2 on the held-out test split (n={len(yt)}), 95% bootstrap CIs:")
    for name, val, ci in zip(("TPR", "TNR", "kappa"), (tpr, tnr, kap), cis):
        print(f"  {name:<6}{val:.2f}  [{ci[0]:.2f}, {ci[1]:.2f}]")
    npass, nfail = int((~yt).sum()), int(yt.sum())
    w = wilson(round(tnr * npass), npass)
    print(f"  (the bootstrap CI collapses at 1.00; Wilson for TNR = {round(tnr * npass)}/{npass}: [{w[0]:.2f}, {w[1]:.2f}];"
          f" test has {nfail} FAIL items)")
    misses = sorted({t.split()[0] + " ... " + " ".join(t.split()[-3:]) for t, a, b in zip(texts[te], yt, ht) if a and not b})
    print(f"  FAILs the judge still misses (pattern): {misses[:2]}")

    prng = random.Random(9)
    pairs = [(reply(prng, prng.random() < 0.5), reply(prng, prng.random() < 0.5)) for _ in range(200)]
    same = [tone_judge(a) == tone_judge(b) for a, b in pairs]
    first, consistent, cons_same = 0, 0, []
    for (a, b), s in zip(pairs, same):
        w1 = pairwise_tone_judge(a, b, prng)
        w2 = pairwise_tone_judge(b, a, prng)
        first += (w1 == "first") + (w2 == "first")
        ok = (w1 == "first") == (w2 == "second")
        consistent += ok
        if s:
            cons_same.append(ok)
    print(f"\nswap test on 200 pairs: picks slot 1 in {first / 400:.0%} of 400 calls; consistent under swap "
          f"{consistent / 200:.0%} overall, {np.mean(cons_same):.0%} on the {len(cons_same)} same-quality pairs")
    print("  decision: use the pointwise binary judge; pairwise only with swap-and-aggregate")

    # ---- online estimate with PPI -------------------------------------------------------------
    pool_rng = random.Random(21)
    pool_pol = [pool_rng.random() < 0.85 for _ in range(20000)]
    pool_txt = [reply(pool_rng, p) for p in pool_pol]
    pool_y = np.array([not human(pool_rng, p) for p in pool_pol], float)        # 1 = PASS (human)
    pool_f = np.array([tone_judge(t) == "PASS" for t in pool_txt], float)       # 1 = PASS (judge)
    theta = pool_y.mean()
    nrng = np.random.default_rng(3)
    N, n, cover = 2000, 200, {"judge only": 0, "human only": 0, "PPI": 0}
    widths = {k: [] for k in cover}
    for rep in range(500):
        U = nrng.choice(len(pool_y), N, replace=False)
        L = nrng.choice(len(pool_y), n, replace=False)
        m, se = mean_se(pool_f[U])
        est = {"judge only": (m, m - Z95 * se, m + Z95 * se)}
        m, se = mean_se(pool_y[L])
        est["human only"] = (m, m - Z95 * se, m + Z95 * se)
        est["PPI"] = ppi_mean_ci(pool_y[L], pool_f[L], pool_f[U])
        for k, (e, lo, hi) in est.items():
            cover[k] += lo <= theta <= hi
            widths[k].append(hi - lo)
        if rep == 0:
            first_est = est
    print(f"\nonline tone pass rate, N={N} judged + n={n} human-labelled replies (true rate {theta:.3f}):")
    print(f"  {'estimator':<12}{'estimate':>9}  {'95% CI':<16}{'coverage/500':>13}{'mean width':>11}")
    for k, (e, lo, hi) in first_est.items():
        print(f"  {k:<12}{e:>9.3f}  [{lo:.3f}, {hi:.3f}]  {cover[k] / 500:>11.0%}{np.mean(widths[k]):>11.3f}")
    assert cover["PPI"] / 500 > 0.9 and cover["judge only"] / 500 < 0.5 and kap > 0.6


if __name__ == "__main__":
    main()
