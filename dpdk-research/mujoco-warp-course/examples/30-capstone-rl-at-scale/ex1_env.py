"""Example 30.1 - CartpoleEnv: a fully on-device RL environment for thousands of worlds.

One call of env.step(action) replays ONE captured graph that does everything on the device:
  1. copy the policy's action into d.ctrl (clamped),
  2. n_substeps physics steps (mjw.step),
  3. reward / termination / truncation kernel (with a non-finite guard),
  4. masked auto-reset of the finished worlds: mjw.reset_data, a random initial state, and an
     in-graph domain-randomization kernel (motor gain, slider damping) for the NEW episode,
  5. the observation kernel and the episode bookkeeping (returns and lengths).
The host never reads a value inside the loop. backend="torch" hands out zero-copy torch tensors
(Ch 28); backend="warp" hands out the wp.arrays themselves, so the env also works without torch.
Other examples import this file: `from ex1_env import CartpoleEnv`.
Run: python ex1_env.py
"""
import pathlib
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
try:
    import my_env                           # notebook: written by the %%writefile cell
except ImportError:
    import my_env_step30 as my_env          # examples/30-capstone-rl-at-scale/

CARTPOLE = """
<mujoco model="cartpole">
  <option timestep="0.01" integrator="implicitfast"/>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="front" pos="0 -2 2.1" xyaxes="1 0 0 0 1 2"/>
    <geom name="floor" type="plane" size="20 20 .1" rgba=".75 .8 .85 1" contype="0" conaffinity="0"/>
    <geom name="rail" type="capsule" fromto="-2 0 1 2 0 1" size=".02" contype="0" conaffinity="0"/>
    <body name="cart" pos="0 0 1">
      <joint name="slider" type="slide" axis="1 0 0" range="-1.8 1.8" limited="true" damping="0.1"/>
      <geom name="cart" type="box" size=".2 .1 .05" mass="1" rgba=".15 .3 .7 1" contype="0" conaffinity="0"/>
      <body name="pole">
        <joint name="hinge" type="hinge" axis="0 1 0" damping="0.01"/>
        <geom name="pole" type="capsule" fromto="0 0 0 0 0 .6" size=".03" mass="0.1" rgba=".9 .45 .1 1"
              contype="0" conaffinity="0"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="slider" gear="10" ctrlrange="-1 1" ctrllimited="true"/></actuator>
  <sensor>
    <jointpos joint="slider"/><jointpos joint="hinge"/>
    <jointvel joint="slider"/><jointvel joint="hinge"/>
  </sensor>
</mujoco>
"""

vec10 = wp.types.vector(length=10, dtype=float)    # the dtype of m.actuator_gainprm
OBS_DIM = 5          # x, cos(theta), sin(theta), x_dot, theta_dot
ACT_DIM = 1


@wp.kernel
def _apply_action(action: wp.array2d(dtype=float), ctrl: wp.array2d(dtype=float)):
    worldid, i = wp.tid()
    ctrl[worldid, i] = wp.clamp(action[worldid, i], -1.0, 1.0)


