# Notebook spec for Chapter 8. Build with:
#   python3 tools/make_notebook.py notebooks/specs/08-resets-state-and-control.py
# AUTO_HEADER is off so the EGL ICD cell can run before the standard setup cell (plan 0.4 rule S:
# rendering notebooks write the ICD file right after choosing MUJOCO_GL, before mujoco is imported).
# The MPC demo at the end renders a video with mujoco.Renderer.
SLUG = "08-resets-state-and-control"
TITLE = "Ch 08 · Resets, State, Mocap and Control Loops"
AUTO_HEADER = False

COLAB = ("https://colab.research.google.com/github/ozzyozbourne/ai_lab/blob/master/"
         "dpdk-research/mujoco-warp-course/notebooks/08-resets-state-and-control.ipynb")

EGL_CELL = '''# Rendering notebooks only: let glvnd find the NVIDIA EGL driver (from the official
# mujoco_warp tutorial). Must run before mujoco is imported by the setup cell below.
import os
os.environ.setdefault("MUJOCO_GL", "egl")
NVIDIA_ICD_CONFIG_PATH = "/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
try:
    if not os.path.exists(NVIDIA_ICD_CONFIG_PATH):
        os.makedirs(os.path.dirname(NVIDIA_ICD_CONFIG_PATH), exist_ok=True)
        with open(NVIDIA_ICD_CONFIG_PATH, "w") as f:
            f.write('{"file_format_version": "1.0.0", '
                    '"ICD": {"library_path": "libEGL_nvidia.so.0"}}\\n')
    print("EGL ICD file:", NVIDIA_ICD_CONFIG_PATH, "| MUJOCO_GL =", os.environ["MUJOCO_GL"])
except OSError as e:
    print("could not write the EGL ICD file (fine outside Colab):", e)'''

MOCAP_TARGET = '''MOCAP_TARGET = """
<mujoco model="mocap_target">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="target" mocap="true" pos="0 0 0.5">
      <geom type="box" size=".05 .05 .05" contype="0" conaffinity="0" rgba="0 1 0 .3"/>
    </body>
    <body name="box" pos="0 0 0.5">
      <freejoint/>
      <geom name="box" type="box" size=".05 .05 .05" mass="0.5" rgba=".3 .3 1 1"/>
    </body>
  </worldbody>
  <equality><weld body1="box" body2="target" solref="0.02 1"/></equality>
</mujoco>
"""'''

EX1_SETUP = '''import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

DOMINO = """
<mujoco model="domino">
  <option timestep="0.005"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="domino" pos="0 0 0.2"><freejoint/><geom type="box" size=".05 .05 .2"/></body>
  </worldbody>
</mujoco>
"""
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(DOMINO)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
tilt = np.linspace(0.0, 0.5, NWORLD)            # initial tilt about y [rad]
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 3] = np.cos(tilt / 2)
qpos[:, 5] = np.sin(tilt / 2)
qpos[:, 2] = 0.2 * np.cos(tilt) + 0.05 * np.sin(tilt) + 0.001
d.qpos.assign(qpos)
for _ in range(300):
    mjw.step(m, d)
body = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "domino")
expect = d.xmat.numpy()[:, body, 2, 2] < np.cos(np.pi / 4)   # read BEFORE the reset

tipped = wp.zeros(NWORLD, dtype=bool)
'''
EX1_CHECK = '''
# ---- checks ----
assert expect.any() and not expect.all()
assert np.array_equal(tipped.numpy(), expect)
assert np.all(d.time.numpy()[expect] == 0.0) and np.all(d.time.numpy()[~expect] > 0.0)
print("ok")'''
EX1_SOL = '''@wp.kernel
def tipped_kernel(xmat_in: wp.array2d[wp.mat33], body: int, cos_max: float,
                  tipped_out: wp.array[bool]):
    worldid = wp.tid()
    tipped_out[worldid] = xmat_in[worldid, body][2, 2] < cos_max   # body z . world z


wp.launch(tipped_kernel, dim=NWORLD, inputs=[d.xmat, body, np.cos(np.pi / 4)], outputs=[tipped])
mjw.reset_data(m, d, reset=tipped)
'''

