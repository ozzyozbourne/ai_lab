"""Example 30.10 - contact track, step 2: HumanoidStandEnv, the contact-rich environment.

Same architecture as CartpoleEnv (Example 30.1): one captured graph per env.step holding action
-> n_substeps x mjw.step -> reward/done kernel -> masked reset (mjw.reset_data + random joint
noise + per-episode floor-friction DR with my_env.randomize) -> observation kernel. New here:
  * buffer sizes measured by Example 30.9 (naconmax per world from the broadphase candidates,
    njmax from the worst row count, +25%) and the solver chosen there (Newton, 10 iterations);
  * overflow monitoring that survives auto-reset: reset_data CLEARS d.overflow of the worlds it
    resets, so the graph ORs d.overflow into env.overflow_seen before every reset, the device
    printf is silenced (m.opt.warn_overflow = 0) and env.overflow() decodes the sticky copy once
    per rollout with my_env.describe_overflow;
  * the contact-track dashboard in numbers: after every substep the graph keeps device-side
    running maxima of nacon (all worlds) and nefc (worst world) and sums solver_niter, and
    env.contact_stats() reads them once per rollout against naconmax / njmax;
  * observations from qpos/qvel, NOT from sensordata: sensors are evaluated inside mjw.step
    BEFORE the last integration and reset_data zeroes them (demonstrated below).
Other examples import this file: `from ex10_humanoid_env import HumanoidStandEnv`.
Run: python ex10_humanoid_env.py [--dump-json PATH]
  --dump-json PATH writes the torso height of every world per control step (page replay).
"""
import argparse
import json
import math
import pathlib
import sys
import types

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
try:
    import my_env                           # notebook: written by the %%writefile cell
except ImportError:
    import my_env_step30 as my_env          # examples/30-capstone-rl-at-scale/

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
NACON_PER_WORLD = 20     # Example 30.9 on CPU: 61 candidates / 4 worlds = 15.2, +25% -> 19.2
NJMAX = 43               # Example 30.9: worst 34 rows, +25%
HEIGHT_MIN = 0.8         # torso below this height = fallen (it starts at 1.28)


def humanoid_model():
    """The shipped humanoid (nq 28, nv 27, nu 21) plus three torso sensors added with MjSpec."""
    spec = mujoco.MjSpec.from_file(str(HUMANOID_PATH))
    xbody, body = mujoco.mjtObj.mjOBJ_XBODY, mujoco.mjtObj.mjOBJ_BODY   # XBODY = body frame;
    for name, kind, obj in [("torso_pos", mujoco.mjtSensor.mjSENS_FRAMEPOS, xbody),  # BODY would
                            ("torso_up", mujoco.mjtSensor.mjSENS_FRAMEZAXIS, xbody),  # be the COM
                            ("com_vel", mujoco.mjtSensor.mjSENS_SUBTREELINVEL, body)]:
        spec.add_sensor(name=name, type=kind, objtype=obj, objname="torso")
    return spec.compile()


@wp.kernel
def _apply_action(action: wp.array2d(dtype=float), ctrl: wp.array2d(dtype=float)):
    worldid, i = wp.tid()
    ctrl[worldid, i] = wp.clamp(action[worldid, i], -1.0, 1.0)


@wp.func
def _torso_up_z(qpos: wp.array2d(dtype=float), worldid: int) -> wp.vec3:
    # free joint: qpos[3:7] is the torso quaternion (w, x, y, z); return its body z axis
    w, x, y, z = qpos[worldid, 3], qpos[worldid, 4], qpos[worldid, 5], qpos[worldid, 6]
    return wp.vec3(2.0 * (x * z + w * y), 2.0 * (y * z - w * x), 1.0 - 2.0 * (x * x + y * y))


