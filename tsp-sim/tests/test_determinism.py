"""Determinism (plan.md section 5.3): identical programs, traces and outputs.

For each milestone, two independent compile-and-run passes in this process
must give a byte-identical Program.to_json(), equal Trace.digest(), equal
n_cycles and equal outputs.  The same fingerprint must come out of fresh
interpreters started with PYTHONHASHSEED = 0, 1 and 2.
"""

import hashlib
import json
import os
import pathlib
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
MILESTONES = ["m1", "m2", "m3"]

SNIPPET = """
import hashlib, json, sys
from tsp.models import MILESTONES, compile_and_run
module = MILESTONES[sys.argv[1]]
graph, inputs = module.build(0)
program, trace, outputs = compile_and_run(graph, inputs)
print(json.dumps({
    "program": hashlib.sha256(program.to_json().encode()).hexdigest(),
    "trace": trace.digest(),
    "n_cycles": trace.n_cycles,
    "outputs": {k: v.tobytes().hex() for k, v in sorted(outputs.items())},
}, sort_keys=True))
"""


def require_stack():
    """Skip unless the compiler, the simulator and the assembler are importable."""
    compiler = pytest.importorskip("tsp.compiler")
    if not hasattr(compiler, "compile_graph"):
        pytest.skip("tsp.compiler.compile_graph is not available yet")
    pytest.importorskip("tsp.hw")
    pytest.importorskip("tsp.asm")


def _run(key):
    from tsp.models import MILESTONES as MODELS, compile_and_run

    graph, inputs = MODELS[key].build(0)
    return compile_and_run(graph, inputs)


def _fingerprint(program, trace, outputs):
    return {
        "program": hashlib.sha256(program.to_json().encode()).hexdigest(),
        "trace": trace.digest(),
        "n_cycles": trace.n_cycles,
        "outputs": {k: v.tobytes().hex() for k, v in sorted(outputs.items())},
    }


@pytest.mark.parametrize("key", MILESTONES)
def test_two_passes_identical(key):
    require_stack()
    p1, t1, o1 = _run(key)
    p2, t2, o2 = _run(key)
    assert p1.to_json() == p2.to_json()
    assert t1.digest() == t2.digest()
    assert t1.n_cycles == t2.n_cycles
    assert sorted(o1) == sorted(o2)
    for name in o1:
        assert o1[name].dtype == o2[name].dtype
        assert o1[name].tobytes() == o2[name].tobytes()


@pytest.mark.parametrize("key", MILESTONES)
def test_same_across_hash_seeds(key):
    require_stack()
    here = _fingerprint(*_run(key))
    for seed in ("0", "1", "2"):
        env = dict(os.environ, PYTHONHASHSEED=seed)
        res = subprocess.run([sys.executable, "-c", SNIPPET, key], cwd=ROOT, env=env,
                             capture_output=True, text=True, timeout=600)
        assert res.returncode == 0, res.stderr
        got = json.loads(res.stdout.strip().splitlines()[-1])
        assert got == here, f"PYTHONHASHSEED={seed} gave a different run"
