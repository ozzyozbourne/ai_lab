"""One dense layer, y = relu(W.x + b), on the Groq TSP simulator (sim_grok_1).

Shows three things about a statically scheduled machine:
  1. the cycle count is known before the run and is identical on every run;
  2. it does not depend on the data;
  3. if one instruction is issued one cycle late, the run fails, because nothing
     in the hardware waits for a late operand.

Run from the repository root:  python3 three_accelerators/experiments/groq/dense_layer.py
"""
import copy
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "..", "sim_grok_1"))

from tsp import isa  # noqa: E402
from tsp.compiler import compile_graph  # noqa: E402
from tsp.hw import Simulator  # noqa: E402
from tsp.models import m1  # noqa: E402
from tsp.params import ChipConfig  # noqa: E402
from tsp.validate import validate  # noqa: E402


def run(program, inputs):
    sim = Simulator(program)
    for name, array in inputs.items():
        sim.poke(name, array)
    trace = sim.run()
    return sim, trace


def main():
    print("== 1. Same program, three runs, two different inputs (toy chip, 12 inputs, 8 outputs)")
    config = ChipConfig.toy()
    for seed in (0, 0, 7):
        graph, inputs = m1.build(seed=seed)
        program = compile_graph(graph, config)
        sim, trace = run(program, inputs)
        ok = np.array_equal(sim.peek("y"), m1.reference(seed=seed)["y"])
        print(f"   seed {seed}: cycles={trace.n_cycles} dispatches={len(trace.dispatches)} "
              f"digest={trace.digest()[:12]} matches_numpy={ok} validator_errors={len(validate(program, trace))}")

    print("== 2. The same layer at the published geometry (320 lanes, 320 x 320 weights)")
    big = ChipConfig.isca2020()
    graph, inputs = m1.build(seed=0, n_in=320, n_out=320, lanes=320)
    program = compile_graph(graph, big)
    sim, trace = run(program, inputs)
    ok = np.array_equal(sim.peek("y"), m1.reference(seed=0, n_in=320, n_out=320, lanes=320)["y"])
    print(f"   cycles={trace.n_cycles} (barrier {big.barrier_cycles}) dispatches={len(trace.dispatches)} "
          f"matches_numpy={ok}")

    print("== 3. Issue one instruction one cycle late (toy chip)")
    graph, inputs = m1.build(seed=0)
    program = compile_graph(graph, config)
    # Find the first unit whose queue has a Nop before a data instruction, and lengthen that Nop by one cycle.
    for unit, queue in program.queues.items():
        idx = next((i for i, ins in enumerate(queue) if isinstance(ins, isa.Nop)
                    and i + 1 < len(queue) and not isinstance(queue[i + 1], isa.Nop)), None)
        if idx is None:
            continue
        late = copy.deepcopy(program)
        old = late.queues[unit][idx]
        late.queues[unit][idx] = isa.Nop(old.n + 1)
        try:
            sim, trace = run(late, inputs)
            errors = validate(late, trace)
            same = np.array_equal(sim.peek("y"), m1.reference(seed=0)["y"])
            print(f"   {unit}: Nop {old.n} -> {old.n + 1}: ran; output_correct={same}; "
                  f"validator_errors={len(errors)}" + (f"; first: {errors[0]}" if errors else ""))
        except Exception as exc:  # the simulator refuses a mistimed operand
            print(f"   {unit}: Nop {old.n} -> {old.n + 1}: {type(exc).__name__}: {str(exc)[:150]}")


if __name__ == "__main__":
    main()