@wp.kernel
def _reward_done(
    qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
    ctrl: wp.array2d(dtype=float), max_steps: int, height_min: float,
    t: wp.array(dtype=int),
    reward: wp.array(dtype=float), terminated: wp.array(dtype=bool),
    truncated: wp.array(dtype=bool), done: wp.array(dtype=bool),
):
    worldid = wp.tid()
    steps = t[worldid] + 1
    t[worldid] = steps
    bad = bool(False)
    for i in range(qpos.shape[1]):
        if not wp.isfinite(qpos[worldid, i]):
            bad = True
    for i in range(qvel.shape[1]):
        if not wp.isfinite(qvel[worldid, i]):
            bad = True
    z = qpos[worldid, 2]
    up = _torso_up_z(qpos, worldid)
    ctrl_cost = float(0.0)
    for i in range(ctrl.shape[1]):
        ctrl_cost += ctrl[worldid, i] * ctrl[worldid, i]
    term = bad or z < height_min
    trunc = (not term) and steps >= max_steps
    r = float(0.0)
    if not bad:
        r = 2.0 * wp.min(z, 1.25) + up[2] - 0.01 * ctrl_cost     # height + upright - effort
    reward[worldid] = r
    terminated[worldid] = term
    truncated[worldid] = trunc
    done[worldid] = term or trunc


@wp.kernel
def _accumulate_overflow(overflow: wp.array(dtype=int), seen: wp.array(dtype=int)):
    worldid = wp.tid()
    seen[worldid] = seen[worldid] | overflow[worldid]       # before reset_data clears it


@wp.kernel
def _track_contacts(
    nacon: wp.array(dtype=int), nefc: wp.array(dtype=int), niter: wp.array(dtype=int),
    max_nacon: wp.array(dtype=int), max_nefc: wp.array(dtype=int),
    niter_sum: wp.array(dtype=int), nsub: wp.array(dtype=int),
):
    worldid = wp.tid()
    wp.atomic_max(max_nefc, 0, nefc[worldid])      # rows of the worst world
    wp.atomic_add(niter_sum, 0, niter[worldid])
    if worldid == 0:
        wp.atomic_max(max_nacon, 0, nacon[0])      # nacon counts contacts of ALL worlds
        nsub[0] = nsub[0] + 1


@wp.kernel
def _init_noise(
    seed: wp.array(dtype=int), episode: wp.array(dtype=int), reset: wp.array(dtype=bool),
    noise: float, qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
):
    worldid = wp.tid()
    if not reset[worldid]:
        return
    rng = wp.rand_init(seed[0] + 1, worldid * 7919 + episode[worldid] * 104729)
    for i in range(7, qpos.shape[1]):              # joints only; the free joint keeps qpos0
        qpos[worldid, i] = qpos[worldid, i] + wp.randf(rng, -noise, noise)
    for i in range(qvel.shape[1]):
        qvel[worldid, i] = wp.randf(rng, -noise, noise)


@wp.kernel
def _observe(
    qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
    done: wp.array(dtype=bool), reward: wp.array(dtype=float), t: wp.array(dtype=int),
    obs: wp.array2d(dtype=float), final_obs: wp.array2d(dtype=float), write_final: int,
    ep_return: wp.array(dtype=float), last_return: wp.array(dtype=float),
    last_length: wp.array(dtype=int), n_finished: wp.array(dtype=int),
):
    worldid = wp.tid()
    out = obs
    if write_final != 0:
        out = final_obs
    nq, nv = qpos.shape[1], qvel.shape[1]
    if write_final != 0:                           # a diverged world: zeros, never NaN,
        bad = bool(False)                          # so a NaN cannot reach the learner
        for i in range(nq):
            if not wp.isfinite(qpos[worldid, i]):
                bad = True
        for i in range(nv):
            if not wp.isfinite(qvel[worldid, i]):
                bad = True
        if bad:
            for i in range(final_obs.shape[1]):
                final_obs[worldid, i] = 0.0
            return
    up = _torso_up_z(qpos, worldid)
    out[worldid, 0] = qpos[worldid, 2]             # torso height
    out[worldid, 1] = up[0]
    out[worldid, 2] = up[1]
    out[worldid, 3] = up[2]
    for i in range(7, nq):                         # 21 joint angles
        out[worldid, i - 3] = qpos[worldid, i]
    for i in range(nv):                            # 27 velocities, scaled to O(1)
        out[worldid, nq - 3 + i] = 0.1 * qvel[worldid, i]
    if write_final != 0:
        return
    ret = ep_return[worldid] + reward[worldid]
    if done[worldid]:
        last_return[worldid] = ret
        last_length[worldid] = t[worldid]
        n_finished[worldid] = n_finished[worldid] + 1
        ret = 0.0
        t[worldid] = 0
    ep_return[worldid] = ret


