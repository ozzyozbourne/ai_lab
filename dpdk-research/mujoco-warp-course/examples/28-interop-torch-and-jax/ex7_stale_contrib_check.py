"""Example 28.7 - a static check of contrib/jax_unroll.py: find the stale lines, print the fixes.

Reads contrib/jax_unroll.py as TEXT from a clone of the mujoco_warp repository; nothing from the
clone is imported or executed. For each stale pattern it prints the line number, the line, and
the corrected course line (Example 28.5). It also checks that the claims hold for the installed
4.0.1 wheel. Skips if no clone is found.
Clone (optional): git clone https://github.com/google-deepmind/mujoco_warp.git
Run: python ex7_stale_contrib_check.py [--src PATH_TO_CLONE]   (or set MUJOCO_WARP_SRC)
"""
import argparse
import os
import pathlib
import re

import mujoco_warp as mjw
from etils import epath

parser = argparse.ArgumentParser()
parser.add_argument("--src", default=os.environ.get("MUJOCO_WARP_SRC"))
args, _ = parser.parse_known_args()

candidates = [args.src] if args.src else ["mujoco_warp", "../mujoco_warp", "/content/mujoco_warp"]
script = next((pathlib.Path(c) / "contrib/jax_unroll.py" for c in candidates
               if (pathlib.Path(c) / "contrib/jax_unroll.py").is_file()), None)

CHECKS = [  # (what is stale, regex on the line, corrected course line)
    ("model path: the repo folder is 'benchmarks' and it is not in the wheel",
     r"\.\./benchmark\b",
     'path = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"'),
    ("nconmax is per world in 4.0.1 (naconmax is the total)",
     r"nconmax\s*=\s*64\s*\*\s*NWORLDS",
     "d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=64, njmax=128)"),
    ("clears the whole Warp kernel cache at import: every run recompiles",
     r"wp\.clear_kernel_cache\(\)",
     "(deleted)"),
    ("also fragile: hard-coded 8192 instead of NWORLDS; qpos0/zero qvel drop the kick",
     r"\(8192\b",
     "jax_qpos = jp.tile(jp.array(d.qpos.numpy()[0]), (NWORLD, 1)); same for jax_qvel"),
]

if script is None:
    print("skipped: no mujoco_warp clone found (pass --src or set MUJOCO_WARP_SRC)")
else:
    lines = script.read_text().splitlines()
    print(f"checking {script} ({len(lines)} lines)")
    for what, pattern, fix in CHECKS:
        hits = [(i + 1, ln) for i, ln in enumerate(lines) if re.search(pattern, ln)]
        if not hits:
            print(f"\n[not found] {what}  (already fixed upstream?)")
            continue
        for no, ln in hits:
            print(f"\n[{what}]\n  line {no:>2}: {ln.strip()}\n  course:  {fix}")
    # Order check: XLA reads its environment once; set it before `import jax` (Example 28.4).
    first = lambda pat: next((i + 1 for i, ln in enumerate(lines) if re.search(pat, ln)), None)
    jax_line, flags_line = first(r"^\s*import jax\b"), first(r"environ\[.XLA_FLAGS.\]")
    missing = [v for v in ("XLA_PYTHON_CLIENT_ALLOCATOR", "XLA_PYTHON_CLIENT_PREALLOCATE")
               if not any(v in ln for ln in lines)]
    if jax_line and flags_line and flags_line > jax_line:
        print(f"\n[also fragile: XLA_FLAGS set after import jax; works only because the backend starts later]"
              f"\n  line {jax_line:>2}: import jax\n  line {flags_line:>2}: {lines[flags_line - 1].strip()}"
              f"\n  course:  all three XLA variables in os.environ before import jax")
    if missing:
        print("  never set:", ", ".join(missing), "(JAX may preallocate most of the GPU memory)")

# The claims, checked against the installed wheel (no clone needed):
pkg = pathlib.Path(str(epath.resource_path("mujoco_warp")))
print("\nwheel has test_data/humanoid/humanoid.xml:",
      (pkg / "test_data/humanoid/humanoid.xml").is_file(),
      "| wheel has ../benchmark/humanoid:", (pkg.parent / "benchmark/humanoid").exists())
doc = mjw.put_data.__doc__
print("put_data docstring:", " ".join(re.search(r"nconmax: (.*?)\.", doc).group(1).split()))
NWORLDS = 8192
print(f"nconmax=64*NWORLDS with NWORLDS={NWORLDS} asks for naconmax = "
      f"{64 * NWORLDS * NWORLDS:,} contacts (intended: {64 * NWORLDS:,})")
