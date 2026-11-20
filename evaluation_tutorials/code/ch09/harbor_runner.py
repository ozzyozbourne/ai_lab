"""Run a Harbor-format task without Docker: Oracle, null agent, and two cheating agents.

Chapter 9, section 9.5 (Agent and environment harnesses). Builds a task directory in the layout
Harbor documents (instruction.md, task.toml, environment/, solution/solve.sh, tests/test.sh), then
plays the harness: set up a fresh workspace per trial, run an "agent" (a shell script) with a
timeout, then run the verifier, which must write logs/verifier/reward.txt. Docker is replaced by a
temporary directory and environment variables APP_DIR / LOGS_DIR / TESTS_DIR (the real paths are
/app, /logs/verifier and /tests inside the container).
Run:  python3 code/ch09/harbor_runner.py   (needs bash; no Docker, no network)
Expected key output: oracle 1, null 0 under both verifiers; the empty-file agent beats the lazy
verifier (1) but not the strict one (0); the test-peeking agent scores 1 when tests are visible to
the agent and 0 when the verifier runs separately.
"""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tempfile

TASK_FILES = {
    "instruction.md": "Reverse the order of the lines in /app/input.txt and write them to /app/output.txt.\n",
    "task.toml": ('[task]\nname = "demo/reverse-lines"\nversion = "1.0"\n\n[agent]\ntimeout_sec = 10\n\n'
                  '[verifier]\ntimeout_sec = 10\nenvironment_mode = "separate"\n'),
    "environment/Dockerfile": "FROM ubuntu:24.04\nWORKDIR /app\nCOPY input.txt /app/input.txt\n",
    "environment/input.txt": "alpha\nbravo\ncharlie\ndelta\n",
    "solution/solve.sh": '#!/bin/bash\ntac "$APP_DIR/input.txt" > "$APP_DIR/output.txt"\n',
    "tests/expected.txt": "delta\ncharlie\nbravo\nalpha\n",
    "tests/test.sh": ('#!/bin/bash\n# strict verifier: compare content (the pattern in Harbor\'s create-task skill)\n'
                      'if diff -q "$APP_DIR/output.txt" "$TESTS_DIR/expected.txt" > /dev/null 2>&1; then\n'
                      '  echo 1 > "$LOGS_DIR/reward.txt"\nelse\n  echo 0 > "$LOGS_DIR/reward.txt"\nfi\n'),
    "tests/test_lazy.sh": ('#!/bin/bash\n# lazy verifier: only checks that the file exists\n'
                           'if [ -f "$APP_DIR/output.txt" ]; then echo 1 > "$LOGS_DIR/reward.txt"; '
                           'else echo 0 > "$LOGS_DIR/reward.txt"; fi\n'),
}

AGENTS = {
    "oracle": None,                                            # runs solution/solve.sh
    "null": "true\n",                                          # does nothing
    "empty-file": 'touch "$APP_DIR/output.txt"\n',             # games an existence check
    "test-peeker": 'cp "$TESTS_DIR/expected.txt" "$APP_DIR/output.txt" 2>/dev/null || true\n',
}


def read_toml(path: pathlib.Path) -> dict:
    """Tiny TOML subset reader ([section] + key = "str" | int) so Python 3.10 works too."""
    out: dict = {}
    sec = out
    for line in path.read_text().splitlines():
        line = line.split("#")[0].strip()
        if line.startswith("["):
            sec = out.setdefault(line.strip("[]"), {})
        elif "=" in line:
            k, v = (x.strip() for x in line.split("=", 1))
            sec[k] = v.strip('"') if v.startswith('"') else int(v)
    return out


def make_task(root: pathlib.Path) -> pathlib.Path:
    task = root / "reverse-lines"
    for rel, text in TASK_FILES.items():
        p = task / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return task


def run_trial(task: pathlib.Path, agent: str, verifier: str, tests_visible: bool) -> str:
    cfg = read_toml(task / "task.toml")
    with tempfile.TemporaryDirectory() as ws_str:               # fresh workspace per trial
        ws = pathlib.Path(ws_str)
        app, logs, tests = ws / "app", ws / "logs" / "verifier", ws / "tests"
        app.mkdir()
        logs.mkdir(parents=True)
        shutil.copy(task / "environment" / "input.txt", app / "input.txt")
        env = {**os.environ, "APP_DIR": str(app), "LOGS_DIR": str(logs), "TESTS_DIR": str(tests)}
        if tests_visible:                                       # the leak: tests baked into the image
            shutil.copytree(task / "tests", tests)
        script = (task / "solution" / "solve.sh").read_text() if AGENTS[agent] is None else AGENTS[agent]
        try:
            subprocess.run(["bash", "-c", script], cwd=app, env=env, check=False,
                           timeout=cfg["agent"]["timeout_sec"], capture_output=True)
        except subprocess.TimeoutExpired:
            pass                                                # timeout: verify whatever is there
        shutil.rmtree(tests, ignore_errors=True)                # verifier gets a clean copy of tests
        shutil.copytree(task / "tests", tests)
        subprocess.run(["bash", str(tests / verifier)], env=env, check=False,
                       timeout=cfg["verifier"]["timeout_sec"], capture_output=True)
        reward = logs / "reward.txt"
        if not reward.exists():                                 # a missing reward is an infra error, not 0
            return "ERROR"
        return reward.read_text().strip()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as root:
        task = make_task(pathlib.Path(root))
        cfg = read_toml(task / "task.toml")
        print(f"task {cfg['task']['name']} v{cfg['task']['version']}: "
              + ", ".join(sorted(str(p.relative_to(task)) for p in task.rglob("*") if p.is_file())))
        header = f"{'agent':<12} {'strict, separate':>17} {'lazy, separate':>15} {'strict, tests visible':>22}"
        print(header)
        results = {}
        for agent in AGENTS:
            r = (run_trial(task, agent, "test.sh", False), run_trial(task, agent, "test_lazy.sh", False),
                 run_trial(task, agent, "test.sh", True))
            results[agent] = r
            print(f"{agent:<12} {r[0]:>17} {r[1]:>15} {r[2]:>22}")
    assert results["oracle"] == ("1", "1", "1"), "Oracle must pass, or the task is broken"
    assert results["null"] == ("0", "0", "0"), "a do-nothing agent must fail"
    assert results["empty-file"][:2] == ("0", "1")
    assert results["test-peeker"][0] == "0" and results["test-peeker"][2] == "1"
    print("checks: oracle passes, null fails; lazy verifier and visible tests are both exploitable")