@wp.kernel
def _reward_done(
    qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
    ctrl: wp.array2d(dtype=float),
    swingup: int, max_steps: int, x_limit: float, cos_limit: float,
    t: wp.array(dtype=int),
    reward: wp.array(dtype=float), terminated: wp.array(dtype=bool),
    truncated: wp.array(dtype=bool), done: wp.array(dtype=bool),
    final_obs: wp.array2d(dtype=float),
):
    worldid = wp.tid()
    x = qpos[worldid, 0]
    th = qpos[worldid, 1]
    xd = qvel[worldid, 0]
    thd = qvel[worldid, 1]
    a = ctrl[worldid, 0]
    steps = t[worldid] + 1
    t[worldid] = steps
    # non-finite guard: MJWarp has no mj_checkPos/mj_checkVel, so the env checks itself (Ch 8)
    bad = not (wp.isfinite(x) and wp.isfinite(th) and wp.isfinite(xd) and wp.isfinite(thd))
    c = wp.cos(th)
    term = bad or wp.abs(x) > x_limit
    if swingup == 0:
        term = term or c < cos_limit              # balance task: the pole fell
    trunc = (not term) and steps >= max_steps     # time limit: NOT a failure
    r = float(0.0)
    if not bad:
        if swingup == 0:
            r = c - 0.25 * x * x - 0.01 * a * a     # upright, centred, gentle
        else:
            # energy shaping: pole energy (normalized so upright at rest = 1) should reach 1.
            # Kept >= about -0.15 so that crashing into the rail end never pays off.
            e = (0.5 * 0.012 * thd * thd + 0.2943 * c) / 0.2943
            r = 0.5 * (1.0 + c) + 0.5 * wp.exp(-2.0 * wp.abs(e - 1.0))
            r = r - 0.05 * x * x - 0.01 * a * a
    reward[worldid] = r
    terminated[worldid] = term
    truncated[worldid] = trunc
    done[worldid] = term or trunc
    # the observation of the state the episode ENDED in (needed to bootstrap truncations)
    final_obs[worldid, 0] = x
    final_obs[worldid, 1] = c
    final_obs[worldid, 2] = wp.sin(th)
    final_obs[worldid, 3] = xd
    final_obs[worldid, 4] = thd
    if bad:
        for i in range(5):
            final_obs[worldid, i] = 0.0


@wp.kernel
def _init_and_randomize(
    seed: wp.array(dtype=int), episode: wp.array(dtype=int), reset: wp.array(dtype=bool),
    swingup: int, gain_lo: float, gain_hi: float, damp_lo: float, damp_hi: float,
    qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
    actuator_gainprm: wp.array2d(dtype=vec10),
    dof_damping: wp.array2d(dtype=float),
):
    worldid = wp.tid()
    if not reset[worldid]:
        return
    # one random stream per (seed, world, episode): reproducible, new for every episode
    rng = wp.rand_init(seed[0], worldid * 7919 + episode[worldid] * 104729)
    # random initial state (reset_data put qpos0 = upright, qvel = 0)
    qpos[worldid, 0] = wp.randf(rng, -0.2, 0.2)
    th0 = wp.randf(rng, -0.1, 0.1)
    if swingup != 0:
        th0 = th0 + wp.pi
    qpos[worldid, 1] = th0
    qvel[worldid, 0] = wp.randf(rng, -0.1, 0.1)
    qvel[worldid, 1] = wp.randf(rng, -0.1, 0.1)
    # in-graph domain randomization: fields with NO derived quantities (no set_const needed)
    g = actuator_gainprm[worldid, 0]
    g[0] = wp.randf(rng, gain_lo, gain_hi)        # motor gain (force = gain * gear * ctrl)
    actuator_gainprm[worldid, 0] = g
    dof_damping[worldid, 0] = wp.randf(rng, damp_lo, damp_hi)     # slider damping
    episode[worldid] = episode[worldid] + 1


@wp.kernel
def _observe(
    qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
    done: wp.array(dtype=bool), reward: wp.array(dtype=float), t: wp.array(dtype=int),
    obs: wp.array2d(dtype=float),
    ep_return: wp.array(dtype=float), last_return: wp.array(dtype=float),
    last_length: wp.array(dtype=int), n_finished: wp.array(dtype=int),
):
    worldid = wp.tid()
    th = qpos[worldid, 1]
    obs[worldid, 0] = qpos[worldid, 0]
    obs[worldid, 1] = wp.cos(th)
    obs[worldid, 2] = wp.sin(th)
    obs[worldid, 3] = qvel[worldid, 0]
    obs[worldid, 4] = qvel[worldid, 1]
    ret = ep_return[worldid] + reward[worldid]
    if done[worldid]:                    # bookkeeping on the device: no host sync per step
        last_return[worldid] = ret
        last_length[worldid] = t[worldid]
        n_finished[worldid] = n_finished[worldid] + 1
        ret = 0.0
        t[worldid] = 0
    ep_return[worldid] = ret


