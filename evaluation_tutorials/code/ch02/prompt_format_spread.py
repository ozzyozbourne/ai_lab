"""Prompt-format sensitivity in the spirit of FormatSpread (Sclar et al. 2023), plus answer
extraction as part of the metric (lm-eval GSM8K strict vs flexible filters; simple-evals MC regex).

Chapter 2, section 2.10 (#prompt-sensitivity).
Run:  python3 code/ch02/prompt_format_spread.py
Expected key output: 20 meaning-preserving formats; each mock model's min/max/mean/spread;
the two models swap rank depending on the format; the same outputs score differently by extractor.
"""
from __future__ import annotations

import hashlib
import itertools
import re

import numpy as np

SEPARATORS = [": ", " - ", ":\n", " :: "]
FIELD_CASE = ["Question/Answer", "QUESTION/ANSWER", "question/answer"]
OPTION_STYLE = ["A)", "(A)", "A."]


def formats() -> list[str]:
    combos = list(itertools.product(SEPARATORS, FIELD_CASE, OPTION_STYLE))   # 36 combos
    rng = np.random.default_rng(0)
    pick = sorted(rng.choice(len(combos), size=20, replace=False))
    return [f"{case.split('/')[0]}{sep}{{q}} {opt} ... {case.split('/')[1]}{sep}" for sep, case, opt in
            (combos[i] for i in pick)]


def format_effect(model: str, fmt: str, scale: float) -> float:
    """Deterministic pseudo-random effect of a format on a model (stable across runs and machines)."""
    h = int(hashlib.sha256(f"{model}|{fmt}".encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return scale * (h - 0.5) * 2          # uniform in [-scale, +scale]


def evaluate(model: str, base: float, scale: float, fmt: str, n_items: int, seed: int) -> float:
    p = float(np.clip(base + format_effect(model, fmt, scale), 0.01, 0.99))
    rng = np.random.default_rng(seed)
    return float(np.mean(rng.random(n_items) < p))


# ---------- answer extraction: the regexes are quoted from real harnesses ----------
STRICT = re.compile(r"#### (\-?[0-9\.\,]+)")                     # lm-eval gsm8k strict-match
FLEX = re.compile(r"(-?[$0-9.,]{2,})|(-?[0-9]+)")                 # lm-eval gsm8k flexible-extract
SIMPLE_EVALS_MC = re.compile(r"(?i)Answer[ \t]*:[ \t]*\$?([A-D])\$?")   # openai/simple-evals common.py


def clean(x: str) -> str:
    """Rough analogue of the gsm8k regexes_to_ignore: drop ',', '$' and a trailing '.'."""
    return re.sub(r"\.$", "", x.replace(",", "").replace("$", ""))


def strict(text: str) -> str | None:
    m = STRICT.search(text)
    return clean(m.group(1)) if m else None


def flexible(text: str) -> str | None:
    ms = FLEX.findall(text)
    if not ms:
        return None
    g = [x for x in ms[-1] if x][0]          # group_select: -1 -> last match
    return clean(g)


if __name__ == "__main__":
    fmts = formats()
    models = {"model-1": (0.62, 0.18), "model-2": (0.58, 0.05)}   # (base accuracy, format sensitivity)
    table = {m: [evaluate(m, b, s, f, 1000, seed=i) for i, f in enumerate(fmts)] for m, (b, s) in models.items()}
    print(f"{len(fmts)} formats x 2 mock models, 1000 items each\n")
    print(f"{'#':>2}  {'format template':<44}{'model-1':>8}{'model-2':>8}  winner")
    for i, f in enumerate(fmts):
        a, b = table["model-1"][i], table["model-2"][i]
        print(f"{i:>2}  {f!r:<44}{a:>8.3f}{b:>8.3f}  {'1' if a > b else '2'}")
    print()
    for m, v in table.items():
        v = np.array(v)
        print(f"{m}: min {v.min():.3f}  max {v.max():.3f}  mean {v.mean():.3f}  spread {v.max() - v.min():.3f}")
    wins1 = sum(a > b for a, b in zip(table["model-1"], table["model-2"]))
    print(f"model-1 wins on {wins1}/{len(fmts)} formats")
    assert 0 < wins1 < len(fmts)                       # the ranking depends on the format
    assert np.ptp(table["model-1"]) > 0.2

    print("\n== Same outputs, different extractors (GSM8K gold = 1200; MC gold = B) ==")
    outputs = ["She has $1,200 left. #### 1,200", "The answer is 1200.", "#### 1200.00",
               "1,200 dollars, since 3 x 400 = 1200", "Step 1: 3 x 400 = 1200. Answer: 1200", "I think 1100"]
    gold = "1200"
    s_ok = f_ok = 0
    for o in outputs:
        s, f = strict(o), flexible(o)
        s_ok += s == gold
        f_ok += f == gold
        print(f"{o!r:<42} strict={s!s:<8} flexible={f!s:<8}")
    print(f"strict-match accuracy {s_ok}/{len(outputs)}   flexible-extract accuracy {f_ok}/{len(outputs)}")
    assert (s_ok, f_ok) == (1, 4)
    mc = ["Reasoning... Answer: B", "answer:$B$", "The answer is (B).", "Answer: b"]
    hits = [(SIMPLE_EVALS_MC.search(t).group(1).upper() if SIMPLE_EVALS_MC.search(t) else None) for t in mc]
    for t, h in zip(mc, hits):
        print(f"simple-evals MC regex on {t!r:<26} -> {h}")
    assert hits == ["B", "B", None, "B"]
