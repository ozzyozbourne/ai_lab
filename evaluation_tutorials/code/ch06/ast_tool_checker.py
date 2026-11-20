"""BFCL-style AST checking of tool calls, with a typed error taxonomy.

Section 6.4 (#trajectory) of Chapter 6.  Run:  python3 code/ch06/ast_tool_checker.py

A model's tool call is a string such as  get_weather(city="Paris", unit="C").  We parse it with
Python's `ast` module (never `eval`), then check it against a JSON schema and a set of acceptable
values, in the same order as BFCL's simple_function_checker:
    wrong_func_name -> missing_required -> unexpected_param -> type_error -> value_error
Strings are normalised as in BFCL's standardize_string (drop spaces and ,./-_*^, lower-case).
Expected key output: 4 of 12 calls are correct; every failure gets exactly one typed error.
"""
from __future__ import annotations

import ast
import re
from collections import Counter
from dataclasses import dataclass

SCHEMA = {
    "name": "get_weather",
    "parameters": {
        "type": "object",
        "properties": {
            "city": {"type": "string"},
            "unit": {"type": "string", "enum": ["C", "F"]},
            "days": {"type": "integer"},
        },
        "required": ["city"],
    },
}
# BFCL-style possible answers: a list of acceptable values per parameter; "" = may be omitted.
POSSIBLE = {"city": ["Paris", "Paris, France"], "unit": ["C", ""], "days": [1, ""]}

PY_TYPES = {"string": str, "integer": int, "number": (int, float), "boolean": bool}


def standardize_string(s: str) -> str:
    """Same normalisation as BFCL's ast_checker.standardize_string."""
    return re.sub(r"[ \,\.\/\-\_\*\^]", "", s).lower().replace("'", '"')


@dataclass
class Verdict:
    valid: bool
    error_type: str = ""
    detail: str = ""


def parse_call(text: str) -> tuple[str, dict]:
    tree = ast.parse(text.strip(), mode="eval")
    call = tree.body
    if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Name):
        raise ValueError("not a simple function call")
    if call.args:
        raise ValueError("positional arguments are not allowed")
    kwargs = {}
    for kw in call.keywords:
        try:
            kwargs[kw.arg] = ast.literal_eval(kw.value)
        except ValueError:
            raise ValueError(f"argument {kw.arg!r} is not a literal") from None
    return call.func.id, kwargs


def check(text: str, schema: dict = SCHEMA, possible: dict = POSSIBLE) -> Verdict:
    try:
        name, kwargs = parse_call(text)
    except SyntaxError:
        return Verdict(False, "parse_error", "SyntaxError: not valid Python")
    except ValueError as e:
        return Verdict(False, "parse_error", str(e))
    if name != schema["name"]:
        return Verdict(False, "wrong_func_name", f"{name!r} != {schema['name']!r}")
    props, required = schema["parameters"]["properties"], schema["parameters"]["required"]
    for p in required:
        if p not in kwargs:
            return Verdict(False, "missing_required", p)
    for p in kwargs:
        if p not in props:
            return Verdict(False, "unexpected_param", p)
    for p, v in kwargs.items():
        want = PY_TYPES[props[p]["type"]]
        if isinstance(v, bool) and want is not bool or not isinstance(v, want):
            return Verdict(False, "type_error", f"{p}={v!r} is not {props[p]['type']}")
    for p, v in kwargs.items():
        if "enum" in props[p] and v not in props[p]["enum"]:
            return Verdict(False, "value_error:enum", f"{p}={v!r} not in {props[p]['enum']}")
        ok = possible[p]
        if isinstance(v, str):
            hit = standardize_string(v) in {standardize_string(x) for x in ok if isinstance(x, str) and x}
        else:
            hit = v in ok
        if not hit:
            return Verdict(False, "value_error", f"{p}={v!r} not in {ok}")
    for p, ok in possible.items():                       # omitted params must be optional
        if p not in kwargs and "" not in ok:
            return Verdict(False, "missing_required", p)
    return Verdict(True)


CALLS = [
    'get_weather(city="Paris", unit="C")',
    'get_weather(city="paris")',
    'get_weather(city="Paris, France", days=1)',
    'get_weather(unit="C", city="PARIS")',
    'get_wether(city="Paris")',
    'get_weather(unit="C")',
    'get_weather(city="Paris", country="FR")',
    'get_weather(city="Paris", days="1")',
    'get_weather(city="Paris", unit="K")',
    'get_weather(city="London")',
    'get_weather(city=user_city)',
    'get_weather(city="Paris"',
]


def main() -> None:
    print(f"{'model output':<44} {'valid':<6} {'error type':<17} detail")
    counts: Counter[str] = Counter()
    verdicts = []
    for c in CALLS:
        v = check(c)
        verdicts.append(v)
        counts[v.error_type or "ok"] += 1
        print(f"{c:<44} {str(v.valid):<6} {v.error_type or '-':<17} {v.detail}")
    print("\nerror taxonomy:", dict(counts))
    n_ok = sum(v.valid for v in verdicts)
    print(f"accuracy: {n_ok}/{len(CALLS)} = {n_ok / len(CALLS):.3f}")
    assert n_ok == 4
    assert counts == Counter({"ok": 4, "parse_error": 2, "wrong_func_name": 1, "missing_required": 1,
                              "unexpected_param": 1, "type_error": 1, "value_error:enum": 1, "value_error": 1})


if __name__ == "__main__":
    main()
