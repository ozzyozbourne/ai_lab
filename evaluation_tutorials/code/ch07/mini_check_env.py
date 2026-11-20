"""A miniature Gymnasium `check_env`: the checks that catch most environment bugs.

Section 7.2 (#interface) of Chapter 7.  Run:  python3 code/ch07/mini_check_env.py

Modelled on gymnasium/utils/env_checker.py (check_reset_seed_determinism, check_step_determinism,
observation-in-space checks) plus one check Gymnasium cannot do generically: that hitting the time limit
sets truncated=True and terminated=False.
Runs the suite on GridWorld (all pass) and BuggyGridWorld (three failures).
Expected key output: GridWorld 7/7 checks pass; BuggyGridWorld fails step determinism, obs-in-space and time limit.
"""
from __future__ import annotations

import pathlib
import random
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gridworld_env import BuggyGridWorld, GridWorld  # noqa: E402


def rollout(env, seed: int, actions: list[int]):
    obs, _ = env.reset(seed=seed)
    out = [("reset", tuple(int(v) for v in obs))]
    for a in actions:
        obs, r, term, trunc, _ = env.step(a)
        out.append((tuple(int(v) for v in obs), r, term, trunc))
        if term or trunc:
            obs, _ = env.reset()
            out.append(("reset", tuple(int(v) for v in obs)))
    return out


def check_reset_seed_determinism(make) -> str | None:
    e1, e2 = make(), make()
    o1, _ = e1.reset(seed=123)
    o2, _ = e2.reset(seed=123)
    if not np.array_equal(o1, o2):
        return f"reset(seed=123) gave {o1} and {o2}"
    return None


def check_step_determinism(make, n_steps: int = 300) -> str | None:
    acts = list(np.random.default_rng(7).integers(4, size=n_steps).astype(int))
    a, b = rollout(make(), 11, acts), rollout(make(), 11, acts)
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            return f"same seed + same actions diverged at record {i}: obs {x[0]} vs {y[0]}"
    return None


def check_reset_obs_in_space(make) -> str | None:
    env = make()
    for s in range(50):
        obs, info = env.reset(seed=s)
        if not env.observation_space.contains(obs):
            return f"reset obs {obs} not in observation_space"
        if not isinstance(info, dict):
            return "reset info is not a dict"
    return None


def check_step_obs_in_space(make, n_steps: int = 2000) -> str | None:
    env = make()
    env.reset(seed=0)
    rng = np.random.default_rng(1)
    for i in range(n_steps):
        obs, r, term, trunc, info = env.step(env.action_space.sample(rng))
        if not env.observation_space.contains(obs):
            return f"step {i}: obs {obs} outside observation_space"
        if term or trunc:
            env.reset()
    return None


def check_step_types(make) -> str | None:
    env = make()
    env.reset(seed=0)
    _, r, term, trunc, info = env.step(0)
    if not isinstance(r, float):
        return f"reward has type {type(r).__name__}"
    if not (isinstance(term, bool) and isinstance(trunc, bool)):
        return "terminated/truncated must be bool"
    if not isinstance(info, dict):
        return "info must be a dict"
    return None


def check_time_limit_truncates(make) -> str | None:
    """Push into the top-left corner forever (slip off): episode must end by truncation, not termination."""
    env = make()
    env.slip = 0.0
    env.reset(seed=0)
    env.pos = (0, 0)
    for t in range(1, env.max_episode_steps + 1):
        _, _, term, trunc, _ = env.step(0)        # 'up' against the wall: never reaches goal or lava
        if term or trunc:
            if t != env.max_episode_steps:
                return f"episode ended early at t={t}"
            if term or not trunc:
                return f"time limit gave terminated={term}, truncated={trunc} (want False, True)"
            return None
    return "episode never ended"


def check_unseeded_reset_runs(make) -> str | None:
    env = make()
    env.reset(seed=3)
    env.reset()
    return None


CHECKS = [check_reset_seed_determinism, check_step_determinism, check_reset_obs_in_space,
          check_step_obs_in_space, check_step_types, check_time_limit_truncates, check_unseeded_reset_runs]


def run_suite(name: str, make) -> list[str]:
    print(f"\n{name}")
    failed = []
    for chk in CHECKS:
        try:
            err = chk(make)
        except Exception as exc:  # an exception is a failed check, with its message
            err = f"raised {type(exc).__name__}: {exc}"
        status = "ok  " if err is None else "FAIL"
        print(f"  {status} {chk.__name__:<30} {'' if err is None else err[:70]}")
        if err is not None:
            failed.append(chk.__name__)
    print(f"  -> {len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed")
    return failed


def main() -> None:
    random.seed(2026)   # only so this printed report is reproducible; the bug itself is using the global RNG
    good = run_suite("GridWorld-v1", GridWorld)
    bad = run_suite("BuggyGridWorld", BuggyGridWorld)
    assert good == []
    assert set(bad) == {"check_step_determinism", "check_step_obs_in_space", "check_time_limit_truncates"}, bad


if __name__ == "__main__":
    main()
