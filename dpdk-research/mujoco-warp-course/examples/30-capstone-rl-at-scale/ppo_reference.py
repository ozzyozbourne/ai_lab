"""ppo_reference.py - a small reference PPO for the on-device environments of Chapter 30.

Read it, run it, modify it; you do not need to write PPO from scratch. It works with any env that
has the interface of CartpoleEnv / HumanoidStandEnv with backend="torch":
  env.nworld, env.reset() -> obs, env.step(action) -> (obs, reward, terminated, truncated),
  env.final_obs (the observation a finished episode ended in), env.episode_stats().
The env tensors are zero-copy VIEWS of Warp buffers that the next env.step overwrites, so the
rollout clones what it keeps. Shapes: N = nworld, T = n_steps, D = obs dim, A = action dim.
"""
import time
from dataclasses import dataclass, field

import torch
import torch.nn as nn


@dataclass
class PPOConfig:
    n_steps: int = 32            # T: control steps per rollout (per world)
    gamma: float = 0.99          # discount
    lam: float = 0.95            # GAE lambda
    epochs: int = 8              # passes over each rollout
    minibatches: int = 4         # minibatches per pass
    clip: float = 0.2            # PPO ratio clip
    lr: float = 1e-3
    vf_coef: float = 0.5
    ent_coef: float = 0.0
    max_grad_norm: float = 1.0
    hidden: tuple = field(default=(64, 64))
    init_log_std: float = -1.0


class ActorCritic(nn.Module):
    """Gaussian policy and value function, each an MLP, with running observation normalization."""

    def __init__(self, obs_dim, act_dim, hidden=(64, 64), init_log_std=-1.0):
        super().__init__()

        def mlp(out):
            layers, d = [], obs_dim
            for h in hidden:
                layers += [nn.Linear(d, h), nn.Tanh()]
                d = h
            layers.append(nn.Linear(d, out))
            return nn.Sequential(*layers)

        self.pi, self.v = mlp(act_dim), mlp(1)
        nn.init.zeros_(self.pi[-1].bias)
        self.pi[-1].weight.data.mul_(0.01)            # start with near-zero actions
        self.log_std = nn.Parameter(torch.full((act_dim,), init_log_std))
        self.register_buffer("obs_mean", torch.zeros(obs_dim))
        self.register_buffer("obs_var", torch.ones(obs_dim))
        self.register_buffer("obs_count", torch.tensor(1e-4))

    @torch.no_grad()
    def update_norm(self, x):                          # parallel Welford update, x: (B, D)
        b_mean, b_var, b = x.mean(0), x.var(0, unbiased=False), x.shape[0]
        delta, tot = b_mean - self.obs_mean, self.obs_count + b
        self.obs_mean += delta * b / tot
        self.obs_var = (self.obs_var * self.obs_count + b_var * b
                        + delta ** 2 * self.obs_count * b / tot) / tot
        self.obs_count = tot

    def norm(self, obs):
        # the std floor (0.1) matters: a nearly constant input such as cos(theta) of a balanced
        # pole would otherwise be divided by ~0 and blow up exactly when the policy gets good
        return ((obs - self.obs_mean) / torch.sqrt(self.obs_var + 1e-2)).clamp(-10, 10)

    def dist(self, obs):
        mean = self.pi(self.norm(obs))
        return torch.distributions.Normal(mean, self.log_std.exp().expand_as(mean))

    def value(self, obs):
        return self.v(self.norm(obs)).squeeze(-1)

    @torch.no_grad()
    def act(self, obs, deterministic=True):
        d = self.dist(obs)
        return (d.mean if deterministic else d.sample()).clamp(-1.0, 1.0)


