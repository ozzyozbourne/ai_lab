# Notebook spec for Chapter 28. Build with:
#   python3 tools/make_notebook.py notebooks/specs/28-interop-torch-and-jax.py
SLUG = "28-interop-torch-and-jax"
TITLE = "Ch 28 · Interop with PyTorch and JAX"

XLA_CELL = '''# JAX memory and graph settings: they must be in os.environ BEFORE the first `import jax`.
# XLA reads them once when its backend starts. If JAX was already imported in this runtime,
# use Runtime > Restart session and run this cell right after the setup cell.
import os
import sys
os.environ["XLA_FLAGS"] = "--xla_gpu_graph_min_graph_size=1"
os.environ["XLA_PYTHON_CLIENT_ALLOCATOR"] = "platform"
os.environ["XLA_PYTHON_CLIENT_PREALLOCATE"] = "false"
print("jax already imported:", "jax" in sys.modules)'''

VERSIONS = '''# Colab's preinstalled torch and JAX are used; never `pip install jax` here (it can replace the
# matched jax/jaxlib/CUDA plugin). Check what this runtime has:
import importlib.metadata as md
for dist in ("torch", "jax", "jaxlib"):
    try:
        print(dist, md.version(dist))
    except md.PackageNotFoundError:
        print(dist, "not installed")'''

EX_SETUP = '''import mujoco
import numpy as np
import torch
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

# CARTPOLE is the MJCF string defined in the Example 28.3 cell above
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
dev = wp.device_to_torch(wp.get_device())'''

EX1 = '''# Exercise 28.1: a write through the view
c = ...  # a torch view of d.ctrl
...      # write k / 10 into world k, with torch
assert np.allclose(d.ctrl.numpy()[:, 0], np.arange(NWORLD) / 10)
print("Exercise 28.1 passed")'''

SOL1 = '''c = wp.to_torch(d.ctrl)
c[:, 0] = torch.arange(NWORLD, dtype=torch.float32, device=dev) / 10
assert np.allclose(d.ctrl.numpy()[:, 0], np.arange(NWORLD) / 10)
print("Exercise 28.1 passed")'''

EX2 = '''# Exercise 28.2: make_ctrl_writer(d) copies into d.ctrl without replacing it
def make_ctrl_writer(d):
    ...

before_obj, before_ptr = d.ctrl, d.ctrl.ptr
write = make_ctrl_writer(d)
write(torch.full((NWORLD, mjm.nu), 0.5, dtype=torch.float64, device=dev))
assert d.ctrl is before_obj and d.ctrl.ptr == before_ptr
assert np.allclose(d.ctrl.numpy(), 0.5)
mjw.step(m, d)
print("Exercise 28.2 passed")'''

SOL2 = '''def make_ctrl_writer(d):
    target = d.ctrl                      # hold the array, not the attribute
    def write(actions):
        src = wp.from_torch(actions.to(torch.float32).contiguous())
        wp.copy(target, src)             # values move, the address stays
    return write

before_obj, before_ptr = d.ctrl, d.ctrl.ptr
write = make_ctrl_writer(d)
write(torch.full((NWORLD, mjm.nu), 0.5, dtype=torch.float64, device=dev))
assert d.ctrl is before_obj and d.ctrl.ptr == before_ptr
assert np.allclose(d.ctrl.numpy(), 0.5)
mjw.step(m, d)
print("Exercise 28.2 passed")'''

EX3 = '''# Exercise 28.3: sanitize awkward actions (float64 and strided)
raw = torch.linspace(-1, 1, 2 * NWORLD, dtype=torch.float64).reshape(NWORLD, 2)[:, :1]
assert not raw.is_contiguous() and raw.dtype == torch.float64
try:
    wp.copy(d.ctrl, wp.from_torch(raw))
    raise AssertionError("expected a RuntimeError")
except RuntimeError:
    pass

def to_ctrl_tensor(actions, d):
    ...

wp.copy(d.ctrl, wp.from_torch(to_ctrl_tensor(raw, d)))
assert np.allclose(d.ctrl.numpy(), raw.numpy())
print("Exercise 28.3 passed")'''