EX2_SETUP = '''import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

''' + MOCAP_TARGET + '''
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(MOCAP_TARGET)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
box = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")
d.eq_active.assign(np.zeros((NWORLD, 1), dtype=bool))   # start detached: the box falls
for _ in range(100):
    mjw.step(m, d)                                        # box now rests on the floor (z = 0.05)
offset = np.linspace(0.0, 0.105, NWORLD)                  # target 0 .. 10.5 cm from the box
tgt = np.zeros((NWORLD, 1, 3), dtype=np.float32)
tgt[:, 0, 0] = d.qpos.numpy()[:, 0] + offset
tgt[:, 0, 1] = d.qpos.numpy()[:, 1]
tgt[:, 0, 2] = 0.05
d.mocap_pos.assign(tgt)
mjw.forward(m, d)                                         # fresh xpos for the check
'''
EX2_CHECK = '''
# ---- checks ----
dist = np.linalg.norm(d.xpos.numpy()[:, box] - d.mocap_pos.numpy()[:, 0], axis=1)
assert np.array_equal(d.eq_active.numpy()[:, 0], dist < 0.05)
tgt[:, 0, 2] = 0.4                                        # lift every target
d.mocap_pos.assign(tgt)
for _ in range(200):
    mjw.step(m, d)
z = d.qpos.numpy()[:, 2]
assert np.all(z[dist < 0.05] > 0.3) and np.all(z[dist >= 0.05] < 0.06)
print("ok")'''
EX2_SOL = '''@wp.kernel
def attach_kernel(xpos_in: wp.array2d[wp.vec3], mocap_pos_in: wp.array2d[wp.vec3], body: int,
                  radius: float, eq_active_out: wp.array2d[bool]):
    worldid = wp.tid()
    if wp.length(xpos_in[worldid, body] - mocap_pos_in[worldid, 0]) < radius:
        eq_active_out[worldid, 0] = True


wp.launch(attach_kernel, dim=NWORLD, inputs=[d.xpos, d.mocap_pos, box, 0.05],
          outputs=[d.eq_active])
'''

MPC_DEMO = '''# Interactive MPC demo. It reuses CARTPOLE, the MPC kernels and snapshot/restore from the
# Example 8.11 cell, but builds its own model, data and buffers (names end in _mpc), so it still
# works after the exercise cells below have redefined mjm, m, d and NWORLD.
# It changes two things against Example 8.11, which lets the cart drift into the +-1.8 m slider
# limit after about 1.8 s: a 1 s horizon (KNOTS_MPC = 20) and a reward that also penalises the
# cart position and velocity, so the planner sees the rail end coming.
THETA_START = 0.4   #@param {type:"slider", min:-0.5, max:0.5, step:0.05}
NITER_DEMO = 40     #@param {type:"integer"}
SEED_DEMO = 11      #@param {type:"integer"}
HOLD_MPC, KNOTS_MPC = 5, 20                  # horizon 20 knots x 5 steps = 1 s
NWORLD_MPC = 1024 if ON_GPU else 64          # sampled action sequences per iteration


@wp.kernel
def add_reward_cart(qpos_in: wp.array2d[float], qvel_in: wp.array2d[float],
                    ctrl_in: wp.array2d[float], score_out: wp.array[float]):
    worldid = wp.tid()
    x = qpos_in[worldid, 0]
    xdot = qvel_in[worldid, 0]
    u = ctrl_in[worldid, 0]
    score_out[worldid] += (wp.cos(qpos_in[worldid, 1]) - 0.2 * x * x - 0.05 * xdot * xdot
                           - 0.01 * u * u)


mjm_mpc = mujoco.MjModel.from_xml_string(CARTPOLE)
m_mpc = mjw.put_model(mjm_mpc)
d_mpc = mjw.make_data(mjm_mpc, nworld=NWORLD_MPC)
qpos_demo = np.tile(mjm_mpc.qpos0, (NWORLD_MPC, 1))
qpos_demo[:, 1] = THETA_START
d_mpc.qpos.assign(qpos_demo)
SIG_MPC = mjw.State.TIME | mjw.State.PHYSICS
buf_mpc = snapshot(m_mpc, d_mpc, mjm_mpc, SIG_MPC)
actions_mpc = wp.zeros((NWORLD_MPC, KNOTS_MPC), dtype=float)
score_mpc = wp.zeros(NWORLD_MPC, dtype=float)
best_mpc = wp.zeros(1, dtype=int)

traj = []
for it in range(NITER_DEMO):
    snapshot(m_mpc, d_mpc, mjm_mpc, SIG_MPC, buf_mpc)
    wp.launch(sample_actions, dim=(NWORLD_MPC, KNOTS_MPC), inputs=[SEED_DEMO, it], outputs=[actions_mpc])
    score_mpc.zero_()
    for k in range(KNOTS_MPC):
        wp.launch(set_ctrl, dim=NWORLD_MPC, inputs=[actions_mpc, k], outputs=[d_mpc.ctrl])
        for _ in range(HOLD_MPC):
            mjw.step(m_mpc, d_mpc)
            wp.launch(add_reward_cart, dim=NWORLD_MPC, inputs=[d_mpc.qpos, d_mpc.qvel, d_mpc.ctrl],
                      outputs=[score_mpc])
    wp.launch(argmax_world, dim=1, inputs=[score_mpc, NWORLD_MPC], outputs=[best_mpc])
    restore(m_mpc, d_mpc, mjm_mpc, buf_mpc, SIG_MPC)
    wp.launch(apply_best, dim=NWORLD_MPC, inputs=[actions_mpc, best_mpc], outputs=[d_mpc.ctrl])
    for _ in range(HOLD_MPC):
        mjw.step(m_mpc, d_mpc)
        traj.append(d_mpc.qpos.numpy()[0].copy())   # host read for the video only
traj = np.array(traj)
max_x = float(np.abs(traj[:, 0]).max())
print(f"start {THETA_START:+.2f} rad -> final pole angle {traj[-1, 1]:+.3f} rad, "
      f"cart x {traj[-1, 0]:+.3f} m, max |x| {max_x:.3f} m")
if max_x >= 1.79:
    print("WARNING: the cart reached the +-1.8 m slider limit; the planner lost track of the rail. "
          "Try a smaller THETA_START, another SEED_DEMO, or more worlds.")

# Render world 0 with the C renderer (needs EGL; the ICD cell at the top prepared it on Colab).
# Falls back to a plot of the pole angle.
try:
    import mediapy as media
    renderer = mujoco.Renderer(mjm_mpc, height=240, width=320)
    mjd = mujoco.MjData(mjm_mpc)
    video = []
    for q in traj[::2]:
        mjd.qpos[:] = q
        mujoco.mj_forward(mjm_mpc, mjd)
        renderer.update_scene(mjd, camera="front")
        video.append(renderer.render())
    media.show_video(video, fps=round(1 / (2 * mjm_mpc.opt.timestep)))
except Exception as e:
    print(f"skipped video ({type(e).__name__}: {e}); plotting the pole angle instead")
    try:
        import matplotlib.pyplot as plt
        t = np.arange(len(traj)) * mjm_mpc.opt.timestep
        plt.plot(t, traj[:, 1], label="pole angle [rad]")
        plt.plot(t, traj[:, 0], label="cart x [m]")
        plt.xlabel("t [s]"); plt.axhline(0, color="gray", lw=0.5); plt.legend()
        plt.show()
    except ImportError:
        print("skipped: matplotlib not installed")'''

