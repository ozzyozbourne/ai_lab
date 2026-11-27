"""my_env.py - the course's running helper module, snapshot after Chapter 26.

Ch 6 added make_worlds. Ch 8 added reset_done, nonfinite_reset, snapshot and restore.
Ch 9 added describe_overflow (Example 9.7).
Ch 10 added randomize (Example 10.9): in-place, graph-friendly friction re-randomization.
Ch 14 added sensor_slices (Example 14.3): sensor name -> (adr, dim) in d.sensordata.
Ch 24 added needs_conditional_fallback and capture_step (Example 24.4): record nsub steps (plus
optional user kernels) into one CUDA graph, with the graph-conditional fallback for CUDA < 12.4.
Ch 26 adds the RL kernels (Examples 26.1-26.3), all analyzer-style (# Model: / # Data in: / # In: /
# Out: groups, _in/_out suffixes, worldid % shape[0] for "*" Model fields) and graph-safe:
obs_columns + pack_obs (observation buffer), site_reward + accumulate (reward), and
count_userdata (a per-world counter kept in d.userdata).
Ch 30 turns this file into the environments.
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

__all__ = ["make_worlds", "reset_done", "nonfinite_reset", "snapshot", "restore",
           "describe_overflow", "randomize", "sensor_slices", "needs_conditional_fallback",
           "capture_step", "obs_columns", "pack_obs", "site_reward", "accumulate",
           "count_userdata"]


# --- Ch 6 ----------------------------------------------------------------------------------------
def make_worlds(xml, nworld, nconmax=None, njmax=None, batch_sizes=None, **sizes):
    """Compile `xml` and return (mjm, m, d) with `nworld` worlds (Ch 6 signature).

    nconmax / njmax are per world; batch_sizes (e.g. {"body_mass": nworld}) gives chosen Model
    fields their own rows (Ch 10); any other keyword (naconmax=, ...) goes to make_data.
    """
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm, batch_sizes=batch_sizes)
    d = mjw.make_data(mjm, nworld=nworld, nconmax=nconmax, njmax=njmax, **sizes)
    assert d.qpos.shape == (nworld, mjm.nq), d.qpos.shape
    return mjm, m, d


# --- Ch 8: resets --------------------------------------------------------------------------------
@wp.kernel
def _nonfinite_kernel(qpos_in: wp.array2d[float], qvel_in: wp.array2d[float],
                      done_out: wp.array[bool]):
    worldid = wp.tid()
    bad = bool(False)
    for i in range(qpos_in.shape[1]):
        if not wp.isfinite(qpos_in[worldid, i]):
            bad = True
    for i in range(qvel_in.shape[1]):
        if not wp.isfinite(qvel_in[worldid, i]):
            bad = True
    if bad:
        done_out[worldid] = True          # only ever sets flags; never clears another reason


def reset_done(m, d, done):
    """Reset the worlds whose done flag is True, then recompute derived quantities.

    `done` is a wp.array of bool with shape (nworld,). Everything stays on the device, so this
    can be captured in a CUDA graph together with mjw.step (Ch 24, Ch 26).
    """
    mjw.reset_data(m, d, reset=done)
    mjw.forward(m, d)                     # reset_data does not recompute xpos, sensors, ...


def nonfinite_reset(m, d, done):
    """OR `done` with "qpos or qvel has a NaN/Inf" (MJWarp has no mj_checkPos/mj_checkVel)."""
    wp.launch(_nonfinite_kernel, dim=d.nworld, inputs=[d.qpos, d.qvel], outputs=[done])


# --- Ch 8: state snapshots -----------------------------------------------------------------------
def snapshot(m, d, mjm, sig, buf=None):
    """Copy the state components in `sig` of every world into a (nworld, size) float array.

    Use State.PHYSICS for MPC (it includes HISTORY and PLASTIC; note it has no TIME bit),
    add State.WARMSTART for bitwise replays with contacts, State.INTEGRATION for everything.
    """
    size = mujoco.mj_stateSize(mjm, int(sig))
    if buf is None:
        buf = wp.zeros((d.nworld, size), dtype=float)
    # get_state does NOT check the size: an undersized buffer is written out of bounds.
    assert buf.shape == (d.nworld, size), f"state buffer {buf.shape} != {(d.nworld, size)}"
    mjw.get_state(m, d, buf, int(sig))
    return buf


def restore(m, d, mjm, buf, sig, active=None):
    """Write a snapshot back (only where the per-world bool mask `active` is True, if given)."""
    assert buf.shape == (d.nworld, mujoco.mj_stateSize(mjm, int(sig)))
    mjw.set_state(m, d, buf, int(sig), active)


# --- Ch 9: overflow ------------------------------------------------------------------------------
def describe_overflow(d, max_worlds=8):
    """Decode d.overflow: "none", or one line per flagged world plus a world count per bit.

    Loops over mjw.OverflowType (Python >= 3.11 iterates the single-bit members only), so bits
    added by a later MJWarp release are decoded without editing this function.
    """
    ov = d.overflow.numpy()
    if not ov.any():
        return "none"
    lines = []
    flagged = np.nonzero(ov)[0]
    for w in flagged[:max_worlds]:
        names = [bit.name for bit in mjw.OverflowType if ov[w] & bit]
        lines.append(f"world {w}: " + " | ".join(names))
    if len(flagged) > max_worlds:
        lines.append(f"... and {len(flagged) - max_worlds} more flagged worlds")
    counts = [f"{bit.name} x{int(np.count_nonzero(ov & bit))}" for bit in mjw.OverflowType
              if (ov & bit).any()]
    lines.append("worlds per bit: " + ", ".join(counts))
    return "\n".join(lines)


# --- Ch 10: domain randomization ----------------------------------------------------------------
@wp.kernel
def _randomize_friction_kernel(
    seed: wp.array(dtype=int),          # device array: a graph replays with the CURRENT value
    episode: wp.array(dtype=int),       # per-world episode counter, bumped on every re-draw
    reset: wp.array(dtype=bool),        # which worlds to re-draw (all if every entry is True)
    lo: float,
    hi: float,
    geom_friction: wp.array2d(dtype=wp.vec3),   # m.geom_friction, shape (nworld, ngeom)
):
    worldid, geomid = wp.tid()
    if not reset[worldid]:
        return
    # one random stream per (seed, world, episode): reproducible and different every episode
    rng = wp.rand_init(seed[0], worldid * 7919 + episode[worldid] * 104729)
    mu = wp.randf(rng, lo, hi)
    f = geom_friction[worldid, geomid]
    geom_friction[worldid, geomid] = wp.vec3(mu, f[1], f[2])


@wp.kernel
def _bump_episode_kernel(reset: wp.array(dtype=bool), episode: wp.array(dtype=int)):
    worldid = wp.tid()
    if reset[worldid]:
        episode[worldid] = episode[worldid] + 1


def randomize(m, seed, episode, reset, lo=0.1, hi=1.0):
    """Draw a new sliding friction in [lo, hi) for every geom of the worlds marked in reset.

    Writes m.geom_friction in place (it must already have one row per world, e.g. from
    put_model(batch_sizes={"geom_friction": nworld})), so a captured CUDA graph that contains
    this call keeps working: only array CONTENTS change, never array objects.
    seed: wp.array(dtype=int, shape=(1,)); episode: wp.array(dtype=int, shape=(nworld,));
    reset: wp.array(dtype=bool, shape=(nworld,)).
    """
    nworld = reset.shape[0]
    assert m.geom_friction.shape[0] == nworld, "batch geom_friction to nworld first"
    wp.launch(_randomize_friction_kernel, dim=(nworld, m.ngeom),
              inputs=[seed, episode, reset, lo, hi], outputs=[m.geom_friction])
    wp.launch(_bump_episode_kernel, dim=nworld, inputs=[reset], outputs=[episode])


# --- Ch 14: sensors ------------------------------------------------------------------------------
def sensor_slices(mjm):
    """Return {sensor name: (adr, dim)} so d.sensordata[:, adr:adr + dim] is that sensor.

    Unnamed sensors get the key "sensor<i>". The addresses come from the compiled MjModel
    (mjm.sensor_adr, mjm.sensor_dim) and are the same in every world.
    """
    out = {}
    for i in range(mjm.nsensor):
        name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_SENSOR, i) or f"sensor{i}"
        out[name] = (int(mjm.sensor_adr[i]), int(mjm.sensor_dim[i]))
    return out


# --- Ch 24: CUDA graphs ---------------------------------------------------------------------------
def needs_conditional_fallback(device=None):
    """True when `device` is a CUDA device whose toolkit or driver is older than CUDA 12.4.

    There, CUDA graph conditional nodes (wp.capture_while / wp.capture_if) do not exist, and
    put_model only *warns* (warp_util.check_toolkit_driver) while m.opt.graph_conditional stays True.
    On the CPU device the answer is False: Warp 1.19 records CPU graphs with APIC, which replays
    capture_while / capture_if callbacks without CUDA.
    """
    device = wp.get_device(device)
    return device.is_cuda and not wp.is_conditional_graph_supported()


def capture_step(m, d, nsub=1, post=None, verbose=True):
    """Record `nsub` calls of mjw.step(m, d), then `post(m, d)` if given, into one graph.

    Returns the graph; replay it with wp.capture_launch(graph). Capturing records the launches,
    it does not run them, so d is not advanced. The graph holds the *addresses* of every array it
    touches and the Python decisions taken while recording (integrator, solver, iteration
    counts, flags): change array contents in place (assign, fill_, copy, kernels) and recapture
    after replacing an array or changing a Python-level option (the Ch 24 knob board).
    """
    assert nsub >= 1, "nsub must be >= 1"
    device = d.qpos.device
    if needs_conditional_fallback(device) and m.opt.graph_conditional:
        m.opt.graph_conditional = False     # fixed iteration counts instead of device-side loops
        if verbose:
            print("capture_step: CUDA < 12.4, set m.opt.graph_conditional = False")
    with wp.ScopedCapture(device=device) as capture:
        for _ in range(nsub):
            mjw.step(m, d)
        if post is not None:
            post(m, d)
    return capture.graph


# --- Ch 26: observation, reward and counter kernels -----------------------------------------------
def obs_columns(mjm, sensor_names):
    """Return (nobs, cols): cols lists the d.sensordata columns of `sensor_names`, in order.

    The observation layout is [qpos (nq) | qvel (nv) | the listed sensors]. cols is a
    wp.array(dtype=int) built once on the host from sensor_slices (Ch 14), so the kernel below
    only reads device memory and can be captured in a graph.
    """
    slices = sensor_slices(mjm)
    cols = []
    for name in sensor_names:
        adr, dim = slices[name]
        cols.extend(range(adr, adr + dim))
    nobs = mjm.nq + mjm.nv + len(cols)
    return nobs, wp.array(np.array(cols, dtype=np.int32), dtype=int)


@wp.kernel
def _pack_obs_kernel(
    # Model:
    nq: int,
    nv: int,
    # Data in:
    qpos_in: wp.array2d[float],
    qvel_in: wp.array2d[float],
    sensordata_in: wp.array2d[float],
    # In:
    sensor_cols: wp.array[int],
    # Out:
    obs_out: wp.array2d[float],
):
    worldid, k = wp.tid()                 # one thread per (world, observation entry)
    if k < nq:
        obs_out[worldid, k] = qpos_in[worldid, k]
    elif k < nq + nv:
        obs_out[worldid, k] = qvel_in[worldid, k - nq]
    else:
        obs_out[worldid, k] = sensordata_in[worldid, sensor_cols[k - nq - nv]]


def pack_obs(m, d, sensor_cols, obs):
    """obs[w] = [qpos[w] | qvel[w] | sensordata[w, sensor_cols]]; obs is (nworld, nobs), preallocated."""
    assert obs.shape == (d.nworld, m.nq + m.nv + sensor_cols.shape[0]), obs.shape
    wp.launch(_pack_obs_kernel, dim=obs.shape, inputs=[m.nq, m.nv, d.qpos, d.qvel, d.sensordata,
              sensor_cols], outputs=[obs])


@wp.kernel
def _site_reward_kernel(
    # Model:
    opt_timestep: wp.array[float],
    # Data in:
    ctrl_in: wp.array2d[float],
    site_xpos_in: wp.array2d[wp.vec3],
    # In:
    siteid: int,
    target: wp.vec3,
    ctrl_weight: float,
    # Out:
    reward_out: wp.array[float],
):
    worldid = wp.tid()
    timestep = opt_timestep[worldid % opt_timestep.shape[0]]     # "*" field: maybe batched
    dist = wp.length(site_xpos_in[worldid, siteid] - target)
    ctrl_cost = float(0.0)                                      # typed: mutable in the loop
    for i in range(ctrl_in.shape[1]):
        c = ctrl_in[worldid, i]
        ctrl_cost += c * c
    reward_out[worldid] = -(dist + ctrl_weight * ctrl_cost) * timestep


def site_reward(m, d, siteid, target, ctrl_weight, reward):
    """reward[w] = -(|site_xpos[w, siteid] - target| + ctrl_weight * |ctrl[w]|^2) * timestep."""
    wp.launch(_site_reward_kernel, dim=d.nworld,
              inputs=[m.opt.timestep, d.ctrl, d.site_xpos, siteid, wp.vec3(*target), ctrl_weight],
              outputs=[reward])


@wp.kernel
def _accumulate_kernel(
    # In:
    value_in: wp.array[float],
    # Out:
    total_out: wp.array[float],
):
    worldid = wp.tid()
    total_out[worldid] += value_in[worldid]     # one thread per entry: no atomics needed


def accumulate(value, total):
    """total[w] += value[w] (episode return, running sums)."""
    wp.launch(_accumulate_kernel, dim=value.shape[0], inputs=[value], outputs=[total])


@wp.kernel
def _count_userdata_kernel(
    # In:
    col: int,
    # Data out:
    userdata_out: wp.array2d[float],
):
    worldid = wp.tid()
    userdata_out[worldid, col] += 1.0


def count_userdata(d, col=0):
    """d.userdata[:, col] += 1 in every world (needs <size nuserdata="..."/> in the MJCF).

    reset_data zeroes d.userdata, so this counts steps of the CURRENT episode; keep counters that
    must survive resets (episode numbers) in your own wp.array.
    """
    assert d.userdata.shape[1] > col, "add <size nuserdata=...> to the model"
    wp.launch(_count_userdata_kernel, dim=d.nworld, inputs=[col], outputs=[d.userdata])