SOL3 = '''raw = torch.linspace(-1, 1, 2 * NWORLD, dtype=torch.float64).reshape(NWORLD, 2)[:, :1]

def to_ctrl_tensor(actions, d):
    return actions.to(device=dev, dtype=torch.float32).reshape(d.ctrl.shape).contiguous()

wp.copy(d.ctrl, wp.from_torch(to_ctrl_tensor(raw, d)))
assert np.allclose(d.ctrl.numpy(), raw.numpy())
print("Exercise 28.3 passed")'''

CLONE = '''# Optional: a clone of the library repository for Example 28.7 (read as text, never executed).
# Cloned to mjw_src/ so the folder name cannot shadow the installed mujoco_warp package.
import os
!git clone -q https://github.com/google-deepmind/mujoco_warp.git mjw_src && git -C mjw_src checkout -q 8f5b9f1
os.environ["MUJOCO_WARP_SRC"] = "mjw_src"'''

STRETCH = '''# Stretch: mjw.forward as a JAX op, checked against the step op (double pendulum, Euler).
import jax
from jax import numpy as jp

PEND_XML = """
<mujoco model="double_pendulum">
  <option timestep="0.01"/>
  <worldbody>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      </body>
    </body>
  </worldbody>
</mujoco>
"""
ON_GPU = wp.get_device().is_cuda
NW = 8
mode = wp.JaxCallableGraphMode.WARP if ON_GPU else wp.JaxCallableGraphMode.NONE
pm = mujoco.MjModel.from_xml_string(PEND_XML)
pw = mjw.put_model(pm)
pw.opt.graph_conditional = ON_GPU and wp.is_conditional_graph_supported()
pd = mjw.make_data(pm, nworld=NW)

def warp_forward(qpos_in: wp.array2d[wp.float32], qvel_in: wp.array2d[wp.float32],
                 qacc_out: wp.array2d[wp.float32]):
    wp.copy(pd.qpos, qpos_in); wp.copy(pd.qvel, qvel_in)
    mjw.forward(pw, pd)
    wp.copy(qacc_out, pd.qacc)

def warp_step(qpos_in: wp.array2d[wp.float32], qvel_in: wp.array2d[wp.float32],
              qpos_out: wp.array2d[wp.float32], qvel_out: wp.array2d[wp.float32]):
    wp.copy(pd.qpos, qpos_in); wp.copy(pd.qvel, qvel_in)
    mjw.step(pw, pd)
    wp.copy(qpos_out, pd.qpos); wp.copy(qvel_out, pd.qvel)

fwd = wp.jax_callable(warp_forward, num_outputs=1, graph_mode=mode,
                      output_dims={"qacc_out": (NW, pm.nv)})
stp = wp.jax_callable(warp_step, num_outputs=2, graph_mode=mode,
                      output_dims={"qpos_out": (NW, pm.nq), "qvel_out": (NW, pm.nv)})
qpos = jp.stack([jp.linspace(0.2, 1.5, NW), jp.zeros(NW)], axis=1)
qvel = jp.zeros((NW, pm.nv))
(qacc,) = fwd(qpos, qvel)
qpos1, qvel1 = stp(qpos, qvel)
err = float(jp.abs(qvel + pm.opt.timestep * qacc - qvel1).max())
print("max |qvel + h*qacc - qvel_step| =", err)
assert err < 1e-5'''

