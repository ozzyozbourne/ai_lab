"""Example 26.12 - run MJWarp's kernel analyzer on your own kernels (notebook-only).

The analyzer lives in the repository, not in the pip wheel:
contrib/kernel_analyzer/kernel_analyzer/cli.py. In the notebook a cell clones the repository
first (git clone --depth 1 --branch v4.0.1 https://github.com/google-deepmind/mujoco_warp, the
tag that matches the installed wheel); this script looks for
that clone in ./mujoco_warp (or in $MJW_REPO) and prints a skip note when it is absent.
It writes two learner files, my_kernel.py (a reward kernel with deliberate convention errors) and
my_kernel_fixed.py (the analyzer-clean version), runs
  python mujoco_warp/contrib/kernel_analyzer/kernel_analyzer/cli.py FILE --types <wheel types.py>
on each, and prints the issues (the CLI writes them to stderr, one per line, and exits 1).
Run: python ex12_kernel_analyzer.py
"""
import os
import pathlib
import subprocess
import sys

import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw  # noqa: F401  (standard import order; we only need its types.py path)
import mujoco_warp._src.types as mjw_types   # private API: used for its file path only

BAD = '''import warp as wp


@wp.kernel
def reward_bad(
    qpos: wp.array2d(dtype=float),
    body_mass: wp.array2d[float],
    reward: wp.array[float],
    scale: float = 1.0,
):
    worldid = wp.tid()
    mass = body_mass[worldid, 1]
    qpos[worldid, 0] = 0.0
    reward[worldid] = -scale * mass * qpos[worldid, 2]
'''

FIXED = '''import warp as wp


@wp.kernel
def reward_good(
    # Model:
    body_mass: wp.array2d[float],
    # Data in:
    qpos_in: wp.array2d[float],
    # In:
    scale: float,
    # Out:
    reward_out: wp.array[float],
):
    worldid = wp.tid()
    mass = body_mass[worldid % body_mass.shape[0], 1]
    reward_out[worldid] = -scale * mass * qpos_in[worldid, 2]
'''

repo = pathlib.Path(os.environ.get("MJW_REPO", "mujoco_warp"))
cli = repo / "contrib" / "kernel_analyzer" / "kernel_analyzer" / "cli.py"
types_py = mjw_types.__file__                 # check against the INSTALLED wheel's types.py
print("types.py:", pathlib.Path(types_py).name, "from the installed mujoco_warp wheel")

if not cli.exists():
    print(f"skipped: {cli} not found (clone the repository first; see the notebook cell)")
else:
    pathlib.Path("my_kernel.py").write_text(BAD)
    pathlib.Path("my_kernel_fixed.py").write_text(FIXED)
    for name in ("my_kernel.py", "my_kernel_fixed.py"):
        r = subprocess.run([sys.executable, str(cli), name, "--types", types_py],
                           capture_output=True, text=True)
        issues = [ln for ln in r.stderr.splitlines() if ln.startswith(name + ":")]
        print(f"\n{name}: exit code {r.returncode}, {len(issues)} issue(s)")
        for ln in issues:
            print(" ", ln)
