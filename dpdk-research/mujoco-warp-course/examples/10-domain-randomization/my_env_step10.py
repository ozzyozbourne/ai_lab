"""my_env.py - the course's running helper module, snapshot after Chapter 10.

Ch 6 added make_worlds. Ch 8 added reset_done, nonfinite_reset, snapshot and restore.
Ch 9 added describe_overflow (Example 9.7).
Ch 10 adds randomize (Example 10.9): in-place, graph-friendly friction re-randomization.
Later chapters extend this file (Ch 14 sensor_slices, Ch 24 capture_step,
Ch 26 obs/reward kernels, Ch 30 the environments).
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

__all__ = ["make_worlds", "reset_done", "nonfinite_reset", "snapshot", "restore",
           "describe_overflow", "randomize"]


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
