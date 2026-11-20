"""Strict vs flexible answer extraction on GSM8K-style generations (lm-eval's two filter pipelines).

Chapter 9, section 9.3 (Benchmark harnesses). Re-implements the two `filter_list` entries and the
`exact_match` normalisation from lm-evaluation-harness `lm_eval/tasks/gsm8k/gsm8k.yaml`:
  strict-match:     regex "#### (\\-?[0-9\\.\\,]+)", take_first
  flexible-extract: regex "(-?[$0-9.,]{2,})|(-?[0-9]+)", group_select -1 (last match), take_first
  exact_match:      ignore_case, regexes_to_ignore [",", "\\$", "(?s).*#### ", "\\.$"]
Run:  python3 code/ch09/filter_ablation.py
Expected key output: strict-match 0.400, flexible-extract 0.700 on the same 20 generations (a 30-point
gap that measures format-following, not arithmetic), and one case where flexible is wrong but strict right.
"""
from __future__ import annotations

import re

STRICT = re.compile(r"#### (\-?[0-9\.\,]+)")
FLEXIBLE = re.compile(r"(-?[$0-9.,]{2,})|(-?[0-9]+)")
IGNORE = [",", r"\$", r"(?s).*#### ", r"\.$"]
INVALID = "[invalid]"

# (target answer, model generation). 15 have correct arithmetic; 10 use the "#### n" format.
CASES: list[tuple[str, str]] = [
    ("1200", "She earns 12 * 100 = $1,200. #### 1,200"),
    ("18", "16 - 3 - 4 = 9 eggs, 9 * 2 = 18. #### 18"),
    ("3", "2 bolts blue + 1 white = 3. #### 3"),
    ("70000", "Cost 80000 + 50000 = 130000, worth 200000, profit 70000. #### 70000"),
    ("540", "3 sprints * 3 times * 60 m = 540 m. #### 540"),
    ("20", "Total feed 60 - 15 - 25 = 20 cups. #### 20"),
    ("64", "Glasses: 8 * 5 + 8 * 3 = 64. #### 64"),
    ("42", "#### 42. That took about 3 steps."),            # strict right, flexible picks 3
    ("260", "Toulouse has 2 * 20 = 40 ... total 260 sheep. The answer is 260."),
    ("160", "Downloads take 80 + 20 + 60 = 160 minutes.\nThe answer is 160."),
    ("45", "So the final answer is $45."),
    ("8", "He has 8 cars left"),
    ("57500", "The total is 57,500 dollars"),
    ("6", "Answer: 6"),
    ("24", "4 * 6 = 24, so 24."),
    ("35", "7 * 4 = 28. #### 28"),                            # wrong arithmetic, good format
    ("12", "12 / 2 + 1 = 7. #### 7"),
    ("90", "I think it is 80."),
    ("5", "Not enough information."),
    ("366", "Leap year: 365 days"),
]


def normalise(s: str) -> str:
    for pat in IGNORE:
        s = re.sub(pat, "", s)
    return s.lower().strip()


def strict_extract(gen: str) -> str:
    m = STRICT.findall(gen)
    return m[0] if m else INVALID                                  # take_first


def flexible_extract(gen: str) -> str:
    matches = FLEXIBLE.findall(gen)
    if not matches:
        return INVALID
    m = matches[-1]                                                # group_select: -1
    return next((g for g in m if g), INVALID) if isinstance(m, tuple) else m


def exact_match(pred: str, target_text: str) -> int:
    return int(normalise(pred) == normalise(target_text))


if __name__ == "__main__":
    rows, s_tot, f_tot = [], 0, 0
    for i, (ans, gen) in enumerate(CASES):
        target_text = f"(reference reasoning) #### {ans}"           # GSM8K references end in #### n
        s, f = strict_extract(gen), flexible_extract(gen)
        sm, fm = exact_match(s, target_text), exact_match(f, target_text)
        s_tot, f_tot = s_tot + sm, f_tot + fm
        rows.append((i, ans, s, sm, f, fm))
    print(f"{'#':>2}  {'target':>6}  {'strict':>9} ok  {'flexible':>9} ok")
    for i, ans, s, sm, f, fm in rows:
        print(f"{i:>2}  {ans:>6}  {s:>9} {sm:>2}  {f:>9} {fm:>2}")
    n = len(CASES)
    strict_acc, flex_acc = s_tot / n, f_tot / n
    has_fmt = sum("####" in g for _, g in CASES) / n
    print(f"\nstrict-match     exact_match = {strict_acc:.3f}")
    print(f"flexible-extract exact_match = {flex_acc:.3f}")
    print(f"gap = {100 * (flex_acc - strict_acc):.0f} points; share of generations using '####' = {has_fmt:.2f}")
    disagree = [r[0] for r in rows if r[3] != r[5]]
    print(f"cases where the filters disagree: {disagree}")
    assert abs(strict_acc - 0.40) < 1e-9 and abs(flex_acc - 0.70) < 1e-9
    assert rows[7][3] == 1 and rows[7][5] == 0                     # flexible is not always kinder
