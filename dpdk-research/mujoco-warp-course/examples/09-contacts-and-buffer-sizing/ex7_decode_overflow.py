"""Example 9.7 - describe_overflow(d): decode d.overflow by looping over mjw.OverflowType.

The catalogue of bits is generated from the enum (never a hand-written list), so new bits in a
later release show up automatically. Three worlds share a tiny pool; world 2 starts with its
boxes in the air. The function is added to the running project, my_env.py.
Run: python ex7_decode_overflow.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


def describe_overflow(d, max_worlds=8):
    """Decode d.overflow: "none", or one line per flagged world plus a world count per bit."""
    ov = d.overflow.numpy()
    if not ov.any():
        return "none"
    lines = []
    flagged = np.nonzero(ov)[0]
    for w in flagged[:max_worlds]:
        names = [bit.name for bit in mjw.OverflowType if ov[w] & bit]   # single-bit members only
        lines.append(f"world {w}: " + " | ".join(names))
    if len(flagged) > max_worlds:
        lines.append(f"... and {len(flagged) - max_worlds} more flagged worlds")
    counts = [f"{bit.name} x{int(np.count_nonzero(ov & bit))}" for bit in mjw.OverflowType
              if (ov & bit).any()]
    lines.append("worlds per bit: " + ", ".join(counts))
    return "\n".join(lines)


print("OverflowType catalogue (generated from the enum):")
for bit in mjw.OverflowType:          # Python >= 3.11 iterates single-bit members: no NONE, no ALL
    print(f"  1 << {int(bit).bit_length() - 1:2d} = {int(bit):5d}  {bit.name}")
print(f"  ALL = {int(mjw.OverflowType.ALL)}")

BOXES = "".join(f'<body pos="{0.25 * i} 0 0.09"><freejoint/>'
                f'<geom type="box" size=".1 .1 .1"/></body>'
                for i in range(6))
SIX_BOXES = f'<mujoco><worldbody><geom type="plane" size="5 5 .1"/>{BOXES}</worldbody></mujoco>'

NWORLD = 3
mjm = mujoco.MjModel.from_xml_string(SIX_BOXES)
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0

d = mjw.make_data(mjm, nworld=NWORLD, nconmax=48, njmax=128)
mjw.step(m, d)
print("\nwell sized:", describe_overflow(d))

d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=8)
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[2, 2::7] += 1.0                  # world 2: all six boxes start 1 m higher (no contacts)
d.qpos.assign(qpos)
mjw.step(m, d)
print("\nundersized, raw d.overflow:", d.overflow.numpy(), " nefc:", d.nefc.numpy())
print(describe_overflow(d))
mjw.reset_data(m, d)                  # the only thing that clears the sticky bits
print("\nafter reset_data:", describe_overflow(d))
