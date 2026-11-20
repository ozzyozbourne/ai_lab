#!/usr/bin/env python3
"""Run every example program in the book and print a pass/fail table.

Usage:
    python3 code/run_all.py            # all chapters
    python3 code/run_all.py ch05 ch06  # selected chapters

Conventions (see plan.md): each chapter's runnable examples are code/chNN/*.py.
Files whose names start with "_" (helpers) or "test_" (pytest files) are not run directly.
Every program must finish in under 60 seconds with no network access and no API keys.
"""
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent


def main(argv: list[str]) -> int:
    chapters = sorted(p for p in ROOT.glob("ch[0-9][0-9]") if p.is_dir())
    if argv:
        chapters = [p for p in chapters if p.name in argv]
    failures = 0
    rows = []
    for ch in chapters:
        for script in sorted(ch.glob("*.py")):
            if script.name.startswith(("_", "test_")):
                continue
            t0 = time.perf_counter()
            try:
                proc = subprocess.run([sys.executable, script.name], cwd=ch, capture_output=True,
                                      text=True, timeout=120)
                ok = proc.returncode == 0
                detail = "" if ok else (proc.stderr.strip().splitlines() or ["(no stderr)"])[-1]
            except subprocess.TimeoutExpired:
                ok, detail = False, "timeout"
            dt = time.perf_counter() - t0
            failures += not ok
            rows.append((f"{ch.name}/{script.name}", "ok" if ok else "FAIL", f"{dt:5.1f}s", detail))
    width = max((len(r[0]) for r in rows), default=10)
    for name, status, dt, detail in rows:
        print(f"{name:<{width}}  {status:<4}  {dt}  {detail}")
    print(f"\n{len(rows) - failures}/{len(rows)} programs passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
