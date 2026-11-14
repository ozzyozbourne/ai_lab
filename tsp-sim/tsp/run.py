"""Run the milestones end to end.

    python -m tsp.run m1|m2|m3|all [--out DIR]

For each milestone this builds the graph, compiles it, simulates the program,
validates the trace, compares the outputs with the NumPy references and writes
<DIR>/<m>_timeline.html, <m>_trace.json and <m>_program.asm.
The exit status is non-zero if any check fails.
"""

import argparse
import os
import sys

import numpy as np

from . import asm
from .compiler import compile_graph
from .hw import Simulator
from .models import m1, m2, m3
from .params import ChipConfig
from .reference import evaluate
from .validate import validate
from .viz import render_timeline

MILESTONES = {
    "m1": (m1, "M1: y = relu(W.x + b)", True),
    "m2": (m2, "M2: two-layer MLP", True),
    "m3": (m3, "M3: one simplified transformer decode step", False),
}
# Tolerance against the independent NumPy reference for floating-point models (plan 5.3).
FLOAT_RTOL = 2e-3  # not-a-parameter: test tolerance, see plan.md section 5.3
FLOAT_ATOL = 2e-3  # not-a-parameter: test tolerance, see plan.md section 5.3


def run_one(key, out_dir):
    """Run one milestone.  Returns a list of failure messages (empty = pass)."""
    module, title, exact = MILESTONES[key]
    config = ChipConfig.toy()
    graph, inputs = module.build()
    program = compile_graph(graph, config)
    sim = Simulator(program)
    for name, array in inputs.items():
        sim.poke(name, array)
    trace = sim.run()

    failures = [f"validate: {msg}" for msg in validate(program, trace)]
    spec = evaluate(graph, inputs)
    independent = module.reference()
    for name in graph.outputs:
        got = sim.peek(name)
        if not np.array_equal(got, spec[name]):
            failures.append(f"{name}: differs from the bit-exact graph interpreter")
        if exact:
            if not np.array_equal(got, independent[name]):
                failures.append(f"{name}: differs from the NumPy reference")
        elif not np.allclose(got, independent[name], rtol=FLOAT_RTOL, atol=FLOAT_ATOL):
            failures.append(f"{name}: outside tolerance of the NumPy reference")

    os.makedirs(out_dir, exist_ok=True)
    render_timeline(program, trace, title, os.path.join(out_dir, f"{key}_timeline.html"))
    with open(os.path.join(out_dir, f"{key}_trace.json"), "w") as f:
        f.write(trace.to_json())
    with open(os.path.join(out_dir, f"{key}_program.asm"), "w") as f:
        f.write(asm.disassemble(program))

    wall = trace.n_cycles + config.tiles - 1
    print(f"{title}")
    print(f"  cycles: {trace.n_cycles} (of which {config.barrier_cycles} are the start-up barrier)")
    ns = wall / config.clock_hz * 1e9  # not-a-parameter: seconds to nanoseconds
    print(f"  wall-clock at the ledger T17 clock: {ns:.1f} ns")
    print(f"  instructions dispatched: {len(trace.dispatches)}, units used: {len(program.queues)}")
    print(f"  trace digest: {trace.digest()}")
    print(f"  result: {'PASS' if not failures else 'FAIL'}")
    for msg in failures:
        print(f"    {msg}")
    return failures


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("milestone", choices=sorted(MILESTONES) + ["all"])
    parser.add_argument("--out", default="timelines")
    args = parser.parse_args(argv)
    keys = sorted(MILESTONES) if args.milestone == "all" else [args.milestone]
    failed = False
    for key in keys:
        failed = bool(run_one(key, args.out)) or failed
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
