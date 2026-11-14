"""Every number in the code is traceable to the ASSUMPTIONS LEDGER (plan.md section 5.3).

- Any numeric literal under tsp/ (except in tsp/params.py) other than 0 and 1
  (so also -1, which tokenizes as '-' and '1') must be on a line that carries
  "# ledger: <ID>" or "# not-a-parameter: <reason>".
- Every ledger ID mentioned under tsp/ must be a row of the ledger tables in
  research/dossier.md section 7.
- Every numeric module-level constant in tsp/params.py carries "# ledger: <ID>"
  with an existing ID.
"""

import ast
import io
import pathlib
import re
import tokenize

ROOT = pathlib.Path(__file__).resolve().parent.parent
PKG = ROOT / "tsp"
DOSSIER = ROOT / "research" / "dossier.md"

ID = r"[A-Z][0-9]+"
LEDGER_COMMENT = re.compile(r"#\s*ledger:\s*(" + ID + r"(?:\s*,\s*" + ID + r")*)")
NOT_A_PARAMETER = re.compile(r"#\s*not-a-parameter:\s*\S")
# "ledger: T6", "ledger T6", "ledger: B11, T8, T9 and T10" anywhere in comments or strings.
LEDGER_MENTION = re.compile(r"\bledger:?\s+(" + ID + r"(?:(?:\s*,\s*|\s+and\s+)" + ID + r")*)\b")
ROW = re.compile(r"^\|\s*(" + ID + r")\s*\|")


def ledger_ids():
    """Row IDs of the tables in the ASSUMPTIONS LEDGER section of the dossier."""
    text = DOSSIER.read_text(encoding="utf-8")
    start = text.index("## 7. ASSUMPTIONS LEDGER")
    ids = []
    for line in text[start:].splitlines():
        m = ROW.match(line)
        if m:
            ids.append(m.group(1))
    return ids


def py_files():
    return sorted(p for p in PKG.rglob("*.py") if "__pycache__" not in p.parts)


def _is_trivial(token_text):
    value = ast.literal_eval(token_text)
    return value in (0, 1) and not isinstance(value, complex)


def literal_violations(path):
    """(line number, line) of every numeric literal not covered by a ledger or not-a-parameter comment."""
    src = path.read_text(encoding="utf-8")
    lines = src.splitlines()
    bad = []
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type != tokenize.NUMBER or _is_trivial(tok.string):
            continue
        line = lines[tok.start[0] - 1]
        if not (LEDGER_COMMENT.search(line) or NOT_A_PARAMETER.search(line)):
            bad.append((tok.start[0], line.strip()))
    return bad


def mentioned_ids(path):
    """Every ledger ID mentioned in the file, as (line number, ID)."""
    out = []
    for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        for m in LEDGER_MENTION.finditer(line):
            for ref in re.findall(ID, m.group(1)):
                out.append((i, ref))
    return out


def test_ledger_has_rows():
    ids = ledger_ids()
    for expected in ("G1", "T6", "T15", "B20", "C4"):
        assert expected in ids
    assert len(ids) == len(dict.fromkeys(ids)), "duplicate ledger row IDs"


def test_package_files_found():
    names = [p.name for p in py_files()]
    assert "params.py" in names and "reference.py" in names


def test_numeric_literals_are_annotated():
    problems = []
    for path in py_files():
        if path == PKG / "params.py":
            continue
        for lineno, line in literal_violations(path):
            problems.append(f"{path.relative_to(ROOT)}:{lineno}: {line}")
    assert not problems, "numeric literals without '# ledger:' or '# not-a-parameter:':\n" + "\n".join(problems)


def test_ledger_ids_exist():
    ids = set(ledger_ids())
    problems = []
    for path in py_files():
        for lineno, ref in mentioned_ids(path):
            if ref not in ids:
                problems.append(f"{path.relative_to(ROOT)}:{lineno}: unknown ledger ID {ref}")
    assert not problems, "\n".join(problems)


def test_params_constants_carry_ledger_ids():
    ids = set(ledger_ids())
    path = PKG / "params.py"
    src = path.read_text(encoding="utf-8")
    lines = src.splitlines()
    problems = []
    checked = 0
    for node in ast.parse(src).body:
        if not isinstance(node, (ast.Assign, ast.AnnAssign)):
            continue
        value = node.value
        if isinstance(value, ast.UnaryOp) and isinstance(value.op, (ast.USub, ast.UAdd)):
            value = value.operand
        if not (isinstance(value, ast.Constant) and isinstance(value.value, (int, float))
                and not isinstance(value.value, bool)):
            continue
        checked += 1
        line = lines[node.lineno - 1]
        m = LEDGER_COMMENT.search(line)
        if not m:
            problems.append(f"params.py:{node.lineno}: no '# ledger: <ID>': {line.strip()}")
            continue
        for ref in re.findall(ID, m.group(1)):
            if ref not in ids:
                problems.append(f"params.py:{node.lineno}: unknown ledger ID {ref}")
    assert checked > 0
    assert not problems, "\n".join(problems)


def test_scanner_catches_a_bare_literal(tmp_path):
    p = tmp_path / "x.py"
    p.write_text("a = 0\nb = -1\nc = 2.0\nd = 3  # ledger: T6\ne = 4  # not-a-parameter: test\n"
                 "f = '5'\ng = 1.0\n", encoding="utf-8")
    assert [n for n, _ in literal_violations(p)] == [3]
    q = tmp_path / "y.py"
    q.write_text("# ledger: T6, B99\n'''see ledger B11 and T8'''\n", encoding="utf-8")
    assert [r for _, r in mentioned_ids(q)] == ["T6", "B99", "B11", "T8"]
