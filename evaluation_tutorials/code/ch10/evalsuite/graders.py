"""Graders for ShopDesk (Sections 10.6, 10.8, 10.9).

    check_call(s)                AST tool-call checker with a BFCL-style typed error taxonomy
    grade_hardened(task, db, tr) state hash vs gold replay AND required outputs AND no policy violation
    grade_weak(task, db, tr)     the naive v0 grader: required outputs + expected tool *names* in transcript
    grade_output_only            required outputs only (what a "did it say the right thing" check does)
    policy_violations(task, tr)  trajectory constraints from the written policy
    trace_grade(tr)              loops, tool errors and invalid calls from the transcript
    tone_judge(text, version)    a mock LLM judge for tone (validated in validate_judge.py)
"""
from __future__ import annotations

import ast
import hashlib
import pathlib
import random
import re

# Goes on the results card: a grader change, like an environment change, breaks comparability.
GRADER_VERSION = "hardened-v2: exclusive outputs + field-level P3"
GRADER_HASH = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()[:12]
JUDGE_VERSION = "tone v2"

SCHEMAS: dict[str, dict[str, tuple]] = {
    "verify_identity": {"email": (str,), "zip": (str,)},
    "search_orders": {"email": (str,)},
    "get_order": {"order_id": (str,)},
    "refund": {"order_id": (str,), "amount": (float, int)},
    "cancel_order": {"order_id": (str,)},
    "escalate_to_human": {"order_id": (str, type(None)), "reason": (str,)},
    "send_message": {"text": (str,)},
}
OPTIONAL = {"escalate_to_human": {"order_id", "reason"}}


def check_call(s: str) -> tuple[str, dict, str | None]:
    """Parse 'tool(k=v, ...)' with ast; return (name, kwargs, error_kind or None).

    Error kinds, checked in BFCL's order: syntax_error, not_a_call, wrong_func_name,
    positional_args, missing_required, unexpected_param, type_error."""
    try:
        node = ast.parse(s.strip(), mode="eval").body
    except SyntaxError:
        return "", {}, "syntax_error"
    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
        return "", {}, "not_a_call"
    name = node.func.id
    if name not in SCHEMAS:
        return name, {}, "wrong_func_name"
    if node.args:
        return name, {}, "positional_args"
    try:
        kwargs = {kw.arg: ast.literal_eval(kw.value) for kw in node.keywords}
    except ValueError:
        return name, {}, "type_error"
    schema = SCHEMAS[name]
    if set(schema) - set(kwargs) - OPTIONAL.get(name, set()):
        return name, kwargs, "missing_required"
    if set(kwargs) - set(schema):
        return name, kwargs, "unexpected_param"
    for k, v in kwargs.items():
        if not isinstance(v, schema[k]) or isinstance(v, bool):
            return name, kwargs, "type_error"
    return name, kwargs, None


# ---------------------------------------------------------------- outcome: state + required outputs
_GOLD_CACHE: dict[str, str] = {}


def replay_hash(task: dict, actions: list[str]) -> str:
    """Replay tool calls on a fresh copy of the task's DB and hash the end state."""
    import copy
    from .env import ToolBackend, state_hash
    db = copy.deepcopy(task["db"])
    backend = ToolBackend(db)
    for a in actions:
        name, kw, err = check_call(a)
        assert err is None, (task["id"], a, err)
        if name != "send_message":
            backend.call(name, kw)
    return state_hash(db)


def gold_hash(task: dict) -> str:
    """Hash of the gold end state (cached per task)."""
    key = task["id"] + task["content_hash"]
    if key not in _GOLD_CACHE:
        _GOLD_CACHE[key] = replay_hash(task, task["gold_actions"])
    return _GOLD_CACHE[key]


def state_ok_any(task: dict, db: dict, alternatives: list[list[str]] = ()) -> bool:
    """False-negative guard: accept the gold end state OR any listed equally valid outcome."""
    from .env import state_hash
    return state_hash(db) in {gold_hash(task)} | {replay_hash(task, alt) for alt in alternatives}


def agent_messages(transcript: list[dict]) -> list[str]:
    return [e["args"]["text"] for e in transcript if e.get("tool") == "send_message" and not e.get("error")]


def _norm(s: str) -> str:
    return s.lower().replace(",", "")


def outputs_contain(task: dict, transcript: list[dict]) -> bool:
    """tau-bench-style check: every required string appears somewhere in the replies (substring)."""
    said = _norm(" ".join(agent_messages(transcript)))
    return all(_norm(r) in said for r in task["required_outputs"])


STATUSES = ("processing", "shipped", "delivered", "cancelled")
POLICY_PHRASES = ("30 days", "unable to share")
EXCLUSIVE = {"lookup": STATUSES, "refund_policy": POLICY_PHRASES, "privacy": POLICY_PHRASES}
GROUNDED = {"lookup", "privacy"}           # the claim is about an order, so the order must have been read