class CartpoleEnv:
    """nworld cartpoles stepped as one batch. step() is one graph replay (or eager calls).

    obs (nworld, 5), reward (nworld,), terminated / truncated (nworld,) bool, final_obs (nworld, 5).
    Finished worlds are reset INSIDE step(): the returned obs of a finished world is already the
    first observation of its next episode, and final_obs holds the observation it ended in.
    """

    def __init__(self, nworld, backend="torch", n_substeps=2, max_steps=200, seed=0,
                 swingup=False, gain_range=(0.8, 1.2), damping_range=(0.05, 0.2),
                 use_graph=True):
        self.nworld, self.n_substeps, self.max_steps = nworld, n_substeps, max_steps
        self.swingup = int(swingup)
        self.gain_range, self.damping_range = gain_range, damping_range
        self.mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
        self.dt = n_substeps * float(self.mjm.opt.timestep)          # control period [s]
        # one row per world for every field the in-graph DR kernel writes, and for the eager
        # mass DR of Example 30.7 (body_mass/body_inertia + set_const, outside the graph):
        # batch the DERIVED fields that set_const writes too, or it writes one shared row (Ch 10)
        batch = ["actuator_gainprm", "dof_damping", "body_mass", "body_inertia",
                 *my_env.MASS_DERIVED]
        self.m = mjw.put_model(self.mjm, batch_sizes={k: nworld for k in batch})
        # no contacts (contype=conaffinity=0); the only constraint rows are the 2 slider limits
        self.d = mjw.make_data(self.mjm, nworld=nworld, nconmax=0, njmax=2)
        f32 = dict(dtype=float)
        self.action = wp.zeros((nworld, ACT_DIM), **f32)
        self.obs_wp = wp.zeros((nworld, OBS_DIM), **f32)
        self.final_obs_wp = wp.zeros((nworld, OBS_DIM), **f32)
        self.reward_wp = wp.zeros(nworld, **f32)
        self.terminated_wp = wp.zeros(nworld, dtype=bool)
        self.truncated_wp = wp.zeros(nworld, dtype=bool)
        self.done = wp.zeros(nworld, dtype=bool)
        self.t = wp.zeros(nworld, dtype=int)
        self.episode = wp.zeros(nworld, dtype=int)
        self.seed = wp.array([seed], dtype=int)      # device array: graphs read its CURRENT value
        self.ep_return = wp.zeros(nworld, **f32)
        self.last_return = wp.zeros(nworld, **f32)
        self.last_length = wp.zeros(nworld, dtype=int)
        self.n_finished = wp.zeros(nworld, dtype=int)
        self._all = wp.ones(nworld, dtype=bool)
        self.backend = backend
        self.graph = None
        self.use_graph = use_graph
        self._views()

    # ---- buffers seen by the learner -----------------------------------------------------------
    def _views(self):
        if self.backend == "torch":
            import torch                                   # only needed for this backend
            self._torch = torch
            self.obs = wp.to_torch(self.obs_wp)            # zero-copy views, made once
            self.final_obs = wp.to_torch(self.final_obs_wp)
            self.reward = wp.to_torch(self.reward_wp)
            self.terminated = wp.to_torch(self.terminated_wp)
            self.truncated = wp.to_torch(self.truncated_wp)
            self._action_t = wp.to_torch(self.action)
        elif self.backend == "warp":
            self.obs, self.final_obs, self.reward = self.obs_wp, self.final_obs_wp, self.reward_wp
            self.terminated, self.truncated = self.terminated_wp, self.truncated_wp
        else:
            raise ValueError(f"backend must be 'torch' or 'warp', got {self.backend!r}")

    # ---- the device-side pieces ----------------------------------------------------------------
    def _physics(self):
        wp.launch(_apply_action, dim=(self.nworld, ACT_DIM), inputs=[self.action],
                  outputs=[self.d.ctrl])
        for _ in range(self.n_substeps):
            mjw.step(self.m, self.d)
        wp.launch(_reward_done, dim=self.nworld,
                  inputs=[self.d.qpos, self.d.qvel, self.d.ctrl, self.swingup, self.max_steps,
                          1.7, float(np.cos(0.8)), self.t],
                  outputs=[self.reward_wp, self.terminated_wp, self.truncated_wp, self.done,
                           self.final_obs_wp])

    def _reset_where(self, mask):
        mjw.reset_data(self.m, self.d, reset=mask)       # qpos0, qvel 0, time 0, ... (masked)
        g, dmp = self.gain_range, self.damping_range
        wp.launch(_init_and_randomize, dim=self.nworld,
                  inputs=[self.seed, self.episode, mask, self.swingup, g[0], g[1], dmp[0], dmp[1]],
                  outputs=[self.d.qpos, self.d.qvel, self.m.actuator_gainprm,
                           self.m.dof_damping])

    def _observe(self, mask):
        wp.launch(_observe, dim=self.nworld,
                  inputs=[self.d.qpos, self.d.qvel, mask, self.reward_wp, self.t],
                  outputs=[self.obs_wp, self.ep_return, self.last_return, self.last_length,
                           self.n_finished])

    def _step_device(self):
        self._physics()
        self._reset_where(self.done)          # auto-reset only the finished worlds
        self._observe(self.done)

    # ---- public API ------------------------------------------------------------------------------
    def reset(self):
        """Reset every world (eager; call once, it also captures the graph). Returns obs."""
        if self.use_graph and self.graph is None:
            self._step_device()               # warm-up: compile every kernel before capturing
            if my_env.needs_conditional_fallback() and self.m.opt.graph_conditional:
                self.m.opt.graph_conditional = False      # CUDA < 12.4 (Ch 24)
            with wp.ScopedCapture() as cap:   # records the launches; runs nothing
                self._step_device()
            self.graph = cap.graph
        self._reset_where(self._all)
        self.reward_wp.zero_()
        self.done.zero_()
        self._observe(self.done)              # obs of the fresh state, no bookkeeping
        for a in (self.t, self.ep_return, self.last_return, self.last_length, self.n_finished):
            a.zero_()
        return self.obs

    def step(self, action):
        """Write the action (torch tensor or wp.array, shape (nworld, 1)), advance one period."""
        if self.backend == "torch":
            self._action_t.copy_(action.reshape(self.nworld, ACT_DIM))   # into the SAME buffer
        else:
            wp.copy(self.action, action)
        if self.graph is not None:
            wp.capture_launch(self.graph)
        else:
            self._step_device()
        return self.obs, self.reward, self.terminated, self.truncated

    def episode_stats(self):
        """Host summary (one sync): finished episodes, mean return/length of the latest ones."""
        n = self.n_finished.numpy()
        have = n > 0
        ret, length = self.last_return.numpy(), self.last_length.numpy()
        if not have.any():
            return {"episodes": 0, "mean_return": float("nan"), "mean_length": float("nan")}
        return {"episodes": int(n.sum()), "mean_return": float(ret[have].mean()),
                "mean_length": float(length[have].mean())}


