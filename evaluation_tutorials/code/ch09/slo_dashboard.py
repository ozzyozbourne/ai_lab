"""Latency and cost SLOs for an LLM service: percentiles, error-budget burn, cost per *successful* task.

Chapter 9, section 9.17 (Cost and latency SLOs). 28 simulated days of traffic. End-to-end latency =
TTFT + (output_tokens - 1) x TPOT by definition; the simulation uses output_tokens x TPOT, a difference of one
token (~8 ms) at 80-350 output tokens. On day 15 a release makes the median faster but sends 4% of requests down
a slow retrieval path (+3 s). SLOs: p95 TTFT < 800 ms, and 99% of requests finish in < 5 s
(error budget = 1% of requests over 28 days).
Run:  python3 code/ch09/slo_dashboard.py
Expected key output: after the release the mean (2.14 -> 2.12 s) and p50 (2.04 -> 1.95 s) improve and
p95 moves (3.62 -> 4.01 s end-to-end, TTFT 623 -> 674 ms) but TTFT stays inside its 800 ms SLO, while p99 end-to-end jumps
4.41 -> 5.50 s and the 5 s SLO burns its error budget at about 1.8-2x; the cheaper model costs less
per request ($0.00252 vs $0.00601) but more per successful task ($0.00945 vs $0.00750).
"""
from __future__ import annotations

import numpy as np

PRICE = {"small": (0.60e-6, 4.0e-6), "large": (1.25e-6, 10.0e-6)}   # $ per input / output token (mock)


def traffic(days: int, per_day: int, rng):
    n = days * per_day
    day = np.repeat(np.arange(1, days + 1), per_day)
    after = day >= 15
    ttft = rng.lognormal(np.log(350), 0.35, n) * np.where(after, 0.85, 1.0)
    tpot = rng.lognormal(np.log(0.008), 0.25, n) * np.where(after, 0.95, 1.0)                   # seconds per output token
    out_tok = rng.integers(80, 350, n)
    slow = after & (rng.random(n) < 0.04)                          # the new slow retrieval path
    ttft = ttft + slow * 3000.0
    e2e = ttft / 1000 + out_tok * tpot
    return day, ttft, e2e


def pct(x, q):
    return float(np.percentile(x, q))


def cost_per_success(model: str, n: int, p_success: float, p_429: float, p_trunc: float, rng):
    in_tok = rng.integers(800, 2500, n)
    out_tok = rng.integers(100, 700, n)
    throttled = rng.random(n) < p_429                              # 429: no tokens billed, retried later
    truncated = (~throttled) & (rng.random(n) < p_trunc)           # finish_reason == "length": billed, useless
    ok = (~throttled) & (~truncated) & (rng.random(n) < p_success)
    pin, pout = PRICE[model]
    cost = np.where(throttled, 0.0, in_tok * pin + out_tok * pout)
    return cost.sum() / n, cost.sum() / ok.sum(), ok.mean()


if __name__ == "__main__":
    rng = np.random.default_rng(17)
    day, ttft, e2e = traffic(28, 4000, rng)
    before, after = day < 15, day >= 15
    print(f"{'window':<14} {'mean e2e':>9} {'p50':>6} {'p95':>6} {'p99':>6} {'p95 TTFT ms':>12} {'>5s':>7}")
    stats = {}
    for name, m in (("days 1-14", before), ("days 15-28", after)):
        stats[name] = (e2e[m].mean(), pct(e2e[m], 50), pct(e2e[m], 95), pct(e2e[m], 99), pct(ttft[m], 95),
                       float((e2e[m] > 5).mean()))
        s = stats[name]
        print(f"{name:<14} {s[0]:>8.2f}s {s[1]:>5.2f}s {s[2]:>5.2f}s {s[3]:>5.2f}s {s[4]:>12.0f} {s[5]:>7.2%}")
    budget = 0.01
    bad_total = float((e2e > 5).mean())
    print(f"\nSLO '99% of requests < 5 s over 28 days': bad fraction {bad_total:.2%}, "
          f"budget used {bad_total / budget:.0%}")
    for d in (7, 14, 15, 21, 28):
        m = day == d
        print(f"  day {d:>2}: bad {float((e2e[m] > 5).mean()):.2%}  burn rate {float((e2e[m] > 5).mean()) / budget:.2f}x")
    print(f"SLO 'p95 TTFT < 800 ms': before {stats['days 1-14'][4]:.0f} ms, after {stats['days 15-28'][4]:.0f} ms")
    print("\ncost per request vs cost per successful task (10,000 tasks each)")
    print(f"{'model':<6} {'success':>8} {'$/request':>10} {'$/successful task':>18}")
    res = {}
    for model, ps, p429, ptr in (("small", 0.30, 0.03, 0.06), ("large", 0.82, 0.01, 0.01)):
        per_req, per_ok, succ = cost_per_success(model, 10_000, ps, p429, ptr, rng)
        res[model] = (per_req, per_ok)
        print(f"{model:<6} {succ:>8.3f} {per_req:>10.5f} {per_ok:>18.5f}")
    b, a = stats["days 1-14"], stats["days 15-28"]
    assert a[1] < b[1] and a[3] > 1.2 * b[3] and a[0] < b[0] and a[4] < 800
    assert a[5] / budget > 1.0
    assert res["small"][0] < res["large"][0] and res["small"][1] > res["large"][1]