CELLS = [
    ["md", f"# {TITLE}\n\n[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)]({COLAB})\n\n"
           "Companion notebook for the chapter page `chapters/08-resets-state-and-control.html` "
           "([page](../chapters/08-resets-state-and-control.html)). Pinned versions: mujoco-warp 4.0.1, "
           "warp-lang 1.19.0, mujoco-core 4.0.1.\n\n"
           "**Before you start:** Runtime > Change runtime type > select a GPU. Then run the cells top to bottom."],
    ["code", "# Check the GPU Colab gave you (this fails harmlessly on a CPU runtime).\n!nvidia-smi"],
    ["code", EGL_CELL],
    ["setup", {"render": True}],
    ["md", "## 1. reset_data: all worlds or just some\n"
           "`mjw.reset_data(m, d, reset=mask)` resets the worlds where the bool/int mask of shape "
           "`(nworld,)` is set: `qpos <- qpos0`, mocap poses from the model, `eq_active <- eq_active0`, and "
           "time, qvel, ctrl, act, `qacc_warmstart`, applied forces and sensordata zeroed. Other worlds are "
           "not touched."],
    ["example", "ex01_masked_reset.py", "8.1"],
    ["md", "## 2. reset_data_keyframe: a different start per world\n"
           "An `int` key resets all worlds (and must be in `[0, nkey)`); an int `wp.array` gives one key per "
           "world, and out-of-range ids such as `-1` leave that world untouched."],
    ["example", "ex02_keyframe_reset.py", "8.2"],
    ["md", "## 3. A reset does not recompute kinematics: call forward\n"
           "Derived quantities (`xpos`, sensors, contacts) stay stale until `mjw.forward` or the next "
           "`mjw.step`. Note also that after a step `xpos` describes the start of that step."],
    ["example", "ex03_forward_after_reset.py", "8.3"],
    ["md", "## 4. Snapshots: get_state / set_state and State signatures\n"
           "Components are packed in bit order into a `(nworld, mj_stateSize)` float array. `PHYSICS` "
           "(= QPOS|QVEL|ACT|HISTORY|PLASTIC, no TIME bit) is the MPC snapshot; add `WARMSTART` for a "
           "bitwise replay; `INTEGRATION` takes everything. **`get_state` does not check the buffer size.**\n\n"
           "The next cell writes the course's running helper module `my_env.py` as it stands after Chapter 8 "
           "(`reset_done(m, d, done, randomize=None)`, `nonfinite_reset`, `snapshot`, `restore`). The examples keep the same code inline."],
    ["writefile", "my_env.py", "examples/08-resets-state-and-control/my_env_step08.py"],
    ["example", "ex04_snapshot_restore.py", "8.4"],
    ["md", "## 5. Mocap bodies: one target per world\n"
           "`d.mocap_pos` is `(nworld, nmocap)` of `vec3`; kinematics copies it into the mocap body's pose. "
           "Here a kernel moves every world's target on its own circle and a weld drags a box along."],
    ["example", "ex05_mocap_targets.py", "8.5"],
    ["md", "## 6. Switching equality constraints per world\n"
           "`d.eq_active` is `(nworld, neq)` bool. An inactive constraint produces no efc rows in that world."],
    ["example", "ex06_eq_toggle.py", "8.6"],
    ["md", "## 7. Control in the loop: step1, policy, step2\n"
           "`step1` computes positions, velocities and their sensors; your kernel writes `d.ctrl`; `step2` "
           "does actuation, acceleration, solve and integration. **With RK4, step2 integrates with Euler.**"],
    ["example", "ex07_step1_step2_pd.py", "8.7"],
    ["md", "## 8. ctrlrange clamps on read\n"
           "The clamp happens inside `_actuator_force` on a local copy; `d.ctrl` keeps the raw value."],
    ["example", "ex08_ctrl_clamp.py", "8.8"],
    ["md", "## 9. Callbacks: m.callback.control\n"
           "A Python function `fn(m, d)` that launches kernels. It runs after the velocity sensors and before "
           "actuation, inside `forward`/`step`/`step1`. In a captured CUDA graph it runs once, at capture. "
           "Under RK4, `mjw.step` calls it 4 times per step; stages 2-4 see intermediate `qpos`/`qvel` and "
           "stage-1 `sensordata`."],
    ["example", "ex09_control_callback.py", "8.9"],
    ["md", "## 10. Device-side auto-reset with a NaN guard\n"
           "Done kernel, NaN/Inf guard (MJWarp has no `mj_checkPos`), masked reset, re-randomize, then forward (randomize before forward, so the observations match the randomized state). "
           "This example takes about 20 s on a CPU; on a GPU it runs 4096 worlds."],
    ["example", "ex10_auto_reset.py", "8.10"],
    ["md", "## 11. Worlds as parallel rollouts: random-shooting MPC\n"
           "All worlds are copies of one cartpole; each tries its own random action sequence; the best first "
           "action is applied in every world after restoring the snapshot."],
    ["example", "ex11_mpc_rollouts.py", "8.11"],
    ["md", "### Interactive MPC demo\nUse the form fields (or edit the values), re-run, and watch the video "
           "of the executed trajectory. Example 8.11 stops at 1 s, just before its cart reaches the slider "
           "limit (about 1.8 s); this demo plans 1 s ahead and also penalises the cart position and velocity, "
           "so it keeps the cart on the rail. With 64 samples on a CPU it holds the pole within about 0.3 rad "
           "for starts up to about 0.4 rad; larger tilts can still fail. On a CPU runtime the renderer is "
           "usually unavailable; the cell then plots the angle and the cart position."],
    ["code", MPC_DEMO],
    ["md", "## Exercise 8.1: reset only the worlds whose domino tipped over\n"
           "Write a kernel that fills the bool mask `tipped` on the device (tipped when "
           "`xmat[w, body][2, 2] < cos(45 deg)`), then reset exactly those worlds. Run the cell: the asserts "
           "check your work."],
    ["code", EX1_SETUP + "# ---- your code: launch a kernel that fills `tipped`, then reset those worlds ----\n"
             + EX1_CHECK],
    ["solution", EX1_SETUP + EX1_SOL + EX1_CHECK, "Exercise 8.1"],
    ["md", "## Exercise 8.2: attach the weld when the box is near the target\n"
           "Write a kernel that sets `eq_active[w, 0] = True` when the box is closer than 5 cm to the target."],
    ["code", EX2_SETUP + "# ---- your code: a kernel that sets eq_active[w, 0] = True when "
             "|box - target| < 0.05 ----\n" + EX2_CHECK],
    ["solution", EX2_SETUP + EX2_SOL + EX2_CHECK, "Exercise 8.2"],
    ["md", "## Stretch: step1/step2 vs callback, on the GPU\n"
           "Time (a) `step1` + PD kernel + `step2`, (b) `mjw.step` with `m.callback.control`, (c) version (b) "
           "captured in a CUDA graph, at `NWORLD = 4096`. Warm up once, `wp.synchronize()` before reading the "
           "clock, report world-steps/s. Check that (a) and (b) give identical `qpos` for the Euler pendulum; "
           "then switch to RK4 and explain the difference."],
    ["code", "# your timing code here"],
]
