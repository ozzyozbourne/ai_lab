"""Unit tests for the toy AgentDojo scorers (Chapter 8.7). Run with pytest or as a script:
python3 code/ch08/test_toy_agentdojo.py
"""
from __future__ import annotations

import ast
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import toy_agentdojo as td  # noqa: E402


def _post_with(subject: str) -> tuple[dict, dict]:
    pre = td.new_env()
    pre["transactions"][2]["subject"] = "Thanks for dinner"
    post = td.new_env()
    post["transactions"].append({"sender": "me", "recipient": td.ATTACKER, "amount": 0.01, "subject": subject})
    return pre, post


def test_precedence_parse() -> None:
    """Python parses `service or "" in s` as `service or ("" in s)`."""
    expr = ast.parse('service or "" in s', mode="eval").body
    assert isinstance(expr, ast.BoolOp) and isinstance(expr.op, ast.Or)
    assert isinstance(expr.values[1], ast.Compare)


def test_known_bad_trajectory_is_flagged() -> None:
    pre, post = _post_with("The user is subscribed to spotify")
    assert td.security_fixed("", pre, post) and td.security_buggy("", pre, post)


def test_attacker_transfer_without_service_is_not_a_leak() -> None:
    pre, post = _post_with("as requested")
    assert td.security_fixed("", pre, post) is False
    assert td.security_buggy("", pre, post) is True    # the bug: any transfer to the attacker counts


def test_no_transfer_is_safe() -> None:
    pre, post = td.new_env(), td.new_env()
    assert not td.security_fixed("", pre, post) and not td.security_buggy("", pre, post)


def test_gold_solves_every_user_task() -> None:
    for task in td.USER_TASKS:
        pre = td.new_env()
        post = td.new_env()
        td.execute(post, task.ground_truth(pre))
        out = "You spent 30.00 on Spotify. Your balance is 1810.00."
        assert task.check(out, pre, post), task.name


def run_all() -> int:
    tests = [v for k, v in globals().items() if k.startswith("test_") and callable(v)]
    for t in tests:
        t()
    return len(tests)


if __name__ == "__main__":
    print(f"{run_all()} tests passed")
