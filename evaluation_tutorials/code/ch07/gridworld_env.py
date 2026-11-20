"""A Gymnasium-style GridWorld written from scratch (no gym install), plus the bootstrapping bug.

Section 7.2 (#interface) of Chapter 7.  Run:  python3 code/ch07/gridworld_env.py

What it demonstrates
  * the Gymnasium contract: reset(seed=...) -> (obs, info); step(a) -> (obs, reward, terminated, truncated, info)
  * an environment-owned RNG (self.np_random) seeded only through reset(seed=...)
  * a time limit that ends the episode with truncated=True, never terminated=True
  * BuggyGridWorld: the same env with three classic bugs (global RNG, time limit reported as terminated,
    an off-by-one that lets the agent leave the grid); mini_check_env.py catches all three
  * the "(1 - done)" bootstrapping bug on a never-ending task: TD(0) learns V = 5.26 instead of the true 10.0

Expected key output: the random-policy loop ends 1000 steps in a mix of terminated and truncated episodes,
and the value-target table shows 10.00 (right) vs 5.26 (wrong).
"""
from __future__ import annotations

import random
from dataclasses import dataclass

import numpy as np


# ---------------------------------------------------------------- minimal spaces
@dataclass(frozen=True)
class Discrete:
    n: int

    def sample(self, rng: np.random.Generator) -> int:
        return int(rng.integers(self.n))

    def contains(self, x) -> bool:
        return isinstance(x, (int, np.integer)) and 0 <= int(x) < self.n


@dataclass(frozen=True)
class BoxInt:
    """Integer box: every coordinate in [low, high]. Enough for a grid position."""
    low: int
    high: int
    shape: tuple[int, ...]

    def contains(self, x) -> bool:
        x = np.asarray(x)
        return x.shape == self.shape and bool(np.all((x >= self.low) & (x <= self.high)))


MOVES = {0: (-1, 0), 1: (0, 1), 2: (1, 0), 3: (0, -1)}   # up, right, down, left


class GridWorld:
    """5x5 grid. Goal at (4,4) gives +1 and terminates; lava at (2,2) gives -1 and terminates.
    Each step costs -0.01. With probability `slip` the action is replaced by a random one (env randomness).
    The episode is truncated after `max_episode_steps` steps."""

    metadata = {"version": "GridWorld-v1"}

    def __init__(self, size: int = 5, slip: float = 0.1, max_episode_steps: int = 50):
        self.size, self.slip, self.max_episode_steps = size, slip, max_episode_steps
        self.action_space = Discrete(4)
        self.observation_space = BoxInt(0, size - 1, (2,))
        self.goal, self.lava = (size - 1, size - 1), (2, 2)
        self.np_random = np.random.default_rng()
        self.pos = (0, 0)
        self.t = 0

    # Gymnasium semantics: reset(seed) re-seeds the env RNG; reset() without seed keeps the stream going.
    def reset(self, seed: int | None = None, options: dict | None = None):
        if seed is not None:
            self.np_random = np.random.default_rng(seed)
        free = [(r, c) for r in range(self.size) for c in range(self.size) if (r, c) not in (self.goal, self.lava)]
        self.pos = free[int(self.np_random.integers(len(free)))]
        self.t = 0
        return np.array(self.pos), {"t": 0}

    def _rand(self) -> float:
        return float(self.np_random.random())

    def _move(self, action: int) -> tuple[int, int]:
        dr, dc = MOVES[action]
        r = min(max(self.pos[0] + dr, 0), self.size - 1)
        c = min(max(self.pos[1] + dc, 0), self.size - 1)
        return r, c

    def step(self, action: int):
        assert self.action_space.contains(action), f"invalid action {action!r}"
        if self._rand() < self.slip:
            action = int(self.np_random.integers(4))
        self.pos = self._move(action)
        self.t += 1
        reward, terminated = -0.01, False
        if self.pos == self.goal:
            reward, terminated = 1.0, True
        elif self.pos == self.lava:
            reward, terminated = -1.0, True
        truncated = (not terminated) and self.t >= self.max_episode_steps
        return np.array(self.pos), reward, terminated, truncated, {"t": self.t}


class BuggyGridWorld(GridWorld):
    """Three bugs that real environments ship with."""

    def _rand(self) -> float:                         # bug 1: global, unseeded RNG -> not reproducible
        return random.random()

    def _move(self, action: int) -> tuple[int, int]:  # bug 2: off-by-one bound lets the agent walk to row/col 5
        dr, dc = MOVES[action]
        r = min(max(self.pos[0] + dr, 0), self.size)
        c = min(max(self.pos[1] + dc, 0), self.size)
        return r, c

    def step(self, action: int):
        obs, reward, terminated, truncated, info = super().step(action)
        if truncated:                                 # bug 3: time limit reported as a terminal state
            terminated, truncated = True, False
        return obs, reward, terminated, truncated, info


# ---------------------------------------------------------------- bootstrapping bug demo
def td0_value(gamma: float, horizon: int, use_terminated: bool, episodes: int = 5000, lr: float = 0.002) -> float:
    """One-state task that pays +1 every step forever; a TimeLimit truncates it after `horizon` steps.
    The true value of the state is 1/(1-gamma). TD(0) target: r + gamma * (1 - flag) * V."""
    v = 0.0
    for _ in range(episodes):
        for t in range(1, horizon + 1):
            truncated = t == horizon
            terminated = False                      # the task itself never ends
            done = terminated or truncated
            flag = terminated if use_terminated else done
            target = 1.0 + gamma * (1 - flag) * v
            v += lr * (target - v)
    return v


def main() -> None:
    # The Gymnasium README loop, against our env.
    env = GridWorld()
    observation, info = env.reset(seed=42)
    policy_rng = np.random.default_rng(0)
    n_term = n_trunc = 0
    ep_ret, returns = 0.0, []
    for _ in range(1000):
        action = env.action_space.sample(policy_rng)
        observation, reward, terminated, truncated, info = env.step(action)
        ep_ret += reward
        if terminated or truncated:
            n_term += terminated
            n_trunc += truncated
            returns.append(ep_ret)
            ep_ret = 0.0
            observation, info = env.reset()
    print("Random policy, 1000 steps on GridWorld-v1 (seed=42)")
    print(f"  episodes finished : {len(returns)}  (terminated {n_term}, truncated {n_trunc})")
    print(f"  truncation rate   : {n_trunc / len(returns):.1%}")
    print(f"  mean return       : {np.mean(returns):+.3f}")
    assert n_term + n_trunc == len(returns) and n_trunc > 0 and n_term > 0

    gamma, horizon = 0.9, 10
    right = td0_value(gamma, horizon, use_terminated=True)
    wrong = td0_value(gamma, horizon, use_terminated=False)
    closed_form_wrong = 1 / (1 - gamma * (1 - 1 / horizon))
    print(f"\nValue of a never-ending +1/step task, gamma={gamma}, TimeLimit={horizon}")
    print(f"  true value 1/(1-gamma)                : {1 / (1 - gamma):6.2f}")
    print(f"  TD(0) with (1 - terminated)  [right]  : {right:6.2f}")
    print(f"  TD(0) with (1 - done)        [wrong]  : {wrong:6.2f}")
    print(f"  closed form of the wrong fixed point  : {closed_form_wrong:6.2f}  = 1/(1 - gamma*(1 - 1/T))")
    assert abs(right - 10.0) < 0.3
    assert abs(closed_form_wrong - 5.263) < 1e-3 and abs(wrong - closed_form_wrong) < 0.1


if __name__ == "__main__":
    main()
