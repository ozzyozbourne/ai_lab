"""Aggregating across tasks: chance normalisation (Open LLM Leaderboard v2), macro vs micro
averages, and how a single average hides a trade-off (HELM-style multi-metric view).

Chapter 2, section 2.8 (#aggregation).
Run:  python3 code/ch02/normalize_scores.py
Expected key output: GPQA raw 0.60 -> 46.67; MuSR -> 35.00; macro and micro averages disagree
and reorder two models; the average hides a calibration trade-off.
"""
from __future__ import annotations


def normalize(raw: float, n_choices: int | None) -> float:
    """(raw - lower) / (1 - lower) * 100, clipped at 0. Generative tasks use lower = 0."""
    lower = 0.0 if n_choices is None else 1.0 / n_choices
    if raw < lower:
        return 0.0
    return (raw - lower) / (1 - lower) * 100


if __name__ == "__main__":
    print("== Chance normalisation ==")
    g = normalize(0.60, 4)
    print(f"GPQA (4 choices) raw 0.60 -> {g:.2f}")
    musr = {"murder mysteries": (0.7, 2), "object placement": (0.4, 5), "team allocation": (0.6, 3)}
    parts = []
    for name, (raw, k) in musr.items():
        parts.append(normalize(raw, k))
        print(f"MuSR {name:<17} ({k} choices) raw {raw:.1f} -> {parts[-1]:.2f}")
    musr_avg = sum(parts) / len(parts)
    print(f"MuSR average of normalised subtasks = {musr_avg:.2f}")
    print(f"MMLU-Pro (10 choices) raw 0.40 -> {normalize(0.40, 10):.2f}   vs 4-choice raw 0.40 -> {normalize(0.40, 4):.2f}")
    print(f"Below chance: 4-choice raw 0.22 -> {normalize(0.22, 4):.2f} (clipped)")
    print(f"Generative (MATH) raw 0.30 -> {normalize(0.30, None):.2f}")
    assert abs(g - 46.67) < 0.01 and abs(musr_avg - 35.00) < 1e-9

    print("\n== Macro vs micro averaging over subjects ==")
    # subject: (n_items, model_X correct, model_Y correct)
    subjects = {"law": (1500, 750, 840), "medicine": (300, 240, 210),
                "physics": (200, 170, 150), "history": (100, 85, 80)}
    for model, col in [("X", 1), ("Y", 2)]:
        accs = [v[col] / v[0] for v in subjects.values()]
        macro = sum(accs) / len(accs)
        micro = sum(v[col] for v in subjects.values()) / sum(v[0] for v in subjects.values())
        print(f"model {model}: per-subject " + " ".join(f"{a:.2f}" for a in accs)
              + f" | macro {macro:.3f} | micro {micro:.3f}")
        if model == "X":
            mX, uX = macro, micro
        else:
            mY, uY = macro, micro
    print("macro winner:", "X" if mX > mY else "Y", "| micro winner:", "X" if uX > uY else "Y")
    assert (mX > mY) and (uY > uX)

    print("\n== One average, two very different models (HELM-style multi-metric) ==")
    rows = {"model P": {"accuracy": 0.82, "calibration (1-ECE)": 0.70, "robustness": 0.60},
            "model Q": {"accuracy": 0.74, "calibration (1-ECE)": 0.92, "robustness": 0.46}}
    for name, m in rows.items():
        avg = sum(m.values()) / len(m)
        print(f"{name}: " + "  ".join(f"{k}={v:.2f}" for k, v in m.items()) + f"  | mean={avg:.3f}")
    assert abs(sum(rows["model P"].values()) - sum(rows["model Q"].values())) < 1e-9
