#!/usr/bin/env python3
"""Compile, run, check and draw the milestone models.

    python run_milestones.py                 # M1, M2, M3 on the toy chip -> out/
    python run_milestones.py --models m1     # one model
    python run_milestones.py --paper-m1      # also M1 at 320x320 on the paper-scale chip
    python run_milestones.py --json          # machine-readable summary on stdout (used by the tests)

For each model: compile -> run twice -> validate the schedule -> compare with the
references -> write the timeline, the program listing and the trace.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

import numpy as np

from tsp.compiler import compile as tsp_compile
from tsp.config import ChipConfig
from tsp.hw import run_program
from tsp.models import ALL as MODELS
from tsp.reference import evaluate, evaluate_plain
from tsp.validate import validate
from tsp.viz import write_timeline

# Tolerance against the plain float64 reference, which does not model F16/F32 rounding (plan section 9).
PLAIN_RTOL = 2e-2  # not a machine parameter: test tolerance
PLAIN_ATOL = 2e-2  # not a machine parameter: test tolerance

TITLES = {
    "m1": "M1: y = relu(W·x + b)",
    "m2": "M2: two-layer MLP",
    "m3": "M3: one transformer decode step",
}


def listing_digest(program) -> str:
    return hashlib.sha256(program.listing().encode()).hexdigest()


def run_one(name: str, config: ChipConfig, model_kwargs: dict | None = None) -> dict:
    """Compile and run one model; return everything the callers need. Raises on any failed check."""
    graph, feeds = MODELS[name](**(model_kwargs or {}))
    program = tsp_compile(graph, config)
    first = run_program(program, feeds, config)
    second = run_program(program, feeds, config)
    report = validate(program, first.trace, config)

    exact = evaluate(graph, feeds, program.tile_len)
    plain = evaluate_plain(graph, feeds)
    outputs = {}
    for out_name, got in first.outputs.items():
        want = exact[out_name]
        ref = np.asarray(plain[out_name], dtype=np.float64)
        is_float = got.dtype.kind == "f"
        outputs[out_name] = {
            "dtype": str(got.dtype),
            "n": int(got.shape[0]),
            "bit_exact": bool(got.dtype == want.dtype and got.tobytes() == want.tobytes()),
            "max_abs_diff_vs_plain": float(np.max(np.abs(got.astype(np.float64) - ref))),
            "matches_plain": bool(np.allclose(got.astype(np.float64), ref, rtol=PLAIN_RTOL, atol=PLAIN_ATOL)
                                  if is_float else np.array_equal(got.astype(np.int64), ref.astype(np.int64))),
        }
    trace = first.trace
    return {
        "name": name,
        "graph": graph,
        "feeds": feeds,
        "program": program,
        "trace": trace,
        "result": first,
        "report": report,
        "summary": {
            "model": name,
            "chip": config.name,
            "config_fingerprint": config.fingerprint(),
            "n_cycles": trace.n_cycles,
            "n_cycles_last_superlane": trace.n_cycles + config.superlanes - 1,   # L-G16
            "n_instructions": program.n_instructions(),
            "n_events": len(trace.events),
            "listing_sha256": listing_digest(program),
            "trace_sha256": trace.digest(),
            "second_run_identical": bool(second.trace.to_json() == trace.to_json()
                                         and second.trace.n_cycles == trace.n_cycles),
            "validation_ok": bool(report.ok),
            "validation": {c.name: {"passed": bool(c.passed), "checked": int(c.checked)} for c in report.checks},
            "outputs": outputs,
        },
    }


def all_ok(summary: dict) -> bool:
    return (summary["validation_ok"] and summary["second_run_identical"]
            and all(o["bit_exact"] and o["matches_plain"] for o in summary["outputs"].values()))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", nargs="+", default=list(MODELS), choices=list(MODELS))
    ap.add_argument("--out", default="out", help="output directory")
    ap.add_argument("--paper-m1", action="store_true", help="also run M1 at 320x320 on the paper-scale chip")
    ap.add_argument("--json", action="store_true", help="print only a JSON summary; write no files")
    args = ap.parse_args(argv)

    jobs = [(m, ChipConfig.toy(), None, m) for m in args.models]
    if args.paper_m1:
        paper = ChipConfig.paper()
        jobs.append(("m1", paper, {"n_in": paper.lanes, "n_out": paper.lanes}, "m1_paper"))

    out = pathlib.Path(args.out)
    summaries, ok = {}, True
    for name, config, kwargs, label in jobs:
        r = run_one(name, config, kwargs)
        s = r["summary"]
        summaries[label] = s
        ok = ok and all_ok(s)
        if args.json:
            continue
        out.mkdir(parents=True, exist_ok=True)
        (out / f"{label}.program.txt").write_text(r["program"].listing())
        (out / f"{label}.trace.json").write_text(r["trace"].to_json())
        if label in TITLES:
            write_timeline(out / f"{label}_timeline.html", r["trace"], config, TITLES[label])
        ns = config.cycles_to_seconds(s["n_cycles"]) * 1e9  # not a machine parameter: seconds -> nanoseconds
        print(f"== {label} on chip '{config.name}'")
        print(f"   cycles: {s['n_cycles']}  (last superlane done at {s['n_cycles_last_superlane']}; "
              f"{ns:.0f} ns if one cycle took 1/{config.clock_hz / 1e6:.0f} MHz - a unit conversion, "
              f"not a prediction: the latencies are assumed)")
        print(f"   instructions: {s['n_instructions']}   trace events: {s['n_events']}")
        print(f"   two runs identical: {s['second_run_identical']}   trace sha256: {s['trace_sha256'][:16]}")
        print("   schedule validation: " + ", ".join(
            f"{k} {'ok' if v['passed'] else 'FAIL'} ({v['checked']})" for k, v in s["validation"].items()))
        for o, v in s["outputs"].items():
            print(f"   output {o} [{v['dtype']} x {v['n']}]: bit-exact vs reference: {v['bit_exact']}; "
                  f"max |diff| vs plain float64 NumPy: {v['max_abs_diff_vs_plain']:.3g} "
                  f"({'ok' if v['matches_plain'] else 'FAIL'})")
        if not r["report"].ok:
            print(r["report"].summary())
    if args.json:
        print(json.dumps(summaries, sort_keys=True))
    else:
        (out / "summary.json").write_text(json.dumps(summaries, sort_keys=True, indent=1) + "\n")
        print(("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED") + f" - files in {out}/")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