class HumanoidStandEnv:
    """nworld humanoids that must keep standing; same interface as CartpoleEnv."""

    def __init__(self, nworld, backend="torch", n_substeps=4, max_steps=500, seed=0,
                 friction_range=(0.4, 1.0), noise=0.05, use_graph=True):
        self.nworld, self.n_substeps, self.max_steps = nworld, n_substeps, max_steps
        self.friction_range, self.noise = friction_range, noise
        self.mjm = humanoid_model()
        self.mjm.opt.solver = mujoco.mjtSolver.mjSOL_NEWTON          # Example 30.9 sweep
        self.mjm.opt.cone = mujoco.mjtCone.mjCONE_PYRAMIDAL
        self.mjm.opt.iterations = 10
        self.dt = n_substeps * float(self.mjm.opt.timestep)          # 0.02 s
        self.m = mjw.put_model(self.mjm, batch_sizes={"geom_friction": nworld})
        self.m.opt.warn_overflow = 0      # no device printf: the env decodes the bits itself
        self.d = mjw.make_data(self.mjm, nworld=nworld, njmax=NJMAX,
                               naconmax=math.ceil(NACON_PER_WORLD * nworld))
        self.obs_dim = 4 + (self.mjm.nq - 7) + self.mjm.nv            # 52
        f32 = dict(dtype=float)
        self.action = wp.zeros((nworld, self.mjm.nu), **f32)
        self.obs_wp = wp.zeros((nworld, self.obs_dim), **f32)
        self.final_obs_wp = wp.zeros((nworld, self.obs_dim), **f32)
        self.reward_wp = wp.zeros(nworld, **f32)
        self.terminated_wp = wp.zeros(nworld, dtype=bool)
        self.truncated_wp = wp.zeros(nworld, dtype=bool)
        self.done = wp.zeros(nworld, dtype=bool)
        self.t = wp.zeros(nworld, dtype=int)
        self.episode = wp.zeros(nworld, dtype=int)
        self.seed = wp.array([seed], dtype=int)
        self.ep_return = wp.zeros(nworld, **f32)
        self.last_return = wp.zeros(nworld, **f32)
        self.last_length = wp.zeros(nworld, dtype=int)
        self.n_finished = wp.zeros(nworld, dtype=int)
        self.overflow_seen = wp.zeros(nworld, dtype=int)
        self.stats = {k: wp.zeros(1, dtype=int) for k in ("max_nacon", "max_nefc", "niter_sum", "nsub")}
        self._all = wp.ones(nworld, dtype=bool)
        self.backend, self.graph, self.use_graph = backend, None, use_graph
        if backend == "torch":
            self.obs, self.final_obs = wp.to_torch(self.obs_wp), wp.to_torch(self.final_obs_wp)
            self.reward = wp.to_torch(self.reward_wp)
            self.terminated = wp.to_torch(self.terminated_wp)
            self.truncated = wp.to_torch(self.truncated_wp)
            self._action_t = wp.to_torch(self.action)
        else:
            self.obs, self.final_obs, self.reward = self.obs_wp, self.final_obs_wp, self.reward_wp
            self.terminated, self.truncated = self.terminated_wp, self.truncated_wp

    def _observe(self, mask, final=False):
        wp.launch(_observe, dim=self.nworld,
                  inputs=[self.d.qpos, self.d.qvel, mask, self.reward_wp, self.t],
                  outputs=[self.obs_wp, self.final_obs_wp, int(final), self.ep_return,
                           self.last_return, self.last_length, self.n_finished])

    def _reset_where(self, mask):
        mjw.reset_data(self.m, self.d, reset=mask)
        wp.launch(_init_noise, dim=self.nworld,
                  inputs=[self.seed, self.episode, mask, self.noise],
                  outputs=[self.d.qpos, self.d.qvel])
        lo, hi = self.friction_range                 # Ch 10 helper; also bumps episode[w]
        my_env.randomize(self.m, self.seed, self.episode, mask, lo, hi)

    def _step_device(self):
        wp.launch(_apply_action, dim=(self.nworld, self.mjm.nu), inputs=[self.action],
                  outputs=[self.d.ctrl])
        s = self.stats
        for _ in range(self.n_substeps):
            mjw.step(self.m, self.d)
            wp.launch(_track_contacts, dim=self.nworld,
                      inputs=[self.d.nacon, self.d.nefc, self.d.solver_niter],
                      outputs=[s["max_nacon"], s["max_nefc"], s["niter_sum"], s["nsub"]])
        wp.launch(_reward_done, dim=self.nworld,
                  inputs=[self.d.qpos, self.d.qvel, self.d.ctrl, self.max_steps, HEIGHT_MIN,
                          self.t],
                  outputs=[self.reward_wp, self.terminated_wp, self.truncated_wp, self.done])
        self._observe(self.done, final=True)        # the observation each episode ended in
        wp.launch(_accumulate_overflow, dim=self.nworld, inputs=[self.d.overflow],
                  outputs=[self.overflow_seen])
        self._reset_where(self.done)
        self._observe(self.done)

    def reset(self):
        if self.use_graph and self.graph is None:
            self._step_device()                      # warm-up compile
            if my_env.needs_conditional_fallback() and self.m.opt.graph_conditional:
                self.m.opt.graph_conditional = False
            with wp.ScopedCapture() as cap:
                self._step_device()
            self.graph = cap.graph
        self._reset_where(self._all)
        self.reward_wp.zero_()
        self.done.zero_()
        self._observe(self.done)
        for a in (self.t, self.ep_return, self.last_return, self.last_length, self.n_finished,
                  self.overflow_seen, *self.stats.values()):
            a.zero_()
        return self.obs

    def step(self, action):
        if self.backend == "torch":
            self._action_t.copy_(action.reshape(self.nworld, self.mjm.nu))
        else:
            wp.copy(self.action, action)
        if self.graph is not None:
            wp.capture_launch(self.graph)
        else:
            self._step_device()
        return self.obs, self.reward, self.terminated, self.truncated

    def episode_stats(self):
        n = self.n_finished.numpy()
        have = n > 0
        if not have.any():
            return {"episodes": 0, "mean_return": float("nan"), "mean_length": float("nan")}
        return {"episodes": int(n.sum()),
                "mean_return": float(self.last_return.numpy()[have].mean()),
                "mean_length": float(self.last_length.numpy()[have].mean())}

    def overflow(self, clear=True):
        """Decode every overflow bit any world raised since the last call (one host sync)."""
        seen = wp.clone(self.overflow_seen)
        wp.launch(_accumulate_overflow, dim=self.nworld, inputs=[self.d.overflow], outputs=[seen])
        text = my_env.describe_overflow(types.SimpleNamespace(overflow=seen))
        if clear:
            self.overflow_seen.zero_()
        return text

    def contact_stats(self, clear=True):
        """Worst nacon and nefc and the mean solver_niter over all substeps since the last call."""
        v = {k: int(a.numpy()[0]) for k, a in self.stats.items()}
        if clear:
            for a in self.stats.values():
                a.zero_()                           # contents only: the graph keeps its arrays
        mean_niter = v["niter_sum"] / max(1, v["nsub"] * self.nworld)
        return {"max_nacon": v["max_nacon"], "naconmax": self.d.naconmax,
                "max_nefc": v["max_nefc"], "njmax": self.d.njmax, "mean_niter": mean_niter,
                "text": f"max nacon {v['max_nacon']}/{self.d.naconmax}, max nefc "
                        f"{v['max_nefc']}/{self.d.njmax}, mean niter {mean_niter:.2f}"}


