"""Trial runner: fresh env per trial, infra_error status + retry, cost/latency, span logs (10.7, 10.9).

    r = run_trial(task, "v2", trial=0)          # one TrialResult
    rs = run_suite(tasks, "v2", n_trials=5)      # list of TrialResult
    spans(r)                                     # OTel-GenAI-style span records for the transcript

Seeds are derived from (task id, trial, attempt) only, so agent v1 and v2 see the same user phrasing on the
same trial (common random numbers make the paired comparison tighter). Fault draws are NOT shared: the env
draws one per tool call, so agents with different call sequences meet different faults, and a retried
attempt gets a new seed (new phrasing), which breaks the pairing for that trial.
"""
from __future__ import annotations

import json
import math
import zlib
from dataclasses import asdict, dataclass, field
from pathlib import Path

from .agents import make_agent
from .env import InfraError, ShopDeskEnv
from .graders import grade_hardened, grade_weak, outputs_ok, policy_violations, state_ok, tone_judge, agent_messages

SYSTEM_PROMPT_TOKENS = 900


def seed_for(*parts) -> int:
    return zlib.crc32("|".join(map(str, parts)).encode())


@dataclass
class TrialResult:
    task_id: str
    slice: str
    template: str
    agent: str
    trial: int
    status: str                       # "ok" | "infra_error"
    attempts: int
    passed: int = 0                   # hardened grader
    weak_passed: int = 0              # weak v0 grader (for red-teaming and RL)
    state_ok: int = 0
    outputs_ok: int = 0
    violations: list = field(default_factory=list)
    truncated: int = 0
    steps: int = 0
    tokens_in: int = 0
    tokens_out: int = 0
    cost: float = 0.0
    latency_s: float = 0.0
    tone_pass: int | None = None
    error: str = ""
    transcript: list = field(default_factory=list)


def _episode(task: dict, agent_name: str, seed: int, infra_fail_rate: float, bugs=frozenset(), agent=None):
    env = ShopDeskEnv(task, infra_fail_rate=infra_fail_rate, bugs=bugs)
    agent = agent or make_agent(agent_name)
    obs, _ = env.reset(seed=seed)
    agent.reset(seed + 1)
    m, rng = agent.model, __import__('random').Random(seed + 2)   # latency noise, separate stream
    tin = tout = 0
    lat = 0.0
    timings = []
    terminated = truncated = False
    while not (terminated or truncated):
        context = SYSTEM_PROMPT_TOKENS + sum(len(json.dumps(e)) for e in env.transcript) // 4
        action = agent.act(obs)
        out = len(action) // 4 + m["think_tokens"]
        t_llm = 0.35 + out / m["tok_per_s"] + rng.lognormvariate(-1.5, 0.6)
        obs, _, terminated, truncated, _ = env.step(action)
        t_tool = 0.0 if action.startswith("send_message") else rng.lognormvariate(-1.2, 0.5)
        tin, tout, lat = tin + context, tout + out, lat + t_llm + t_tool
        timings.append((round(t_llm, 3), round(t_tool, 3), context, out))
    return env, agent, tin, tout, lat, truncated, timings


def run_trial(task: dict, agent_name: str, trial: int, infra_fail_rate: float = 0.03, max_retries: int = 2,
              base_seed: int = 0, bugs=frozenset(), judge: bool = True) -> TrialResult:
    for attempt in range(max_retries + 1):
        seed = seed_for(base_seed, task["id"], trial, attempt)
        try:
            env, agent, tin, tout, lat, trunc, timings = _episode(task, agent_name, seed, infra_fail_rate, bugs)
        except InfraError as e:
            last = str(e)
            continue
        tr = env.transcript
        msgs = agent_messages(tr)
        r = TrialResult(task["id"], task["slice"], task["template"], agent_name, trial, "ok", attempt + 1,
                        passed=int(grade_hardened(task, env.db, tr)), weak_passed=int(grade_weak(task, env.db, tr)),
                        state_ok=int(state_ok(task, env.db)), outputs_ok=int(outputs_ok(task, tr)),
                        violations=policy_violations(task, tr), truncated=int(trunc), steps=env.steps,
                        tokens_in=tin, tokens_out=tout,
                        cost=tin * agent.model["price_in"] + tout * agent.model["price_out"], latency_s=lat,
                        tone_pass=(int(tone_judge(msgs[-1]) == "PASS") if (judge and msgs) else None),
                        transcript=tr)
        r.timings = timings  # type: ignore[attr-defined]
        return r
    return TrialResult(task["id"], task["slice"], task["template"], agent_name, trial, "infra_error",
                       max_retries + 1, error=last)


def run_suite(tasks: list[dict], agent_name: str, n_trials: int = 5, **kw) -> list[TrialResult]:
    return [run_trial(t, agent_name, k, **kw) for t in tasks for k in range(n_trials)]


def write_jsonl(results: list[TrialResult], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for r in results:
            d = asdict(r)
            f.write(json.dumps(d) + "\n")


def spans(r: TrialResult) -> list[dict]:
    """Flatten a transcript into span records named after the OTel GenAI conventions."""
    root = {"trace_id": f"{r.task_id}/{r.agent}/t{r.trial}", "span_id": "0", "parent_id": None,
            "name": f"invoke_agent {r.agent}", "status": "ok" if r.passed else "fail"}
    out, t = [root], 0.0
    timings = getattr(r, "timings", [])
    for i, e in enumerate(r.transcript[1:], start=1):
        t_llm, t_tool, cin, cout = timings[i - 1] if i - 1 < len(timings) else (0, 0, 0, 0)
        out.append({"span_id": f"{i}.0", "parent_id": "0", "name": "chat", "start_s": round(t, 2),
                    "dur_s": t_llm, "gen_ai.usage.input_tokens": cin, "gen_ai.usage.output_tokens": cout})
        t += t_llm
        res = e.get("result") or {}
        err = e.get("error") or (None if res.get("ok", True) else res.get("error"))
        out.append({"span_id": f"{i}.1", "parent_id": "0", "name": f"execute_tool {e['tool'] or '?'}",
                    "start_s": round(t, 2), "dur_s": t_tool, "args": e["args"], "error": err,
                    "user_reply": e.get("user_reply")})
        t += t_tool
    return out


def p95(xs) -> float:
    s = sorted(xs)
    return s[min(len(s) - 1, math.ceil(0.95 * len(s)) - 1)] if s else float("nan")
