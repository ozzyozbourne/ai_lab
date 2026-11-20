"""Nondeterminism: 'temperature 0' that is not deterministic, TARr@N / TARa@N, and seed variance.

Chapter 5, section 5.10 (#nondeterminism).
Run:  python3 code/ch05/seeds_nondeterminism.py
Shows: (1) a mock greedy model whose logits get a tiny batch-size-dependent perturbation (a stand-in for
non-batch-invariant kernels): 10 'deterministic' runs disagree on near-tie questions; we compute the
spread of accuracy and the total agreement rates TARr@10 (raw strings) and TARa@10 (parsed answers);
(2) a batch-invariant run is bitwise identical; (3) a sampled (temperature 1) model on a 30-question
AIME-sized set: per-seed accuracy sd, and how the mean over K seeds stabilises.
"""
from __future__ import annotations

import numpy as np

N_Q, N_OPT, RUNS = 500, 4, 10


def make_benchmark(rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    logits = rng.normal(0, 1.0, size=(N_Q, N_OPT))
    gold = rng.integers(0, N_OPT, size=N_Q)
    logits[np.arange(N_Q), gold] += 0.8  # the model leans towards the right answer
    return logits, gold


def greedy_run(logits: np.ndarray, batch_size: int, batch_invariant: bool) -> list[str]:
    """Argmax decode. Non-invariant kernels add a perturbation that depends on the batch size."""
    if batch_invariant:
        pert = np.zeros_like(logits)
    else:
        pert = np.random.default_rng(batch_size).normal(0, 0.02, size=logits.shape)
    choice = np.argmax(logits + pert, axis=1)
    # raw text also varies in formatting on near ties (e.g. trailing whitespace from a different token path)
    margin = np.sort(logits + pert, axis=1)[:, -1] - np.sort(logits + pert, axis=1)[:, -2]
    fmt_rng = np.random.default_rng(0 if batch_invariant else batch_size + 1000)
    tail = np.where((margin < 0.15) & (fmt_rng.random(len(choice)) < 0.5), " ", "")
    return [f"Answer: {'ABCD'[c]}{t}" for c, t in zip(choice, tail)]


def parse(raw: str) -> str:
    return raw.strip()[-1]


def tar(outputs: list[list[str]]) -> float:
    """Total agreement rate: fraction of questions where all N runs give the identical value."""
    return float(np.mean([len(set(col)) == 1 for col in zip(*outputs)]))


def main() -> None:
    rng = np.random.default_rng(2408)
    logits, gold = make_benchmark(rng)
    batch_sizes = [1, 3, 8, 16, 17, 32, 33, 64, 100, 128]  # server load decides the batch you land in
    raws = [greedy_run(logits, bs, batch_invariant=False) for bs in batch_sizes]
    parsed = [[parse(r) for r in run] for run in raws]
    accs = np.array([np.mean([p == "ABCD"[g] for p, g in zip(run, gold)]) for run in parsed])
    print(f"(1) Greedy decoding, {RUNS} runs at different batch sizes, n = {N_Q}")
    print("    accuracy per run: " + " ".join(f"{a:.3f}" for a in accs))
    print(f"    min {accs.min():.3f}  max {accs.max():.3f}  spread {100*(accs.max()-accs.min()):.1f} pts")
    best = np.mean([any(p[i] == "ABCD"[gold[i]] for p in parsed) for i in range(N_Q)])
    worst = np.mean([all(p[i] == "ABCD"[gold[i]] for p in parsed) for i in range(N_Q)])
    print(f"    best-possible (right in any run) {best:.3f} vs worst-possible (right in all runs) {worst:.3f}")
    tr, ta = tar(raws), tar(parsed)
    print(f"    TARr@{RUNS} (raw strings) = {tr:.3f}   TARa@{RUNS} (parsed answers) = {ta:.3f}")
    assert accs.max() > accs.min() and tr < ta < 1.0

    inv = [greedy_run(logits, bs, batch_invariant=True) for bs in batch_sizes]
    print(f"(2) Batch-invariant kernels: TARr@{RUNS} = {tar(inv):.3f}")
    assert tar(inv) == 1.0

    # (3) temperature-1 sampling on an AIME-sized set
    n = 30
    p_true = np.random.default_rng(7).beta(0.5, 0.6, size=n)  # per-problem solve rates, mean ~0.45
    srng = np.random.default_rng(99)
    seeds = 600
    acc = (srng.random((seeds, n)) < p_true).mean(axis=1)
    print(f"(3) Sampled decoding, n = {n} problems (one problem = {100/n:.1f} pts), {seeds} seeds")
    print(f"    per-seed accuracy: mean {acc.mean()*100:.1f}, sd {acc.std(ddof=1)*100:.1f} pts, "
          f"range {acc.min()*100:.1f}-{acc.max()*100:.1f}")
    for k in (1, 4, 10, 30):
        groups = acc[: (seeds // k) * k].reshape(-1, k).mean(axis=1) if k <= seeds // 10 else None
        sd = np.sqrt(np.mean(p_true * (1 - p_true)) / n / k)
        g = f"{groups.std(ddof=1)*100:4.1f}" if groups is not None and len(groups) > 1 else "  - "
        print(f"    mean over K={k:>2} seeds: theoretical sd {sd*100:4.1f} pts, observed sd across blocks {g}")
    print(f"    report: {acc[:10].mean()*100:.1f} +/- {acc[:10].std(ddof=1)*100:.1f} (mean +/- sd over 10 seeds)")
    assert acc.std(ddof=1) > 0.05


if __name__ == "__main__":
    main()