if __name__ == "__main__":
    np.set_printoptions(precision=3, suppress=True)
    parser = argparse.ArgumentParser()
    parser.add_argument("--dump-json", default=None)
    args, _ = parser.parse_known_args()
    ON_GPU = wp.get_device().is_cuda
    NWORLD = 1024 if ON_GPU else 4
    env = HumanoidStandEnv(NWORLD, backend="warp", seed=0)
    obs = env.reset()
    print("device:", wp.get_device(), "| nworld:", NWORLD, f"| naconmax {env.d.naconmax}, "
          f"njmax {env.d.njmax} | solver Newton, pyramidal, 10 iterations")
    print("obs shape:", obs.shape, "| action shape:", env.action.shape,
          f"| control period {env.dt:.2f} s")
    print("floor friction per world:", env.m.geom_friction.numpy()[:, 0, 0].round(4))
    act = wp.zeros((NWORLD, env.mjm.nu), dtype=float)       # zero torque: it will slump
    obs, rew, term, trunc = env.step(act)
    print("one step of rewards:", rew.numpy())
    heights = [env.d.qpos.numpy()[:, 2].round(3).tolist()]
    for _ in range(149):                                    # 3 s with zero actions
        env.step(act)
        heights.append(env.d.qpos.numpy()[:, 2].round(3).tolist())   # demo only: host read
    st = env.episode_stats()
    print(f"after 3 s of zero torque: {st['episodes']} falls, mean episode length "
          f"{st['mean_length']:.1f} steps, episodes per world {env.n_finished.numpy()}")
    print("overflow seen during the episodes:", env.overflow().replace("\n", "; "))
    print("contact budget during the episodes:", env.contact_stats()["text"])

    # why the observations come from qpos and not from sensordata
    sl = my_env.sensor_slices(env.mjm)
    print("sensor slices:", sl)
    adr = sl["torso_pos"][0] + 2                            # z of the torso_pos sensor
    m2, d2 = env.m, mjw.make_data(env.mjm, nworld=NWORLD, njmax=NJMAX,
                                  naconmax=math.ceil(NACON_PER_WORLD * NWORLD))
    d2.qvel.assign(np.tile(np.r_[0.0, 0.0, -1.0, np.zeros(env.mjm.nv - 3)], (NWORLD, 1)))
    mjw.step(m2, d2)                                        # torso moving down at 1 m/s
    print(f"after one mjw.step: torso z from qpos {d2.qpos.numpy()[0, 2]:.4f}, from sensordata "
          f"{d2.sensordata.numpy()[0, adr]:.4f} (= z before this step's integration)")
    mjw.reset_data(m2, d2)
    print("after reset_data: sensordata torso_pos =", d2.sensordata.numpy()[0, :3],
          "(zero until the next forward/step)")
    if args.dump_json:
        with open(args.dump_json, "w") as f:
            json.dump({"nworld": NWORLD, "dt": 2 * env.dt, "kind": "height", "zmin": 0.0,
                       "zmax": 1.4, "frames": heights[::2]},   # dt: one frame per 2 steps
                      f, separators=(",", ":"))
        print("wrote", args.dump_json, len(heights[::2]), "frames")