CELLS = [
    ["md", "## 0. JAX settings first\nThe setup cell above did not import JAX. The next cell puts the three XLA variables into the environment **before** anything imports JAX (Section 4 of the chapter explains each one)."],
    ["code", XLA_CELL],
    ["code", VERSIONS],
    ["md", "# Part A: PyTorch\n\n## 1. Zero-copy: one buffer, several views\n`wp.to_torch(d.qpos)` is a torch tensor over MJWarp's own buffer. The example compares data pointers, writes from torch, steps with MJWarp and reads through the same view. A `d.qpos.numpy()` snapshot is a copy and goes stale."],
    ["example", "ex1_torch_zero_copy.py", "28.1"],
    ["md", "## 2. Caveats: dtypes, shapes, contiguity, streams\nComposite Warp types become trailing dims; strided slices are fine for scalar dtypes but not for vector dtypes; float64 tensors must be converted before `wp.copy` into MJWarp; part 5 (streams) runs only on a GPU."],
    ["example", "ex2_torch_dtypes.py", "28.2"],
    ["md", "## 3. Feeding actions in\nA torch policy on CARTPOLE: observations through views made once, actions copied **into** `d.ctrl` with `wp.from_torch` + `wp.copy`. The address of `d.ctrl` never changes."],
    ["example", "ex3_torch_ctrl.py", "28.3"],
    ["md", "## Exercises 28.1-28.3 (torch)\nShared setup for the three auto-checked exercises:"],
    ["code", EX_SETUP],
    ["md", "### Exercise 28.1\nMake a torch view of `d.ctrl` and write `k / 10` into world `k` with torch only."],
    ["code", EX1],
    ["solution", SOL1, "Exercise 28.1"],
    ["md", "### Exercise 28.2\nWrite `make_ctrl_writer(d)`: it returns `write(actions)` that copies a torch tensor of any float dtype into `d.ctrl` without replacing it."],
    ["code", EX2],
    ["solution", SOL2, "Exercise 28.2"],
    ["md", "### Exercise 28.3\nThe actions are float64 **and** strided. Confirm the direct copy fails, then write `to_ctrl_tensor` so it works."],
    ["code", EX3],
    ["solution", SOL3, "Exercise 28.3"],
    ["md", "# Part B: JAX\nIf JAX fails in this runtime, Part A is unaffected. Every JAX example checks that JAX and Warp are on the same kind of device; on a Colab GPU runtime they use `graph_mode=WARP`, on a CPU-only runtime `graph_mode=NONE`.\n\n## 4. The XLA environment and a live DLPack view"],
    ["example", "ex4_jax_env_flags.py", "28.4"],
    ["md", "## 4b. `mjw.step` as a JAX op: the corrected `jax_unroll`\nA closure over `m, d` that copies in, steps and copies out, wrapped with `wp.jax_callable(..., graph_mode=..., output_dims=...)`, unrolled with `jax.lax.scan` inside `jax.jit`. The steps/s line is your own number."],
    ["example", "ex5_jax_callable.py", "28.5"],
    ["md", "## 5. A compiled control loop with rewards in JAX\nPolicy and reward in `jax.numpy`, the simulator as one op in the scan. The last line shows that `jax.grad` through the op raises (Ch 29)."],
    ["example", "ex6_jax_grad_free_loop.py", "28.6"],
    ["md", "## 6. What is stale in `contrib/jax_unroll.py`\nThe next cell clones the repository (optional; about 1 minute). Example 28.7 reads the script as text and prints the stale lines with their fixes. Without the clone it prints a skip line and then only the wheel checks."],
    ["code", CLONE],
    ["example", "ex7_stale_contrib_check.py", "28.7"],
    ["md", "## 7. The `custom_vmap` pattern\n`jax.vmap` over a per-env step becomes one call of the batched Warp op. The counter shows how often the Python Warp function ran (on a GPU in WARP mode it counts captures). The eager loop stays at 8 envs even on a GPU: in WARP mode the graph-cache key includes a `call_id`, and every eager Python call of a `jax_callable` gets a new one, so each eager 1-world call captures a new CUDA graph. A jitted function traces once and keeps one `call_id`."],
    ["example", "ex8_custom_vmap.py", "28.8"],
    ["md", "## Stretch: `mjw.forward` as a JAX op\nWrap `mjw.forward` so it maps `(qpos, qvel)` to `qacc`, wrap `mjw.step` too, and check `qvel + h * qacc == qvel_step` on the double pendulum (Euler, no damping). Then: what do the two ops share through one `d`? What does `jax.grad` do?"],
    ["code", "# your code here"],
    ["solution", STRETCH, "Stretch"],
]