if __name__ == "__main__":
    np.set_printoptions(precision=3, suppress=True)
    ON_GPU = wp.get_device().is_cuda
    NWORLD = 4096 if ON_GPU else 8
    try:
        import torch
        backend = "torch"
    except ImportError:
        backend = "warp"
        print("skipped: torch not installed, using backend='warp'")

    env = CartpoleEnv(NWORLD, backend=backend, seed=0)
    obs = env.reset()                       # warms up and captures the graph
    print("device:", wp.get_device(), "| backend:", backend, "| nworld:", NWORLD)
    print("obs:", type(obs).__module__.split(".")[0], tuple(obs.shape), "| graph captured:",
          env.graph is not None, f"| control period {env.dt:.2f} s")
    if backend == "torch":
        print("obs shares memory with the wp.array:", obs.data_ptr() == env.obs_wp.ptr)
        act = torch.zeros(NWORLD, 1)
    else:
        act = wp.zeros((NWORLD, 1), dtype=float)
    print("obs world 0:", np.asarray(obs[0].tolist() if backend == "torch" else obs.numpy()[0]))
    obs, rew, term, trunc = env.step(act)
    rew_np = rew.cpu().numpy() if backend == "torch" else rew.numpy()
    print("one step of rewards:", rew_np)
    print("motor gain per world:", env.m.actuator_gainprm.numpy()[:, 0, 0])
    print("slider damping per world:", env.m.dof_damping.numpy()[:, 0])
    print("terminated:", int(np.asarray(term.tolist()).sum()), "| truncated:",
          int(np.asarray(trunc.tolist()).sum()))
    print("overflow:", my_env.describe_overflow(env.d))
