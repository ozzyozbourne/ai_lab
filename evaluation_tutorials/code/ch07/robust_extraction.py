"""Answer extraction for RLVR math rewards: naive parsers vs a last-boxed-answer parser with a cascade.

Section 7.4 (#rlvr) of Chapter 7.  Run:  python3 code/ch07/robust_extraction.py

A verifier is only as good as its parser. Three extractors score 14 hand-labelled responses:
  * substring  : reward 1 if str(gold) appears anywhere in the response  (lenient: false positives)
  * first_num  : first number in the response must equal gold            (brittle: false negatives)
  * strict     : exactly one \\boxed{...} (nested braces handled); its content is normalised
                 (\\text{}, $, commas, spaces, trailing .0, a/b and \\frac{a}{b} fractions) and compared
                 by a cascade of string -> numeric -> exact-fraction matchers (cf. Reasoning Gym cascade_score)
Expected key output: substring 6 false positives / 3 false negatives, first_num 2 FP / 5 FN, strict 0 FP / 0 FN.
"""
from __future__ import annotations

import re
from fractions import Fraction


def boxed_contents(text: str) -> list[str]:
    """All \\boxed{...} contents, with balanced nested braces."""
    out, i = [], 0
    while (i := text.find("\\boxed{", i)) != -1:
        j, depth = i + len("\\boxed{"), 1
        start = j
        while j < len(text) and depth:
            depth += {"{": 1, "}": -1}.get(text[j], 0)
            j += 1
        if depth == 0:
            out.append(text[start:j - 1])
        i = j
    return out


def normalise(s: str) -> str:
    s = s.strip().strip("$").strip()
    s = re.sub(r"\\text\{([^{}]*)\}", r"\1", s)
    s = re.sub(r"\\d?frac\{([^{}]*)\}\{([^{}]*)\}", r"(\1)/(\2)", s)
    s = s.replace("\\!", "").replace("{,}", "").replace(",", "").replace(" ", "")
    s = re.sub(r"^\((-?\d+)\)/\((\d+)\)$", r"\1/\2", s)
    s = re.sub(r"(\d)\.0+$", r"\1", s)
    return s.rstrip(".")


def as_fraction(s: str) -> Fraction | None:
    try:
        return Fraction(s)
    except (ValueError, ZeroDivisionError):
        return None


def cascade_match(pred: str, gold: str) -> bool:
    p, g = normalise(pred), normalise(gold)
    if p == g:                                       # 1. normalised string match
        return True
    fp, fg = as_fraction(p), as_fraction(g)          # 2./3. numeric and exact fraction equivalence
    return fp is not None and fg is not None and fp == fg


def substring_verifier(resp: str, gold: str) -> float:
    return float(gold in resp)


def first_num_verifier(resp: str, gold: str) -> float:
    m = re.search(r"-?\d+(?:\.\d+)?", resp)
    return float(m is not None and as_fraction(m.group()) == as_fraction(gold))


def strict_verifier(resp: str, gold: str) -> float:
    boxes = boxed_contents(resp)
    if len(boxes) != 1:                              # zero boxes: no answer; several: hedging, not answering
        return 0.0
    return float(cascade_match(boxes[0], gold))


# (response, gold, is the response actually a correct final answer?)
CASES = [
    (r"So 12 * 3 = 36, the answer is \boxed{36}.", "36", True),
    (r"The total is \boxed{1,250} dollars.", "1250", True),
    (r"Answer: $\boxed{\frac{3}{4}}$", "0.75", True),
    (r"\boxed{\text{42}}", "42", True),
    (r"After simplifying we get \boxed{7.0}", "7", True),
    (r"Step 1: 2+2=4. Step 2: 4*3=12. Final: \boxed{12}", "12", True),
    (r"It is \boxed{\dfrac{10}{4}}", "5/2", True),
    (r"I think it's \boxed{360}", "36", False),
    (r"Could be \boxed{3}, \boxed{36} or \boxed{63}.", "36", False),
    (r"Since 36 is too large, the answer is \boxed{18}", "36", False),
    (r"\boxed{-7}", "7", False),
    (r"The answer is 12, no wait, \boxed{13}", "12", False),
    (r"There are 3 groups of 12, giving 36 items, but 1 is lost: \boxed{35}", "36", False),
    (r"The answer is \boxed{}", "0", False),
]


def main() -> None:
    assert boxed_contents(r"\boxed{\frac{1}{2}} and \boxed{x}") == [r"\frac{1}{2}", "x"]
    print(f"{'response':<62} {'gold':>5} {'true':>5} | sub first strict")
    tallies = {k: [0, 0] for k in ("substring", "first_num", "strict")}   # [FP, FN]
    for resp, gold, truth in CASES:
        scores = {"substring": substring_verifier(resp, gold), "first_num": first_num_verifier(resp, gold),
                  "strict": strict_verifier(resp, gold)}
        for k, v in scores.items():
            if v == 1 and not truth:
                tallies[k][0] += 1
            if v == 0 and truth:
                tallies[k][1] += 1
        shown = resp if len(resp) <= 60 else resp[:57] + "..."
        print(f"{shown:<62} {gold:>5} {str(truth)[0]:>5} | {scores['substring']:3.0f} "
              f"{scores['first_num']:5.0f} {scores['strict']:6.0f}")
    print("\nverifier    false positives  false negatives   (of 7 correct, 7 incorrect)")
    for k, (fp, fn) in tallies.items():
        print(f"{k:<11} {fp:>15}  {fn:>15}")
    assert tallies == {"substring": [6, 3], "first_num": [2, 5], "strict": [0, 0]}, tallies


if __name__ == "__main__":
    main()
