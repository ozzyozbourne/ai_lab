"""Example 10.9 - re-randomize friction on the device at episode resets (graph friendly).

A Warp kernel writes new sliding frictions into m.geom_friction IN PLACE, one random stream per
(seed, world, episode) from wp.rand_init / wp.randf. Nothing is replaced and nothing is copied
from the host, so the same code can live inside a captured CUDA graph. The seed is a device
array: a graph stores array pointers, so a replay reads the seed's CURRENT value. (A plain
Python int would be frozen into the graph at capture time.) This is my_env.randomize.
Run: python ex9_rerandomize_kernel.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

SLOPE = """
<mujoco model="slope">
  <option timestep="0.005"/>
  <worldbody>
    <geom name="slope" type="plane" size="5 5 .1" euler="0 30 0"/>
    <body name="box" pos="0.0505 0 0.08747" euler="0 30 0">
      <freejoint/>
      <geom name="box" type="box" size=".1 .1 .1" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""


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


NWORLD = 4
mjm = mujoco.MjModel.from_xml_string(SLOPE)
m = mjw.put_model(mjm, batch_sizes={"geom_friction": NWORLD})
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)

seed = wp.array([7], dtype=int)
episode = wp.zeros(NWORLD, dtype=int)
all_worlds = wp.array([True] * NWORLD, dtype=bool)
some_worlds = wp.array([True, False, True, False], dtype=bool)

mu = lambda: m.geom_friction.numpy()[:, :, 0]      # (nworld, ngeom): slope and box columns
print("from the XML         mu =", mu()[:, 0])
randomize(m, seed, episode, all_worlds)
print("reset 1 (all worlds) mu =", mu()[:, 0], "| slope == box:", np.allclose(mu()[:, 0], mu()[:, 1]))
randomize(m, seed, episode, some_worlds)
mjw.reset_data(m, d, reset=some_worlds)           # physics reset of the same worlds
print("reset 2 (worlds 0, 2) mu =", mu()[:, 0], "| episodes:", episode.numpy())

# The same call inside a graph: capture once, change only the seed's CONTENT, replay.
def episode_start():
    randomize(m, seed, episode, all_worlds)
    mjw.reset_data(m, d, reset=all_worlds)
    mjw.step(m, d)

episode_start()                                    # warm up: compile every kernel first
try:
    with wp.ScopedCapture() as cap:
        episode_start()
    for s in (11, 12):
        seed.assign([s])                           # a copy into the same array, outside the graph
        wp.capture_launch(cap.graph)
        print(f"graph replay, seed {s}: mu =", mu()[:, 0])
except Exception as e:                             # older Warp CPU builds cannot capture
    print("skipped graph capture:", type(e).__name__, e)
print("device:", wp.get_device(), "| episodes:", episode.numpy())
