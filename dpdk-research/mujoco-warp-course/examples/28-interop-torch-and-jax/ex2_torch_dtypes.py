"""Example 28.2 - dtypes, shapes, contiguity and streams at the Warp/torch boundary.

1. vec3 / quat / mat33 arrays become float32 tensors with trailing (3,) / (4,) / (3, 3) dims.
2. A non-contiguous torch slice: wp.from_torch keeps the strides for scalar dtypes (still a
   zero-copy view, is_contiguous False), but refuses vector dtypes whose inner dims are strided.
3. dtype mismatches: wp.from_torch maps float64 to wp.float64, and wp.copy into a float32
   MJWarp array then raises. wp.copy only compares element byte sizes, though: an int32 tensor
   (4 bytes, like float32) is copied bit for bit with no error. Convert in torch first.
4. uint32 buffers (the packed RGB of the batch renderer, Ch 27) come out as torch.uint32.
5. Streams (GPU only): Warp's default stream is a blocking stream, so it is ordered with torch's
   default stream; on a torch.cuda.Stream() (non-blocking) run Warp on that same stream.
Run: python ex2_torch_dtypes.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

try:
    import torch
except ImportError:
    torch = None
    print("skipped: torch not installed")

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4


def show(name, t):
    print(f"  {name:<11} torch {str(tuple(t.shape)):<14} {t.dtype}  contiguous={t.is_contiguous()}")


if torch is not None:
    dev = wp.device_to_torch(wp.get_device())
    mjm = mujoco.MjModel.from_xml_string(PENDULUM)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD)
    d.qpos.assign(np.tile(mjm.key_qpos[0], (NWORLD, 1)).astype(np.float32))  # "horizontal"
    mjw.forward(m, d)

    # 1. composite dtypes gain trailing dims; worlds stay the leading dim
    print("1. Warp array -> torch view")
    for name in ("qpos", "xpos", "xquat", "xmat", "cvel"):
        arr = getattr(d, name)
        print(f"  d.{name:<9} warp {arr.dtype.__name__:<20} {arr.shape}")
    for name in ("xpos", "xquat", "xmat", "cvel"):
        show(name, wp.to_torch(getattr(d, name)))
    print("  link1 xquat (w, x, y, z), 90 deg about y:", wp.to_torch(d.xquat)[0, 1].cpu().numpy())

    # 2. contiguity: a column slice of a (nworld, 3) tensor is strided
    acts = torch.arange(NWORLD * 3, dtype=torch.float32, device=dev).reshape(NWORLD, 3)
    col = acts[:, 1]
    print("2. non-contiguous slice: stride", col.stride(), "contiguous", col.is_contiguous())
    w = wp.from_torch(col)
    print("  wp.from_torch(slice): shape", w.shape, "strides (bytes)", w.strides,
          "is_contiguous", w.is_contiguous)
    ctrl = wp.zeros((NWORLD,), dtype=float)
    wp.copy(ctrl, w)  # wp.copy handles the strided source
    print("  wp.copy(strided -> contiguous) ok:", ctrl.numpy()[:4])
    pairs = acts.reshape(3, NWORLD).t()  # (nworld, 3) view whose last dim is strided
    try:
        wp.from_torch(pairs, dtype=wp.vec3)
    except RuntimeError as e:
        print("  vec3 from strided inner dim -> RuntimeError:", str(e).split(", because ")[-1])
    print("  fix: wp.from_torch(pairs.contiguous(), dtype=wp.vec3).shape =",
          wp.from_torch(pairs.contiguous(), dtype=wp.vec3).shape)

    # 3. dtype: torch float64 maps to wp.float64; MJWarp arrays are float32
    a64 = torch.ones((NWORLD, mjm.nu), dtype=torch.float64, device=dev)
    print("3. torch.float64 -> warp", wp.from_torch(a64).dtype.__name__)
    try:
        wp.copy(d.ctrl, wp.from_torch(a64))
    except RuntimeError as e:
        print("  wp.copy(d.ctrl, float64) -> RuntimeError:", e)
    a32i = torch.arange(1, NWORLD + 1, dtype=torch.int32, device=dev).reshape(NWORLD, mjm.nu)
    wp.copy(d.ctrl, wp.from_torch(a32i))   # same element size: no error, bits reinterpreted
    print("  wp.copy(d.ctrl, int32 [1 2 3 4]) -> no error, d.ctrl =",
          " ".join(f"{x:.0e}" for x in d.ctrl.numpy()[:4, 0]), "(denormals)")
    wp.copy(d.ctrl, wp.from_torch(a64.float()))
    print("  after .float():", d.ctrl.numpy()[:, 0])

    # 4. uint32 buffers (packed RGB from the batch renderer) keep their dtype
    rgb_packed = wp.zeros((NWORLD, 8), dtype=wp.uint32)
    print("4. uint32 array -> torch", wp.to_torch(rgb_packed).dtype,
          "(few torch ops support it: unpack with mjw.get_rgb first, Ch 27)")

    # 5. streams: if torch works on its own non-blocking stream, put Warp on the same stream
    if ON_GPU:
        # stream_from_torch docstring: keep Warp-owned arrays used on a non-blocking stream
        # alive until that work is done (here d lives on; nothing temporary is launched).
        side = torch.cuda.Stream()
        torch_stream = wp.stream_from_torch(side)
        with torch.cuda.stream(side), wp.ScopedStream(torch_stream):
            mjw.step(m, d)                         # Warp launches go to torch's stream...
            tip_z = wp.to_torch(d.site_xpos)[:, 0, 2].mean()   # ...so torch reads after it
        torch.cuda.current_stream().wait_stream(side)
        print(f"5. stepped on torch's stream, mean tip z = {tip_z.item():.4f}")
    else:
        print("5. skipped on CPU: streams are CUDA only (wp.stream_from_torch)")