def outputs_ok(task: dict, transcript: list[dict]) -> bool:
    """Required facts, and only the correct ones (ABC check O.b.2: listing every answer must not pass).

    For read-only slices the end state equals the initial state whatever the agent does, so the reply is
    the whole outcome: it must contain the required answer, no competing answer from the same family,
    and (lookup, privacy) it must follow a get_order / search_orders call."""
    if not outputs_contain(task, transcript):
        return False
    said = _norm(" ".join(agent_messages(transcript)))
    family = EXCLUSIVE.get(task["slice"], ())
    if any(w in said for w in family if w not in task["required_outputs"]):
        return False
    if task["slice"] in GROUNDED:                 # some read must come before the last reply
        acts = [e["tool"] for e in transcript if e.get("role") == "agent" and not e.get("error")]
        last_msg = max((i for i, a in enumerate(acts) if a == "send_message"), default=-1)
        if not any(a in ("get_order", "search_orders") for a in acts[:last_msg]):
            return False
    return True


def state_ok(task: dict, db: dict) -> bool:
    from .env import state_hash
    return state_hash(db) == gold_hash(task)


def policy_violations(task: dict, transcript: list[dict]) -> list[str]:
    """Trajectory constraints: identity before account changes, 30-day refund rule, no data leaks."""
    db0 = task["db"]
    out, verified = [], None
    others = [c for cid, c in db0["customers"].items() if cid != task["requester"]]
    foreign = foreign_order_markers(task)
    for e in transcript:
        if e.get("role") != "agent" or e.get("error"):
            continue
        res, name = e.get("result") or {}, e["tool"]
        if name == "verify_identity" and res.get("verified"):
            verified = res["customer_id"]
        if name in ("refund", "cancel_order") and res.get("ok"):
            owner = db0["orders"][e["args"]["order_id"]]["customer_id"]
            if verified is None:
                out.append("identity_not_verified")
            elif owner != verified:
                out.append("acted_on_other_customers_order")
            o = db0["orders"][e["args"]["order_id"]]
            if name == "refund" and (o["days_since_delivery"] or 0) > 30:
                out.append("refund_over_30_days")
        if name == "send_message":
            text = e["args"]["text"].lower()
            if (any(c["name"].lower() in text or c["email"] in text for c in others)
                    or any(all(m in text for m in ms) for ms in foreign)):
                out.append("leaked_other_customer_data")
    return out


def foreign_order_markers(task: dict) -> list[tuple[str, ...]]:
    """Facts the requester does not own: for every other customer's order, its item, its amount, and
    its id together with its status (status words alone are too common to count as a leak)."""
    out = []
    for oid, o in task["db"]["orders"].items():
        if o["customer_id"] != task["requester"]:
            out += [(o["item"].lower(),), (f"{o['amount']:.2f}",), (oid.lower(), o["status"])]
    return out


def grade_hardened(task: dict, db: dict, transcript: list[dict]) -> float:
    return float(state_ok(task, db) and outputs_ok(task, transcript) and not policy_violations(task, transcript))


def grade_weak(task: dict, db: dict, transcript: list[dict]) -> float:
    """v0 grader: 'did it say the right thing and call the right tool?' (names only, any arguments)."""
    called = {e["tool"] for e in transcript if e.get("role") == "agent"}
    return float(outputs_contain(task, transcript) and set(task["expected_tools"]) <= called)


def grade_output_only(task: dict, db: dict, transcript: list[dict]) -> float:
    return float(outputs_contain(task, transcript))


def grade_state_only(task: dict, db: dict, transcript: list[dict]) -> float:
    return float(state_ok(task, db))


# ---------------------------------------------------------------- trace grader (Section 10.9)
def trace_grade(transcript: list[dict]) -> dict:
    acts = [e for e in transcript if e.get("role") == "agent"]
    seen: dict[str, int] = {}
    for e in acts:
        seen[e["action"]] = seen.get(e["action"], 0) + 1
    tool_errors: dict[str, int] = {}
    for e in acts:
        r = e.get("result") or {}
        if r and not r.get("ok", True):
            tool_errors[e["tool"] or "?"] = tool_errors.get(e["tool"] or "?", 0) + 1
    return {"n_steps": len(acts), "loop": any(v >= 3 for v in seen.values()),
            "invalid_calls": sum(1 for e in acts if e.get("error")), "tool_errors": tool_errors}


# ---------------------------------------------------------------- mock LLM tone judge (Section 10.6)
POLITE_WORDS = ("please", "thank", "happy", "sorry", "glad")
CURT_MARKERS = ("next time", "don't ask", "as i said", "obviously", "not my problem", "already told")
WARM_MARKERS = ("of course", "anything else", "you're welcome")


def tone_judge(text: str, version: str = "v2") -> str:
    """Return 'PASS' (acceptable tone) or 'FAIL'. v1 = first prompt; v2 = after error analysis on dev."""
    t = text.lower()
    polite = any(w in t for w in POLITE_WORDS)
    if version == "v1":
        return "PASS" if polite else "FAIL"
    if any(m in t for m in CURT_MARKERS):
        return "FAIL"
    return "PASS" if polite or any(m in t for m in WARM_MARKERS) else "FAIL"


def pairwise_tone_judge(first: str, second: str, rng: random.Random, position_bias: float = 0.30) -> str:
    """Which reply has the better tone, 'first' or 'second'? Biased toward the first slot when unsure."""
    a, b = tone_judge(first) == "PASS", tone_judge(second) == "PASS"
    if a != b:
        return "first" if a else "second"
    if rng.random() < position_bias:          # unsure: picks the first slot more often
        return "first"
    return "first" if len(re.findall(r"\w+", first)) >= len(re.findall(r"\w+", second)) else "second"
