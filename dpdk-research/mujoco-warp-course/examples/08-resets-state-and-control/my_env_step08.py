"""my_env.py - the course's running helper module, snapshot after Chapter 8.

Ch 6 added make_worlds. Ch 8 adds reset_done, nonfinite_reset, snapshot and restore.
Later chapters extend this file (Ch 9 describe_overflow, Ch 10 randomize, Ch 14 sensor_slices,
Ch 24 capture_step, Ch 26 obs/reward kernels, Ch 30 the environments).
"""
import mujoco
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

__all__ = ["make_worlds", "reset_done", "nonfinite_reset", "snapshot", "restore"]


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


def reset_done(m, d, done, randomize=None):
    """Reset the worlds whose done flag is True, randomize them, then recompute derived quantities.

    `done` is a wp.array of bool with shape (nworld,). `randomize(m, d, done)`, if given, launches
    the per-episode randomization (initial velocity, targets, ...) of the done worlds. It runs
    after reset_data and before forward, so every derived quantity (xpos, cvel, velocity sensors,
    qfrc_bias, ...) matches the final state. Everything stays on the device, so this can be
    captured in a CUDA graph together with mjw.step (Ch 24, Ch 26).

    Cost: forward runs on every world on every call, even when no world is done, which is about
    one extra forward pass per step. It is unconditional so that there is no host branch to break
    graph capture; skipping it would need a conditional graph node, or reading observations after
    the next step instead.
    """
    mjw.reset_data(m, d, reset=done)
    if randomize is not None:
        randomize(m, d, done)
    mjw.forward(m, d)                     # reset_data does not recompute xpos, sensors, ...


def nonfinite_reset(m, d, done):
    """OR `done` with "qpos or qvel has a NaN/Inf" (MJWarp has no mj_checkPos/mj_checkVel)."""
    wp.launch(_nonfinite_kernel, dim=d.nworld, inputs=[d.qpos, d.qvel], outputs=[done])


# --- Ch 8: state snapshots -----------------------------------------------------------------------
def snapshot(m, d, mjm, sig, buf=None):
    """Copy the state components in `sig` of every world into a (nworld, size) float array.

    Use State.PHYSICS (+ State.TIME if anything reads d.time) for MPC (it includes HISTORY and
    PLASTIC; note it has no TIME bit),
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
