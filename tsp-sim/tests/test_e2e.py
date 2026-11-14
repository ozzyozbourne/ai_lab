"""End-to-end and determinism tests (plan.md section 9, rows "End to end" and "Determinism")."""
import json
import os
import pathlib
import subprocess
import sys

import pytest

import run_milestones as rm
from tsp.compiler import compile as tsp_compile
from tsp.config import ChipConfig, OpTiming
from tsp.models import ALL as MODELS

ROOT = pathlib.Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "tests" / "golden_digests.json"


@pytest.fixture(scope="module")
def runs():
    cfg = ChipConfig.toy()
    return {m: rm.run_one(m, cfg) for m in MODELS}


@pytest.mark.parametrize("model", list(MODELS))
def test_milestone_correct_and_valid(runs, model):
    s = runs[model]["summary"]
    assert s["validation_ok"], runs[model]["report"].summary()
    for name, o in s["outputs"].items():
        assert o["bit_exact"], f"{model}.{name} differs from the bit-exact reference"
        assert o["matches_plain"], f"{model}.{name}: max diff vs plain reference {o['max_abs_diff_vs_plain']}"
    assert s["second_run_identical"]


def test_integer_models_match_plain_reference_exactly(runs):
    for model in ("m1", "m2"):
        for name, o in runs[model]["summary"]["outputs"].items():
            assert o["max_abs_diff_vs_plain"] == 0.0, (model, name)


def test_m1_on_paper_scale_chip():
    cfg = ChipConfig.paper()
    r = rm.run_one("m1", cfg, {"n_in": cfg.lanes, "n_out": cfg.lanes})
    assert rm.all_ok(r["summary"]), r["report"].summary()


@pytest.mark.parametrize("model", list(MODELS))
def test_perturbed_latencies_still_correct(model):
    """Different assumed latencies (ledger 7.2), including nonzero d_skew, change cycle counts, not results."""
    base = ChipConfig.toy()
    cfg = base.with_timing(READ=OpTiming(1, 3), VARITH=OpTiming(0, 2), VTRANS=OpTiming(2, 5),
                           MATVEC=OpTiming(1, 4), SXM=OpTiming(0, 2), IW=OpTiming(1, 2), WRITE=OpTiming(0, 2))
    r = rm.run_one(model, cfg)
    assert rm.all_ok(r["summary"]), r["report"].summary()
    assert r["summary"]["n_cycles"] != rm.run_one(model, base)["summary"]["n_cycles"]


@pytest.mark.parametrize("model", list(MODELS))
def test_schedule_is_data_independent(model):
    """Same shapes, different constant values -> the same program (plan 5: no pass reads tensor values)."""
    cfg = ChipConfig.toy()
    g1, _ = MODELS[model]()
    g2, _ = MODELS[model](seed=12345)
    assert any((g1.constants[k] != g2.constants[k]).any() for k in g1.constants)
    assert tsp_compile(g1, cfg).queues == tsp_compile(g2, cfg).queues


def _summary_in_subprocess(hashseed: str) -> dict:
    env = dict(os.environ, PYTHONHASHSEED=hashseed)
    out = subprocess.run([sys.executable, "run_milestones.py", "--json"], cwd=ROOT, env=env,
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


@pytest.fixture(scope="module")
def two_processes():
    return _summary_in_subprocess("1"), _summary_in_subprocess("987654")


def test_determinism_across_processes(two_processes):
    a, b = two_processes
    for model in MODELS:
        for key in ("listing_sha256", "trace_sha256", "n_cycles", "n_instructions"):
            assert a[model][key] == b[model][key], (model, key)


def test_golden_digests_for_integer_models(two_processes):
    """M1 and M2 use integer arithmetic only, so their traces are identical on every platform."""
    golden = json.loads(GOLDEN.read_text())
    a, _ = two_processes
    for model in ("m1", "m2"):
        for key in ("listing_sha256", "trace_sha256", "n_cycles"):
            assert a[model][key] == golden[model][key], (model, key)
