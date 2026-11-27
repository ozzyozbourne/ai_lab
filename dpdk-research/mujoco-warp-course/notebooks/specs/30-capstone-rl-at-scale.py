# Notebook spec for Chapter 30. Build with:
#   python3 tools/make_notebook.py notebooks/specs/30-capstone-rl-at-scale.py
SLUG = "30-capstone-rl-at-scale"
TITLE = "Ch 30 · Capstone: GPU-Native Reinforcement Learning at Scale"
SETUP = {"render": True}

STUB1 = r'''
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

@wp.kernel
def action_rate_penalty(action: wp.array2d(dtype=float), prev_action: wp.array2d(dtype=float),
                        k: float, reward: wp.array(dtype=float)):
    worldid = wp.tid()
    # your code here

N, A, K = 64, 3, 0.05
rng = np.random.default_rng(0)
a_prev = rng.uniform(-1, 1, (N, A)).astype(np.float32)
a = rng.uniform(-1, 1, (N, A)).astype(np.float32)
r0 = rng.normal(size=N).astype(np.float32)
action, prev, reward = wp.array(a), wp.array(a_prev), wp.array(r0)
wp.launch(action_rate_penalty, dim=N, inputs=[action, prev, K], outputs=[reward])
expected = r0 - K * ((a - a_prev) ** 2).sum(1)
assert np.allclose(reward.numpy(), expected, atol=1e-6)
assert np.array_equal(prev.numpy(), a), "prev_action must now hold this step's action"
print("action-rate penalty matches NumPy")
'''

SOL1 = r'''
@wp.kernel
def action_rate_penalty(action: wp.array2d(dtype=float), prev_action: wp.array2d(dtype=float),
                        k: float, reward: wp.array(dtype=float)):
    worldid = wp.tid()
    s = float(0.0)
    for i in range(action.shape[1]):
        da = action[worldid, i] - prev_action[worldid, i]
        s += da * da
        prev_action[worldid, i] = action[worldid, i]   # remember for the next step
    reward[worldid] = reward[worldid] - k * s

N, A, K = 64, 3, 0.05
rng = np.random.default_rng(0)
a_prev = rng.uniform(-1, 1, (N, A)).astype(np.float32)
a = rng.uniform(-1, 1, (N, A)).astype(np.float32)
r0 = rng.normal(size=N).astype(np.float32)
action, prev, reward = wp.array(a), wp.array(a_prev), wp.array(r0)
wp.launch(action_rate_penalty, dim=N, inputs=[action, prev, K], outputs=[reward])
expected = r0 - K * ((a - a_prev) ** 2).sum(1)
assert np.allclose(reward.numpy(), expected, atol=1e-6)
assert np.array_equal(prev.numpy(), a)
print("action-rate penalty matches NumPy")
'''

STUB2 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from ex1_env import CartpoleEnv, my_env     # the %%writefile cells provide both files

env = CartpoleEnv(8, backend="warp", seed=5)
env.reset()
act = wp.array(np.full((8, 1), 1.0, np.float32))
resets = 0
for _ in range(100):
    before = env.m.actuator_gainprm.numpy()[:, 0, 0].copy()
    env.step(act)
    done = env.done.numpy()
    after = env.m.actuator_gainprm.numpy()[:, 0, 0]
    # your asserts: running worlds unchanged, reset worlds changed (gain and damping)
    resets += int(done.sum())
assert resets > 0
# your code: scale the pole mass by np.linspace(1, 4, 8) and assert the cart's subtree mass
# equals 1.0 + 0.1 * scale in every world
'''

SOL2 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from ex1_env import CartpoleEnv, my_env

env = CartpoleEnv(8, backend="warp", seed=5)
env.reset()
act = wp.array(np.full((8, 1), 1.0, np.float32))      # full push: episodes end quickly
resets = 0
for _ in range(100):
    before = env.m.actuator_gainprm.numpy()[:, 0, 0].copy()
    damp_before = env.m.dof_damping.numpy()[:, 0].copy()
    env.step(act)
    done = env.done.numpy()
    after = env.m.actuator_gainprm.numpy()[:, 0, 0]
    damp_after = env.m.dof_damping.numpy()[:, 0]
    assert np.array_equal(after[~done], before[~done]), "running worlds must keep their gain"
    assert np.array_equal(damp_after[~done], damp_before[~done])
    assert (after[done] != before[done]).all(), "a reset world draws a new gain"
    resets += int(done.sum())
assert resets > 0
pole = mujoco.mj_name2id(env.mjm, mujoco.mjtObj.mjOBJ_BODY, "pole")
cart = mujoco.mj_name2id(env.mjm, mujoco.mjtObj.mjOBJ_BODY, "cart")
my_env.scale_body_mass(env.mjm, env.m, env.d, pole, np.linspace(1, 4, 8))
sub = env.m.body_subtreemass.numpy()[:, cart]
assert np.allclose(sub, 1.0 + 0.1 * np.linspace(1, 4, 8), atol=1e-5), sub
print(f"in-graph DR touched only reset worlds ({resets} resets); subtree mass {sub[:3]}")
'''