class PPO:
    def __init__(self, env, cfg=None, seed=0):
        self.env, self.cfg = env, cfg or PPOConfig()
        torch.manual_seed(seed)
        obs = env.reset()
        self.device = obs.device
        self.obs_dim, self.act_dim = obs.shape[1], env.action.shape[1]
        self.model = ActorCritic(self.obs_dim, self.act_dim, self.cfg.hidden,
                                 self.cfg.init_log_std).to(self.device)
        self.opt = torch.optim.Adam(self.model.parameters(), lr=self.cfg.lr)
        self._actor_params = list(self.model.pi.parameters()) + [self.model.log_std]
        self.obs = obs.clone()

    @torch.no_grad()
    def collect(self):
        """One rollout: T env steps in all N worlds at once. Returns (T, N, ...) tensors."""
        T, N, g = self.cfg.n_steps, self.env.nworld, self.cfg.gamma
        buf = {k: torch.zeros((T, N) + s, device=self.device) for k, s in
               [("obs", (self.obs_dim,)), ("act", (self.act_dim,)), ("logp", ()), ("val", ()),
                ("rew", ()), ("done", ())]}
        for t in range(T):
            dist = self.model.dist(self.obs)
            a = dist.sample()
            buf["obs"][t], buf["act"][t] = self.obs, a
            buf["logp"][t] = dist.log_prob(a).sum(-1)
            buf["val"][t] = self.model.value(self.obs)
            obs, rew, term, trunc = self.env.step(a.clamp(-1.0, 1.0))
            # time limit: the episode did NOT fail, so bootstrap its value. torch.where, not
            # `if trunc.any():` (a Python bool of a device tensor = a host sync every step), and
            # not `* trunc.float()` (NaN * 0 = NaN would leak from a diverged world's row).
            boot = torch.where(trunc, self.model.value(self.env.final_obs), torch.zeros_like(rew))
            buf["rew"][t] = rew + g * boot
            buf["done"][t] = (term | trunc).float()   # cut GAE at every episode boundary
            self.obs = obs.clone()                    # the view changes on the next step
        buf["last_val"] = self.model.value(self.obs)
        return buf

    @torch.no_grad()
    def gae(self, buf):
        """Generalized advantage estimation, backwards in time, all worlds in parallel."""
        T, g, lam = self.cfg.n_steps, self.cfg.gamma, self.cfg.lam
        adv = torch.zeros_like(buf["rew"])
        next_adv, next_val = torch.zeros_like(buf["last_val"]), buf["last_val"]
        for t in reversed(range(T)):
            keep = 1.0 - buf["done"][t]                     # 0 where an episode ended at t
            delta = buf["rew"][t] + g * next_val * keep - buf["val"][t]
            next_adv = delta + g * lam * keep * next_adv
            adv[t] = next_adv
            next_val = buf["val"][t]
        return adv, adv + buf["val"]                        # advantages, value targets

    def update(self, buf, adv, ret):
        """Clipped-surrogate PPO: `epochs` passes over shuffled minibatches of the T*N samples."""
        c = self.cfg
        flat = {k: buf[k].reshape((-1,) + buf[k].shape[2:]) for k in ("obs", "act", "logp")}
        adv, ret = adv.reshape(-1), ret.reshape(-1)
        adv = (adv - adv.mean()) / (adv.std() + 1e-8)
        n = adv.shape[0]
        mb = max(1, n // c.minibatches)
        for _ in range(c.epochs):
            perm = torch.randperm(n, device=self.device)
            for i in range(0, n, mb):
                idx = perm[i:i + mb]
                dist = self.model.dist(flat["obs"][idx])
                logp = dist.log_prob(flat["act"][idx]).sum(-1)
                ratio = (logp - flat["logp"][idx]).exp()
                a = adv[idx]
                pg = -torch.min(ratio * a, ratio.clamp(1 - c.clip, 1 + c.clip) * a).mean()
                vf = 0.5 * (self.model.value(flat["obs"][idx]) - ret[idx]).pow(2).mean()
                ent = dist.entropy().sum(-1).mean()
                loss = pg + c.vf_coef * vf - c.ent_coef * ent
                self.opt.zero_grad()
                loss.backward()
                # clip actor and critic separately: the value loss (returns ~100) would
                # otherwise dominate one global norm and freeze the policy
                nn.utils.clip_grad_norm_(self._actor_params, c.max_grad_norm)
                nn.utils.clip_grad_norm_(self.model.v.parameters(), c.max_grad_norm)
                self.opt.step()
        return {"pg_loss": pg.item(), "v_loss": vf.item(), "entropy": ent.item()}

    def train(self, iters, log=print):
        history = []
        for it in range(iters):
            t0 = time.perf_counter()
            buf = self.collect()
            adv, ret = self.gae(buf)
            info = self.update(buf, adv, ret)
            self.model.update_norm(buf["obs"].reshape(-1, self.obs_dim))   # after the update,
            # so the log-probs stored in this rollout were computed with the same normalizer
            if self.device.type == "cuda":
                torch.cuda.synchronize()
            sec = time.perf_counter() - t0
            st = self.env.episode_stats()
            row = {"iter": it, "mean_return": st["mean_return"], "mean_length": st["mean_length"],
                   "episodes": st["episodes"],
                   "steps_per_s": self.cfg.n_steps * self.env.nworld / sec, **info}
            history.append(row)
            if log:
                log(f"iter {it:3d} | mean return {row['mean_return']:8.2f} | mean length "
                    f"{row['mean_length']:6.1f} | {row['steps_per_s']:9.0f} env-steps/s")
        return history

    def save(self, path):
        torch.save({"model": self.model.state_dict(), "obs_dim": self.obs_dim,
                    "act_dim": self.act_dim, "hidden": self.cfg.hidden}, path)


def load_policy(path, device="cpu"):
    """Load a checkpoint written by PPO.save; returns an ActorCritic in eval mode."""
    ck = torch.load(path, map_location=device)
    model = ActorCritic(ck["obs_dim"], ck["act_dim"], tuple(ck["hidden"])).to(device)
    model.load_state_dict(ck["model"])
    return model.eval()
