"""my_env.py - the course's running helper module, snapshot after Chapter 30.

Ch 6 added make_worlds. Ch 8 added reset_done, nonfinite_reset, snapshot and restore.
Ch 9 added describe_overflow (Example 9.7).
Ch 10 added randomize (Example 10.9): in-place, graph-friendly friction re-randomization.
Ch 14 added sensor_slices (Example 14.3): sensor name -> (adr, dim) in d.sensordata.
Ch 24 added needs_conditional_fallback and capture_step (Example 24.4): record nsub steps (plus
optional user kernels) into one CUDA graph, with the graph-conditional fallback for CUDA < 12.4.
Ch 30 adds scale_body_mass (eager mass domain randomization + set_const, Example 30.7). The two
RL environments built on top of this module live in ex1_env.py (CartpoleEnv) and
ex10_humanoid_env.py (HumanoidStandEnv).
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

__all__ = ["make_worlds", "reset_done", "nonfinite_reset", "snapshot", "restore",
           "describe_overflow", "randomize", "sensor_slices", "needs_conditional_fallback",
           "capture_step", "MASS_DERIVED", "scale_body_mass"]


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


# --- Ch 30: eager mass domain randomization -------------------------------------------------------
# derived fields that set_const recomputes from body_mass/body_inertia (Ch 10 ex5/ex6)
MASS_DERIVED = ["body_subtreemass", "body_invweight0", "dof_invweight0", "actuator_acc0"]


def scale_body_mass(mjm, m, d, body, scale):
    """Set body_mass[w, body] = scale[w] * nominal mass in every world, then run mjw.set_const.

    body_mass, body_inertia AND the derived fields in MASS_DERIVED must be batched to nworld
    (put_model(batch_sizes={...})): set_const launches over each OUTPUT's leading size, so an
    unbatched body_subtreemass would get world 0's value for every world (Ch 10 ex6).
    The inertia is scaled by the same factor, as the set_const docstring recommends. set_const
    recomputes the derived fields (body_subtreemass, dof_invweight0, actuator_acc0, ...); it
    allocates temporaries and relaunches every world, so call it EAGERLY between rollouts, never
    inside a captured graph (Ch 10 §6-§7, Ch 30 §9).
    """
    scale = np.asarray(scale, dtype=np.float32).reshape(-1)
    assert m.body_mass.shape[0] == d.nworld == scale.shape[0], "batch body_mass to nworld first"
    for name in MASS_DERIVED:
        assert getattr(m, name).shape[0] == d.nworld, f"batch {name} to nworld too"
    mass = np.tile(mjm.body_mass.astype(np.float32), (d.nworld, 1))
    inertia = np.tile(mjm.body_inertia.astype(np.float32), (d.nworld, 1, 1))
    mass[:, body] *= scale
    inertia[:, body] *= scale[:, None]
    m.body_mass.assign(mass)                      # same array objects: only contents change
    m.body_inertia.assign(inertia)
    mjw.set_const(m, d)                           # SetConstGroup.ALL (body_mass needs ALL)