CELLS = [
    ["md", "This notebook is the companion of Chapter 30. Run the setup cell first (GPU runtime). "
           "The next cells write the helper files the examples import: `my_env.py` (the running project, "
           "snapshot after Chapter 30), `ex1_env.py` (CartpoleEnv), `ppo_reference.py` (the reference PPO) "
           "and `ex10_humanoid_env.py` (HumanoidStandEnv). Every number printed below is your own; the page "
           "only quotes CPU numbers from the course's verification box.\n\n"
           "**Budgets** (targets, not measurements: the course was verified on a CPU). Warm-up track "
           "(Examples 30.1-30.8): sized for about 10-20 minutes on a Colab GPU, most of it "
           "Example 30.6. Contact track (Examples 30.9-30.11): its own 20-30 minutes, most of it Example 30.11. "
           "Stretch sections (30.12, 30.13) are optional."],
    ["writefile", "my_env.py", "examples/30-capstone-rl-at-scale/my_env_step30.py"],
    ["writefile", "ex1_env.py", "examples/30-capstone-rl-at-scale/ex1_env.py"],
    ["writefile", "ppo_reference.py", "examples/30-capstone-rl-at-scale/ppo_reference.py"],
    ["writefile", "ex10_humanoid_env.py", "examples/30-capstone-rl-at-scale/ex10_humanoid_env.py"],
    ["md", "## Warm-up track\n### 4. Implementing CartpoleEnv\nOne `env.step(action)` = copy the action in, then "
           "replay ONE captured graph: action -> substeps -> reward/done -> masked reset + in-graph DR -> "
           "observation. The cell below runs the same file as the `%%writefile ex1_env.py` cell, as a script."],
    ["example", "ex1_env.py", "30.1"],
    ["md", "Eager launches versus one graph replay per control step (your own numbers):"],
    ["example", "ex2_random_policy.py", "30.2"],
    ["md", "Test the reward, termination and observation kernels against NumPy before training anything:"],
    ["example", "ex3_reward_check.py", "30.3"],
    ["md", "### 5. Asynchronous episodes and auto-reset\nTermination (failure) and truncation (time limit) are "
           "reported separately; every world restarts on its own schedule."],
    ["example", "ex4_episodes.py", "30.4"],
    ["md", "### 6. A baseline first: evolution strategies\nNumPy ES with a linear policy, one candidate per world. "
           "Saves `policy_es.npz`."],
    ["example", "ex5_es_baseline.py", "30.5"],
    ["md", "### 8. Training with the reference PPO\nOn a GPU this trains 150 iterations of 4096 worlds and saves "
           "`policy_ppo.pt` (checkpoint). Watch the mean length climb to the 200-step time limit."],
    ["example", "ex6_ppo_train.py", "30.6"],
    ["md", "**CPU fallback.** Without a GPU, the cell above ran only 3 iterations, so its checkpoint is untrained. "
           "The next cells write the same file and run it with 40 iterations of 128 worlds (a usable policy; about "
           "10 s on the course's CPU dev box). Skip them on a GPU runtime."],
    ["writefile", "ex6_ppo_train.py", "examples/30-capstone-rl-at-scale/ex6_ppo_train.py"],
    ["code", "# CPU fallback: retrain with 40 iterations of 128 worlds (overwrites policy_ppo.pt)\n"
             "!python ex6_ppo_train.py --iters 40 --nworld 128"],
    ["md", "### 9. Evaluation under randomized physics\nPole mass from 0.5x to 32x, applied eagerly with "
           "`my_env.scale_body_mass` (assign + `mjw.set_const`) between evaluation rollouts. Run it once with the "
           "PPO checkpoint (default) and once with `--policy es` to compare. Without a GPU, Example 30.6 "
           "runs only 3 iterations and its checkpoint is untrained (0% everywhere): for a usable "
           "policy, run the CPU-fallback cell above (40 iterations of 128 worlds) before this cell."],
    ["example", "ex7_evaluate.py", "30.7"],
    ["md", "The same evaluation with the ES policy (the file is written first so it can run as a script):"],
    ["writefile", "ex7_evaluate.py", "examples/30-capstone-rl-at-scale/ex7_evaluate.py"],
    ["code", "!python ex7_evaluate.py --policy es"],
    ["md", "Render the policy: `mujoco.Renderer` (EGL on Colab) for world 0 as a video, and the MJWarp batch "
           "renderer for a 4x4 grid of all worlds."],
    ["example", "ex8_render_policy.py", "30.8"],
    ["code", "try:\n    import mediapy as media\n    media.show_video(media.read_video(\"ex8_world0.mp4\"), fps=12)\n"
             "except Exception as e:\n    print(\"skipped video:\", type(e).__name__, e)"],
    ["md", "## Contact track\n### 10. HumanoidStandEnv\nStep 1: measure contacts, rows and broadphase candidates "
           "with random actions, add 25%, and sweep the solver."],
    ["example", "ex9_humanoid_sizing.py", "30.9"],
    ["md", "Step 2: the environment (sizes from step 1; overflow monitoring that survives auto-reset; "
           "observations from qpos, not sensordata; a per-rollout contact budget). The cell below runs the file the "
           "`%%writefile ex10_humanoid_env.py` cell wrote. If your GPU run of 30.9 printed different worst cases, "
           "edit `NACON_PER_WORLD` and `NJMAX` in that `%%writefile` cell, re-run it, then re-run the cell below."],
    ["code", "# Example 30.10 - ex10_humanoid_env.py (runs the file written by the %%writefile cell above)\n"
             "!python ex10_humanoid_env.py"],
    ["md", "Step 3: train (GPU budget 20-30 minutes). The overflow column decodes every bit any world raised "
           "during that rollout; the contact column shows the worst `nacon` and `nefc` against their budgets and "
           "the mean solver iterations."],
    ["code", "# If you edited and re-wrote ex10_humanoid_env.py, load the new version before training.\n"
             "import importlib, sys\n"
             "if \"ex10_humanoid_env\" in sys.modules:\n"
             "    importlib.reload(sys.modules[\"ex10_humanoid_env\"])\n"
             "    print(\"reloaded ex10_humanoid_env\")"],
    ["example", "ex11_humanoid_train.py", "30.11"],
    ["md", "## 11. Stretch sections (optional)\n<details><summary>Scaling study and swing-up</summary>\n\n"
           "Example 30.12 keeps the whole ES rollout on the device (the policy is a Warp kernel) and compares "
           "nworld values under a fixed wall-clock budget. Example 30.13 is the swing-up variant with an "
           "energy-shaped reward.\n</details>\n\n"
           "They do not run by default: \"Run all\" only writes the two files. Set `RUN_STRETCH = True` in the cell "
           "after them to run both (Example 30.12 alone takes up to 60 s per nworld row on a GPU)."],
    ["writefile", "ex12_scaling.py", "examples/30-capstone-rl-at-scale/ex12_scaling.py"],
    ["writefile", "ex13_swingup.py", "examples/30-capstone-rl-at-scale/ex13_swingup.py"],
    ["code", "RUN_STRETCH = False   # set to True to run Examples 30.12 and 30.13\n"
             "import subprocess, sys\n"
             "if RUN_STRETCH:\n"
             "    for f in (\"ex12_scaling.py\", \"ex13_swingup.py\"):\n"
             "        print(f\"--- {f}\", flush=True)\n"
             "        r = subprocess.run([sys.executable, f], capture_output=True, text=True)\n"
             "        print(r.stdout, r.stderr)\n"
             "else:\n"
             "    print(\"stretch examples skipped (RUN_STRETCH = False)\")"],
    ["md", "## Exercise 30.1: an action-rate penalty kernel\nSubtract `k * sum((a - a_prev)**2)` from each "
           "world's reward and store the current action in `prev_action`. Check against NumPy."],
    ["code", STUB1],
    ["solution", SOL1, "Exercise 30.1"],
    ["md", "## Exercise 30.2: where each kind of DR acts\nAssert that the in-graph DR changes gain and damping "
           "only in worlds reset during that step, and that eager mass DR changes `body_subtreemass` per world."],
    ["code", STUB2],
    ["solution", SOL2, "Exercise 30.2"],
    ["md", "## Stretch: learn to stand from depth images\nAdd 64x64 depth observations to `HumanoidStandEnv` "
           "(render context with `render_depth=True`; `forward` + `refit_bvh` + `render` + `get_depth` inside the "
           "graph after the reset), give PPO a small CNN, and compare mean episode length against wall-clock time "
           "with and without pixels."],
]
