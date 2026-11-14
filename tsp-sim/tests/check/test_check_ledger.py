"""Ledger traceability (plan.md section 9, "Ledger" row).

- every ledger row (research/dossier.md section 7) has a status word and a non-empty reasoning cell;
- every L-... id mentioned in tsp/config.py, tsp/isa.py, tsp/numerics.py exists in the ledger;
- every line of tsp/config.py holding a numeric literal carries an L-... id or a
  "not a machine parameter:" comment (AST for literals, tokenize for comments);
- in tsp/hw/**.py and tsp/compiler/**.py, every numeric literal other than -1, 0, 1, 2 is on a
  line with an L-... id or a "not a machine parameter:" comment.
"""
import ast
import io
import re
import tokenize
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
DOSSIER = ROOT / "research" / "dossier.md"
ID_RE = re.compile(r"\bL-[A-Z]+\d+\b")
EXEMPT_RE = re.compile(r"not a machine parameter:")
STATUS_WORDS = ("SOURCED", "INFERRED", "ASSUMED", "scope")
ALLOWED_SMALL = (-1, 0, 1, 2)


def ledger_rows() -> dict[str, dict]:
    """id -> {'status': cell, 'reasoning': cell} from the tables of section 7."""
    text = DOSSIER.read_text(encoding="utf-8")
    start = text.index("## 7. ASSUMPTIONS LEDGER")
    end = text.index("\n## 8.", start)
    rows, header = {}, None
    for line in text[start:end].splitlines():
        if not line.startswith("|"):
            header = None
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = cells
            continue
        if set("".join(cells)) <= set("-: "):
            continue                                     # the |---|---| separator
        if not ID_RE.fullmatch(cells[0]):
            continue
        status_i = header.index("Status")
        reason_i = [i for i, h in enumerate(header) if "reasoning" in h.lower()][0]
        rows[cells[0]] = {"status": cells[status_i] if status_i < len(cells) else "",
                          "reasoning": cells[reason_i] if reason_i < len(cells) else ""}
    return rows


def literal_lines(source: str) -> list[tuple[int, object]]:
    """(line, value) of every numeric literal; -c is reported as one literal -c."""
    tree = ast.parse(source)
    out, inner = [], set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub)
                and isinstance(node.operand, ast.Constant) and _is_number(node.operand.value)):
            out.append((node.lineno, -node.operand.value))
            inner.add(id(node.operand))
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and _is_number(node.value) and id(node) not in inner:
            out.append((node.lineno, node.value))
    return sorted(out, key=lambda x: (x[0], repr(x[1])))


def _is_number(v) -> bool:
    return isinstance(v, (int, float, complex)) and not isinstance(v, bool)


def comments(source: str) -> dict[int, str]:
    out = {}
    for tok in tokenize.generate_tokens(io.StringIO(source).readline):
        if tok.type == tokenize.COMMENT:
            out[tok.start[0]] = tok.string
    return out


def annotated(comment: str) -> bool:
    return bool(ID_RE.search(comment) or EXEMPT_RE.search(comment))


def unannotated(path: Path, allow_small: bool) -> list[str]:
    src = path.read_text(encoding="utf-8")
    com = comments(src)
    lines = src.splitlines()
    bad = []
    for lineno, val in literal_lines(src):
        if allow_small and val in ALLOWED_SMALL:
            continue
        if not annotated(com.get(lineno, "")):
            bad.append(f"{path.relative_to(ROOT)}:{lineno}: {val!r}: {lines[lineno - 1].strip()}")
    return list(dict.fromkeys(bad))


# ---- the ledger itself --------------------------------------------------------------
def test_ledger_parses():
    rows = ledger_rows()
    assert len(rows) >= 50
    for must in ("L-G1", "L-T1", "L-T10", "L-I2", "L-M4", "L-V7", "L-X9", "L-S4", "L-K7", "L-C1"):
        assert must in rows, must


def test_ledger_rows_have_status_and_reasoning():
    bad = []
    for rid, row in ledger_rows().items():
        if not any(w in row["status"] for w in STATUS_WORDS):
            bad.append(f"{rid}: no status word in {row['status']!r}")
        if not row["reasoning"]:
            bad.append(f"{rid}: empty reasoning cell")
    assert not bad, "ledger rows (research/dossier.md section 7):\n" + "\n".join(bad)


# ---- ids used in the contract files ---------------------------------------------------
@pytest.mark.parametrize("rel", ["tsp/config.py", "tsp/isa.py", "tsp/numerics.py"])
def test_ids_in_contract_files_exist(rel):
    ids = ledger_rows()
    used = sorted(set(ID_RE.findall((ROOT / rel).read_text(encoding="utf-8"))))
    assert used or rel != "tsp/config.py"
    missing = [i for i in used if i not in ids]
    assert not missing, f"{rel} cites ids missing from the ledger: {missing}"


def test_config_literals_are_annotated():
    bad = unannotated(ROOT / "tsp" / "config.py", allow_small=False)
    assert not bad, "tsp/config.py lines with a numeric literal and no L-... id or " \
                    "'not a machine parameter:' comment:\n" + "\n".join(bad)


# ---- hw and compiler -------------------------------------------------------------------
@pytest.mark.parametrize("pkg", ["hw", "compiler"])
def test_package_literals_are_annotated(pkg):
    d = ROOT / "tsp" / pkg
    files = sorted(d.rglob("*.py")) if d.is_dir() else []
    if not files:
        pytest.skip(f"tsp/{pkg} does not exist yet (or has no .py files)")
    bad = [b for f in files for b in unannotated(f, allow_small=True)]
    assert not bad, f"numeric literals outside -1, 0, 1, 2 without an L-... id or " \
                    f"'not a machine parameter:' comment:\n" + "\n".join(bad)


@pytest.mark.parametrize("pkg", ["hw", "compiler"])
def test_package_ids_exist(pkg):
    d = ROOT / "tsp" / pkg
    files = sorted(d.rglob("*.py")) if d.is_dir() else []
    if not files:
        pytest.skip(f"tsp/{pkg} does not exist yet (or has no .py files)")
    ids = ledger_rows()
    missing = sorted({f"{f.relative_to(ROOT)}: {i}" for f in files
                      for i in ID_RE.findall(f.read_text(encoding="utf-8")) if i not in ids})
    assert not missing, "ids missing from the ledger:\n" + "\n".join(missing)


# ---- the checker itself can fail ---------------------------------------------------------
def test_literal_checker_detects_and_accepts(tmp_path):
    p = tmp_path / "x.py"
    p.write_text("a = 3\nb = 4  # L-G1\nc = -1\nd = -2\ne = 5  # not a machine parameter: test\n"
                 "f = 'text 7'\ng = True\n", encoding="utf-8")
    ROOT_saved = ROOT
    src = p.read_text()
    com = comments(src)
    flagged = [ln for ln, v in literal_lines(src) if v not in ALLOWED_SMALL and not annotated(com.get(ln, ""))]
    assert flagged == [1, 4] and ROOT_saved == ROOT
    strict = [ln for ln, v in literal_lines(src) if not annotated(com.get(ln, ""))]
    assert strict == [1, 3, 4]
