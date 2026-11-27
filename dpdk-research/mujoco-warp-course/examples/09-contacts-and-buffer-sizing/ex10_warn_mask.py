"""Example 9.10 - silence one warning with m.opt.warn_overflow, and see that the bit is still set.

The overflow warnings are wp.printf calls inside kernels: C-level output, buffered apart from
Python's print. flush_device_prints() pushes it out so the order on screen is the real order.
warn_overflow is read through wp.static, so each new value compiles new kernel variants.
Run: python ex10_warn_mask.py
"""
import ctypes
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


def flush_device_prints():
    """Wait for the device, then flush C stdio so wp.printf text appears before our next line."""
    wp.synchronize()
    sys.stdout.flush()
    try:
        ctypes.CDLL(None).fflush(None)         # Linux/macOS; harmless to skip elsewhere
    except (OSError, AttributeError):
        pass


BOXES = "".join(f'<body pos="{0.25 * i} 0 0.09"><freejoint/>'
                f'<geom type="box" size=".1 .1 .1"/></body>'
                for i in range(6))
SIX_BOXES = f'<mujoco><worldbody><geom type="plane" size="5 5 .1"/>{BOXES}</worldbody></mujoco>'

mjm = mujoco.MjModel.from_xml_string(SIX_BOXES)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2, nconmax=4, njmax=8)
print("default m.opt.warn_overflow =", m.opt.warn_overflow, "=", repr(mjw.OverflowType.ALL))

print("\n--- step 1: all warnings on")
flush_device_prints()
mjw.step(m, d)
flush_device_prints()

m.opt.warn_overflow &= ~mjw.OverflowType.NEFC      # new static value -> new kernel variants
print("\n--- step 2: NEFC silenced, warn_overflow =", int(m.opt.warn_overflow))
flush_device_prints()
mjw.step(m, d)
flush_device_prints()
print("bits per world:", [mjw.OverflowType(int(b)).name for b in d.overflow.numpy()])
print("NEFC still recorded in world 0:", bool(d.overflow.numpy()[0] & mjw.OverflowType.NEFC))

m.opt.warn_overflow = 0                            # silence everything (bool False works too)
print("\n--- step 3: warn_overflow = 0, nothing printed")
flush_device_prints()
mjw.step(m, d)
flush_device_prints()
print("raw d.overflow:", d.overflow.numpy(), "(sticky until reset_data)")
