"""No machine parameter literals in tsp/hw (plan.md 3.1, section 9 'Ledger' row)."""
import ast
import re
from pathlib import Path

HW = Path(__file__).resolve().parents[2] / "tsp" / "hw"
ALLOWED = (-1, 0, 1, 2)
NOTE = re.compile(r"#.*(L-[A-Z]+\d+|not a machine parameter:)")


def test_no_unannotated_numeric_literals():
    bad = []
    for path in sorted(HW.rglob("*.py")):
        src = path.read_text()
        lines = src.splitlines()
        tree = ast.parse(src)
        negated = {id(n.operand) for n in ast.walk(tree)
                   if isinstance(n, ast.UnaryOp) and isinstance(n.op, ast.USub)}
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and type(node.value) in (int, float) and not isinstance(node.value, bool):
                v = -node.value if id(node) in negated else node.value
                if v not in ALLOWED and not NOTE.search(lines[node.lineno - 1]):
                    bad.append(f"{path.name}:{node.lineno}: {v}")
    assert not bad, bad
