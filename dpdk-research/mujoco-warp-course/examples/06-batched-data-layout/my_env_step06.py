"""my_env.py, snapshot after Ch 6: helpers that later chapters extend (course plan 0.10).

Ch 6 adds make_worlds(xml, nworld). Ch 8 adds reset_done, nonfinite_reset, snapshot/restore;
Ch 9 adds describe_overflow; Ch 10 adds randomize; and so on.
"""
import mujoco
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


def make_worlds(xml, nworld, nconmax=None, njmax=None, batch_sizes=None):
    """Compile an MJCF string and create nworld parallel worlds on the default device.

    Returns (mjm, m, d): the host mujoco.MjModel, the device mjw.Model and an mjw.Data whose
    arrays all start with an nworld dimension. nconmax is per world; njmax is per world.
    batch_sizes (e.g. {"body_mass": nworld}) gives chosen Model fields their own rows.
    """
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm, batch_sizes=batch_sizes)
    d = mjw.make_data(mjm, nworld=nworld, nconmax=nconmax, njmax=njmax)
    assert d.qpos.shape == (nworld, mjm.nq), d.qpos.shape
    return mjm, m, d
