"""The three milestone models (plan.md section 6).

Each module exposes:
    build(seed=0, ...)     -> (Graph, inputs)   the compute graph and its input values
    reference(seed=0, ...) -> {output name: array}
                              the expected outputs, computed directly with NumPy
                              from the same seed, without Graph or tsp.reference

`compile_and_run` is a small helper shared by the end-to-end tests: it
compiles a graph, pokes the inputs, runs the simulator and peeks the outputs.
"""

from . import m1, m2, m3

MILESTONES = {"m1": m1, "m2": m2, "m3": m3}


def compile_and_run(graph, inputs, config=None, record_cells=True):
    """Compile `graph`, simulate it with `inputs` and read the outputs back.

    Returns (program, trace, outputs) where outputs maps each graph output
    name to the array peeked from simulated memory after the run.
    """
    # Imported here so the models can be used without the compiler or simulator.
    from ..compiler import compile_graph
    from ..hw import Simulator
    from ..params import ChipConfig

    if config is None:
        config = ChipConfig.toy()
    program = compile_graph(graph, config)
    sim = Simulator(program, record_cells=record_cells)
    for name, array in inputs.items():
        sim.poke(name, array)
    trace = sim.run()
    outputs = {name: sim.peek(name) for name in graph.outputs}
    return program, trace, outputs
