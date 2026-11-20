"""Log-likelihood multiple-choice scoring with a mock LM: acc vs acc_norm vs acc_mutual_info,
letter (MCF) scoring with a position prior, and the permutation fix. Plus perplexity and bits-per-byte.

Chapter 2, section 2.4 (#logprob) and Figure 2.3.
Run:  python3 code/ch02/mock_mc_eval.py
Expected key output: the Figure 2.3 item picks A / C / B under acc / acc_norm / MI;
on 400 mock items acc, acc_norm and MI disagree; the letter prior is cancelled by averaging
over cyclic permutations; PPL = 3.364 for token probabilities [0.5, 0.25, 0.125, 0.5].
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

LETTERS = "ABCD"


@dataclass
class Choice:
    text: str
    ll: float          # log p(choice | prompt), summed over the choice's tokens
    ll_uncond: float   # log p(choice | empty context), for mutual information


def predict(choices: list[Choice]) -> dict[str, int]:
    """Same decision rules as lm-eval-harness's multiple_choice output type."""
    lls = np.array([c.ll for c in choices])
    chars = np.array([float(len(c.text)) for c in choices])
    nbytes = np.array([float(len(c.text.encode("utf-8"))) for c in choices])
    mi = lls - np.array([c.ll_uncond for c in choices])
    return {"acc": int(np.argmax(lls)), "acc_norm": int(np.argmax(lls / chars)),
            "acc_bytes": int(np.argmax(lls / nbytes)), "acc_mutual_info": int(np.argmax(mi))}


def figure_item() -> None:
    """The hand-made item drawn in Figure 2.3 (gold = B)."""
    item = [Choice("oxygen", -2.0, -1.5), Choice("carbon dioxide", -3.3, -6.0),
            Choice("nitrogen gas from soil", -4.5, -6.0), Choice("the air", -2.4, -1.2)]
    print("Figure 2.3 item: 'Which gas do plants absorb for photosynthesis?'  gold = B")
    print(f"{'opt':<4}{'text':<24}{'ll':>6}{'chars':>6}{'ll/char':>9}{'ll_unc':>8}{'MI':>6}")
    for L, c in zip(LETTERS, item):
        print(f"{L:<4}{c.text:<24}{c.ll:>6.1f}{len(c.text):>6}{c.ll / len(c.text):>9.3f}"
              f"{c.ll_uncond:>8.1f}{c.ll - c.ll_uncond:>6.1f}")
    pred = predict(item)
    print("picked:", {k: LETTERS[v] for k, v in pred.items()})
    assert (pred["acc"], pred["acc_norm"], pred["acc_mutual_info"]) == (0, 2, 1)


def make_items(rng: np.random.Generator, n: int) -> list[tuple[list[Choice], int]]:
    """Mock LM: every token costs about -1 nat; the gold option gets a small per-token bonus;
    'frequent' generic options get a bonus both with and without context (a surface-frequency prior)."""
    items = []
    for _ in range(n):
        gold = int(rng.integers(4))
        choices = []
        for j in range(4):
            n_tok = int(rng.integers(1, 9))
            chars = int(n_tok * rng.uniform(3.5, 6.5))
            freq = rng.choice([0.0, 0.5], p=[0.7, 0.3])      # generic, high-frequency phrase?
            per_tok = -1.0 + freq + (0.35 if j == gold else 0.0)
            ll = n_tok * per_tok + rng.normal(0, 0.8)
            ll_unc = n_tok * (-1.6 + freq) + rng.normal(0, 0.8)
            choices.append(Choice("x" * chars, ll, ll_unc))
        items.append((choices, gold))
    return items


def letter_eval(rng: np.random.Generator, n: int, prior: np.ndarray) -> tuple[float, float]:
    """Letter (MCF) scoring: log p(letter) = knowledge signal for the content + a position prior.
    Returns (accuracy in the original order, accuracy after averaging over 4 cyclic rotations)."""
    plain = debiased = 0
    for _ in range(n):
        gold = int(rng.integers(4))
        content_score = rng.normal(0, 1.0, size=4)
        content_score[gold] += 1.0                         # the model weakly knows the answer
        logits = content_score + prior                     # position j shows content j
        plain += int(np.argmax(logits) == gold)
        # rotate contents through positions; average each content's score over all positions
        avg = np.zeros(4)
        for shift in range(4):
            pos_of_content = (np.arange(4) + shift) % 4
            avg += content_score + prior[pos_of_content]
        debiased += int(np.argmax(avg / 4) == gold)
    return plain / n, debiased / n


def perplexity_demo() -> None:
    probs = [0.5, 0.25, 0.125, 0.5]
    logps = [math.log(p) for p in probs]
    mean_lp = sum(logps) / len(logps)
    ppl = math.exp(-mean_lp)                  # lm-eval: perplexity(items) = exp(-mean(items))
    text = "a cat sat"                        # pretend these 4 tokens spell 9 UTF-8 bytes
    bpb = -sum(logps) / (len(text.encode("utf-8")) * math.log(2))
    print(f"token probs {probs}: mean log p = {mean_lp:.4f}, PPL = {ppl:.3f}")
    print(f"same tokens as {len(text.encode())} bytes: bits-per-byte = {bpb:.3f}")
    assert abs(mean_lp + 1.2130) < 1e-4 and abs(ppl - 3.364) < 1e-3


if __name__ == "__main__":
    figure_item()
    rng = np.random.default_rng(7)
    items = make_items(rng, 400)
    scores = {"acc": 0, "acc_norm": 0, "acc_bytes": 0, "acc_mutual_info": 0}
    for choices, gold in items:
        for k, v in predict(choices).items():
            scores[k] += int(v == gold)
    print("\n400 mock cloze items, same log-probs, four decision rules:")
    for k, v in scores.items():
        print(f"  {k:<16} {v / len(items):.3f}")
    assert scores["acc_norm"] > scores["acc"] and scores["acc_mutual_info"] > scores["acc"]

    print("\nLetter (A-D) scoring, 2000 items, gold position uniform:")
    for name, prior in [("no prior", np.zeros(4)), ("likes 'A'", np.array([1.2, 0.0, 0.0, 0.0]))]:
        plain, fixed = letter_eval(np.random.default_rng(11), 2000, prior)
        print(f"  {name:<10} original order acc = {plain:.3f}   permutation-averaged acc = {fixed:.3f}")
    p0, f0 = letter_eval(np.random.default_rng(11), 2000, np.zeros(4))
    pA, fA = letter_eval(np.random.default_rng(11), 2000, np.array([1.2, 0.0, 0.0, 0.0]))
    assert pA < p0 - 0.05 and abs(fA - f0) < 1e-12

    print()
    perplexity_demo()
