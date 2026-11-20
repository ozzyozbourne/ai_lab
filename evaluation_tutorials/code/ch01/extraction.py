"""The answer parser is part of the metric: GSM8K strict vs flexible extraction.

Chapter 1, section 1.5 (Metrics in one page).
Re-implements the two filter pipelines and the exact_match normalisation from
EleutherAI/lm-evaluation-harness lm_eval/tasks/gsm8k/gsm8k.yaml, on 16 mocked model outputs.
Run:  python3 code/ch01/extraction.py
Expected key output: strict-match 0.312, flexible-extract 0.625, human-judged correct 0.875;
flexible-extract has 1 false positive (item 16) and 5 false negatives.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

STRICT = r"#### (\-?[0-9\.\,]+)"                    # gsm8k.yaml, filter "strict-match"
FLEXIBLE = r"(-?[$0-9.,]{2,})|(-?[0-9]+)"         # gsm8k.yaml, filter "flexible-extract"
IGNORE = [",", r"\$", r"(?s).*#### ", r"\.$"]      # metric_list.exact_match.regexes_to_ignore


@dataclass(frozen=True)
class Item:
    output: str          # what the (mock) model generated
    target: str          # GSM8K-style reference, "... #### <number>"
    human_ok: bool       # would a careful human mark the final answer correct?


ITEMS = [
    Item("40 + 2 = 42 apples.\n#### 42", "#### 42", True),
    Item("3 * $400 = $1,200.\n#### 1,200", "#### 1200", True),
    Item("The answer is $42.", "#### 42", True),
    Item("**42**", "#### 42", True),
    Item("42.0", "#### 42", True),
    Item("#### 42.0", "#### 42", True),
    Item("The answer is 42. Check: 6 * 7 = 42 and 50 - 8.", "#### 42", True),
    Item("#### 42\nExplanation: we used 3 steps.", "#### 42", True),
    Item("I think it is 41.\n#### 41", "#### 42", False),
    Item("Answer: 7", "#### 7", True),
    Item("#### -5", "#### -5", True),
    Item("It drops to −5 degrees, so the answer is −5.", "#### -5", True),  # Unicode minus
    Item("The total is 1,200 dollars.\n####1200", "#### 1200", True),                # no space
    Item("So x = 18 and the answer is 18", "#### 18", True),
    Item("#### 18", "#### 18", True),
    Item("Final answer: 17. (Earlier I wrote 18 by mistake.)", "#### 18", False),
]


def regex_filter(resp: str, pattern: str, group_select: int = 0) -> str:
    """Mirror of lm-eval's RegexFilter: findall, pick a match, take first non-empty group."""
    matches = re.findall(pattern, resp)
    if not matches:
        return "[invalid]"
    m = matches[group_select]
    if isinstance(m, tuple):
        m = [g for g in m if g][0]
    return m.strip()


def normalise(s: str) -> str:
    for rx in IGNORE:                                  # applied to prediction AND reference
        s = re.sub(rx, "", s)
    return s.lower().strip()                           # ignore_case: true


def exact_match(pred: str, target: str) -> bool:
    return normalise(pred) == normalise(target)


if __name__ == "__main__":
    strict_hits = flex_hits = human_hits = 0
    flex_fp: list[int] = []
    flex_fn: list[int] = []
    print(f"{'#':>2}  {'model output (escaped)':<46} {'strict':>9} {'flexible':>9} {'human':>6}")
    for i, it in enumerate(ITEMS, 1):
        s = regex_filter(it.output, STRICT)
        f = regex_filter(it.output, FLEXIBLE, group_select=-1)
        s_ok, f_ok = exact_match(s, it.target), exact_match(f, it.target)
        strict_hits += s_ok
        flex_hits += f_ok
        human_hits += it.human_ok
        if f_ok and not it.human_ok:
            flex_fp.append(i)
        if it.human_ok and not f_ok:
            flex_fn.append(i)
        shown = it.output.replace("\n", "\\n")[:46]
        mark = lambda ok, x: f"{'none' if x == '[invalid]' else x[:6]}{'+' if ok else '-'}"
        print(f"{i:>2}  {shown:<46} {mark(s_ok, s):>9} {mark(f_ok, f):>9} {'yes' if it.human_ok else 'no':>6}")
    n = len(ITEMS)
    print(f"\naccuracy  strict-match={strict_hits / n:.3f}  flexible-extract={flex_hits / n:.3f}  "
          f"human-judged={human_hits / n:.3f}  (n={n})")
    print(f"flexible-extract vs human: false positives {flex_fp}, false negatives {flex_fn}")
    print("Same outputs, three different 'accuracies': the parser is part of the measurement.")
    assert (strict_hits, flex_hits, human_hits) == (5, 10, 14), (strict_hits, flex_hits, human_hits)
    assert flex_fp == [16] and flex_fn == [5, 6, 7, 8, 12]
