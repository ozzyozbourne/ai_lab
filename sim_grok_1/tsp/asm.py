"""Program checker, text assembler/disassembler and static dispatch expansion.

See plan.md section 3.7.

Text format (one instruction per line, fields in dataclass order, fields equal
to their default omitted):

    unit VXM_A0
      Notify
      Nop n=2
      Vxm op="add" dtype="int32" a=E0 b=E4 out=E8 n=16 tag="y@3" expect=["p@3","b@2"]
    unit MXM_W0
      Sync
      Iw dtype="int8" entries=[0:W0,1:W1] expect=["W.0@0","W.1@0"]

Values: integers in decimal, strings as JSON string literals (so tags may hold
any character), a StreamRef as direction letter plus stream number (E5),
None as '-', tuples as [a,b,...], and Iw entries as row:StreamRef.
"""

import json
import numbers
from dataclasses import MISSING, fields

from . import isa, params
from .errors import ProgramError

_CLASSES = {
    c.__name__: c
    for c in (isa.Sync, isa.Notify, isa.Nop, isa.Repeat, isa.Read, isa.Write, isa.Vxm,
              isa.Iw, isa.Abc, isa.Distribute, isa.Permute, isa.Shift)
}
_DATA_CLASSES = isa.MEM_INSTRS + isa.VXM_INSTRS + isa.MXM_INSTRS + isa.SXM_INSTRS
_MXM_DTYPES = ("int8", "fp16")                      # B6: MXM operand types
_ARITH_OPS = ("add", "sub", "mul", "neg", "relu")   # B11: keep the data type
_ARITH_DTYPES = ("int32", "fp32")                   # B11: 32-bit ALU operands
_FP32_ONLY_OPS = ("tanh", "exp", "rsqrt")           # B11
_CAST_PAIRS = (("fp32", "fp16"), ("fp16", "fp32"), ("int32", "fp32"))  # B11
_REQUANT_PAIR = ("int32", "int8")                   # B20


# =============================================================================
# check_program
# =============================================================================
def _is_int(x):
    return isinstance(x, numbers.Integral) and not isinstance(x, bool)


def _fail(unit, i, instr, msg):
    raise ProgramError(f"{unit}[{i}] {type(instr).__name__}: {msg}")


def _check_ref(unit, i, instr, name, ref, w, config):
    """A StreamRef of a value w streams wide: valid dir, in range, aligned (G3, G5)."""
    if not isinstance(ref, isa.StreamRef):
        _fail(unit, i, instr, f"{name} is not a StreamRef: {ref!r}")
    if ref.dir not in isa.DIRS:
        _fail(unit, i, instr, f"{name} has bad direction {ref.dir!r}")
    if not _is_int(ref.s):
        _fail(unit, i, instr, f"{name} stream number is not an integer: {ref.s!r}")
    if ref.s < 0 or ref.s + w - 1 > config.streams_per_dir - 1:
        _fail(unit, i, instr, f"{name} streams {ref.s}..{ref.s + w - 1} outside 0..{config.streams_per_dir - 1}")
    if ref.s % w != 0:
        _fail(unit, i, instr, f"{name} base stream {ref.s} not a multiple of width {w}")


def _check_dtype(unit, i, instr, name, dtype, allowed=isa.DTYPES):
    if dtype not in allowed:
        _fail(unit, i, instr, f"{name} {dtype!r} not one of {allowed}")


def _check_len(unit, i, instr, name, n, config):
    """A result length n in 1..lanes (B19)."""
    if not _is_int(n) or n < 1 or n > config.lanes:
        _fail(unit, i, instr, f"{name}={n!r} outside 1..{config.lanes}")


def _check_tags(unit, i, instr):
    tag = getattr(instr, "tag", "")
    if not isinstance(tag, str):
        _fail(unit, i, instr, f"tag is not a string: {tag!r}")
    expect = getattr(instr, "expect", ())
    if not isinstance(expect, tuple) or not all(isinstance(e, str) for e in expect):
        _fail(unit, i, instr, f"expect is not a tuple of strings: {expect!r}")


def _check_vxm(unit, i, instr, config):
    op, dt = instr.op, instr.dtype
    if op not in params.VXM_UNARY_OPS and op not in params.VXM_BINARY_OPS:
        _fail(unit, i, instr, f"unknown op {op!r}")
    _check_dtype(unit, i, instr, "dtype", dt)
    if instr.out_dtype != "":
        _check_dtype(unit, i, instr, "out_dtype", instr.out_dtype)
    out_dt = instr.result_dtype()
    if op in params.VXM_BINARY_OPS and instr.b is None:
        _fail(unit, i, instr, f"binary op {op!r} without operand b")
    if op in params.VXM_UNARY_OPS and instr.b is not None:
        _fail(unit, i, instr, f"unary op {op!r} with operand b")
    if op in _ARITH_OPS:
        ok = dt in _ARITH_DTYPES and out_dt == dt
    elif op in _FP32_ONLY_OPS:
        ok = dt == "fp32" and out_dt == "fp32"
    elif op == "cast":
        ok = (dt, out_dt) in _CAST_PAIRS
    else:  # requant
        ok = (dt, out_dt) == _REQUANT_PAIR
    if not ok:
        _fail(unit, i, instr, f"op {op!r} not defined for {dt} -> {out_dt} (plan 2.5, B11, B20)")
    if not _is_int(instr.imm):
        _fail(unit, i, instr, f"imm is not an integer: {instr.imm!r}")
    if op == "requant" and instr.imm < 0:
        _fail(unit, i, instr, f"requant shift {instr.imm} is negative")
    if op != "requant" and instr.imm != 0:
        _fail(unit, i, instr, f"imm={instr.imm} given for op {op!r}, which takes no immediate")
    _check_ref(unit, i, instr, "a", instr.a, isa.width(dt), config)
    if instr.b is not None:
        _check_ref(unit, i, instr, "b", instr.b, isa.width(dt), config)
    _check_ref(unit, i, instr, "out", instr.out, isa.width(out_dt), config)
    _check_len(unit, i, instr, "n", instr.n, config)


def _check_mxm(unit, i, instr, config):
    """MXM operands and B10 directions: operands flow outward, the result inward."""
    hemi = unit.split("_")[1][0]
    inward = "E" if hemi == "W" else "W"
    _check_dtype(unit, i, instr, "dtype", instr.dtype, _MXM_DTYPES)
    w = isa.width(instr.dtype)
    if isinstance(instr, isa.Iw):
        if not isinstance(instr.entries, tuple) or not instr.entries:
            _fail(unit, i, instr, f"entries must be a non-empty tuple, got {instr.entries!r}")
        for k, entry in enumerate(instr.entries):
            if not isinstance(entry, tuple) or len(entry) != 2:  # not-a-parameter: an entry is a (row, StreamRef) pair
                _fail(unit, i, instr, f"entry {k} is not a (row, StreamRef) pair: {entry!r}")
            row, ref = entry
            if not _is_int(row) or row < 0 or row > config.lanes - 1:
                _fail(unit, i, instr, f"entry {k} row {row!r} outside 0..{config.lanes - 1}")
            _check_ref(unit, i, instr, f"entry {k}", ref, w, config)
            if ref.dir != hemi:
                _fail(unit, i, instr, f"entry {k} reads dir {ref.dir} but {unit} reads outward-flowing {hemi} streams (B10)")
        used = len(instr.entries) * w
        if used > config.iw_max_streams:
            _fail(unit, i, instr, f"uses {used} streams, more than {config.iw_max_streams} (B8)")
    else:
        _check_ref(unit, i, instr, "src", instr.src, w, config)
        _check_ref(unit, i, instr, "out", instr.out, isa.width(instr.result_dtype()), config)
        if instr.src.dir != hemi:
            _fail(unit, i, instr, f"src dir {instr.src.dir} but {unit} reads outward-flowing {hemi} streams (B10)")
        if instr.out.dir != inward:
            _fail(unit, i, instr, f"out dir {instr.out.dir} but {unit} writes inward-flowing {inward} streams (B10)")
        _check_len(unit, i, instr, "n_rows", instr.n_rows, config)


def _check_sxm(unit, i, instr, config):
    widths = tuple(sorted(dict.fromkeys(isa.width(d) for d in isa.DTYPES)))
    if instr.width not in widths:
        _fail(unit, i, instr, f"width {instr.width!r} not one of {widths}")
    _check_ref(unit, i, instr, "src", instr.src, instr.width, config)
    _check_ref(unit, i, instr, "out", instr.out, instr.width, config)
    _check_len(unit, i, instr, "n", instr.n, config)
    if isinstance(instr, isa.Shift):
        if not _is_int(instr.shift):
            _fail(unit, i, instr, f"shift is not an integer: {instr.shift!r}")
        return
    m = instr.map
    if not isinstance(m, tuple) or not all(_is_int(x) for x in m):
        _fail(unit, i, instr, f"map must be a tuple of integers, got {m!r}")
    if isinstance(instr, isa.Distribute):
        lps = config.lanes_per_superlane
        if len(m) != lps:
            _fail(unit, i, instr, f"map has {len(m)} entries, expected lanes_per_superlane = {lps}")
        for x in m:
            if x < -1 or x > lps - 1:
                _fail(unit, i, instr, f"map entry {x} outside -1..{lps - 1}")
    else:
        if sorted(m) != list(range(config.lanes)):
            _fail(unit, i, instr, f"map is not a bijection over range({config.lanes})")


def _check_data(unit, i, instr, config):
    kind = config.kind(unit)
    if not isinstance(instr, isa.ALLOWED[kind]):
        _fail(unit, i, instr, f"not allowed on a {kind} unit")
    _check_tags(unit, i, instr)
    if isinstance(instr, (isa.Read, isa.Write)):
        if not _is_int(instr.addr) or instr.addr < 0 or instr.addr > config.mem_words - 1:
            _fail(unit, i, instr, f"addr {instr.addr!r} outside 0..{config.mem_words - 1}")
        ref = instr.out if isinstance(instr, isa.Read) else instr.src
        _check_ref(unit, i, instr, "out" if isinstance(instr, isa.Read) else "src", ref, isa.width("int8"), config)
    elif isinstance(instr, isa.Vxm):
        _check_vxm(unit, i, instr, config)
    elif isinstance(instr, isa.MXM_INSTRS):
        _check_mxm(unit, i, instr, config)
    else:
        _check_sxm(unit, i, instr, config)


def _check_queue(unit, queue, config):
    """Check one queue; return the number of Notify elements in it."""
    if not isinstance(queue, list):
        raise ProgramError(f"{unit}: queue is not a list")
    if not queue:
        raise ProgramError(f"{unit}: empty queue")
    if not isinstance(queue[0], (isa.Sync, isa.Notify)):
        raise ProgramError(f"{unit}: queue starts with {type(queue[0]).__name__}, not Sync or Notify (B14)")
    notifies = 0
    prev_data = False            # previous element is a data instruction or a Repeat chained to one
    for i, instr in enumerate(queue):
        if isinstance(instr, (isa.Sync, isa.Notify)):
            if i != 0:
                _fail(unit, i, instr, "only allowed as the first element of a queue")
            notifies += isinstance(instr, isa.Notify)
            prev_data = False
        elif isinstance(instr, isa.Nop):
            if not _is_int(instr.n) or instr.n < 1 or instr.n > config.nop_max:
                _fail(unit, i, instr, f"n={instr.n!r} outside 1..{config.nop_max} (T14)")
            prev_data = False
        elif isinstance(instr, isa.Repeat):
            if not _is_int(instr.n) or instr.n < 1:
                _fail(unit, i, instr, f"n={instr.n!r} must be an integer >= 1 (T18)")
            if not _is_int(instr.d) or instr.d < 1:
                _fail(unit, i, instr, f"d={instr.d!r} must be an integer >= 1 (T18)")
            if not prev_data:
                _fail(unit, i, instr, "not preceded by a data instruction (T18)")
        elif isinstance(instr, _DATA_CLASSES):
            _check_data(unit, i, instr, config)
            prev_data = True
        else:
            raise ProgramError(f"{unit}[{i}]: not an instruction: {instr!r}")
    return notifies


def check_program(program):
    """Raise ProgramError for the first structural violation found (plan 3.7)."""
    config = program.config
    units = config.units()
    for unit in program.queues:
        if unit not in units:
            raise ProgramError(f"unknown unit {unit!r}")
    notifies = 0
    for unit in units:
        if unit in program.queues:
            notifies += _check_queue(unit, program.queues[unit], config)
    if notifies != 1:
        raise ProgramError(f"program has {notifies} Notify instructions, expected exactly one (B14)")


# =============================================================================
# Text form
# =============================================================================
def _fmt_value(v):
    if v is None:
        return "-"
    if isinstance(v, isa.StreamRef):
        return f"{v.dir}{v.s}"
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, bool):
        raise TypeError(f"cannot format bool {v!r}")
    if _is_int(v):
        return str(int(v))
    if isinstance(v, (tuple, list)):
        if len(v) == 2 and _is_int(v[0]) and isinstance(v[1], isa.StreamRef):  # not-a-parameter: an Iw entry is a pair
            return f"{int(v[0])}:{_fmt_value(v[1])}"
        return "[" + ",".join(_fmt_value(x) for x in v) + "]"
    raise TypeError(f"cannot format {v!r}")


def format_instr(instr):
    """One-line, deterministic text of an instruction, e.g. 'Read addr=3 out=E5 tag="x@0#0"'.

    Fields equal to their dataclass default are omitted.
    """
    parts = [type(instr).__name__]
    for f in fields(instr):
        v = getattr(instr, f.name)
        if f.default is not MISSING and v == f.default and type(v) is type(f.default):
            continue
        parts.append(f"{f.name}={_fmt_value(v)}")
    return " ".join(parts)


def disassemble(program):
    """All queues as text, in canonical unit order (only units present in the program)."""
    lines = []
    for unit in program.config.units():
        if unit in program.queues:
            lines.append(f"unit {unit}")
            lines.extend("  " + format_instr(instr) for instr in program.queues[unit])
    return "\n".join(lines) + "\n"


class _Parser:
    """Recursive-descent parser for one instruction line."""

    def __init__(self, text, lineno):
        self.text = text
        self.pos = 0
        self.lineno = lineno

    def error(self, msg):
        raise ProgramError(f"line {self.lineno}: {msg} at column {self.pos + 1}: {self.text!r}")

    def peek(self):
        return self.text[self.pos] if self.pos < len(self.text) else ""

    def skip_spaces(self):
        while self.peek() == " ":
            self.pos += 1

    def word(self):
        start = self.pos
        while self.peek().isalnum() or self.peek() == "_":
            self.pos += 1
        if start == self.pos:
            self.error("expected a name")
        return self.text[start:self.pos]

    def integer(self):
        start = self.pos
        if self.peek() == "-":
            self.pos += 1
        while self.peek().isdigit():
            self.pos += 1
        digits = self.text[start:self.pos]
        if digits in ("", "-"):
            self.error("expected an integer")
        return int(digits)

    def value(self):
        c = self.peek()
        if c == '"':
            try:
                s, end = json.JSONDecoder().raw_decode(self.text, self.pos)
            except json.JSONDecodeError:
                self.error("bad string literal")
            if not isinstance(s, str):
                self.error("expected a string")
            self.pos = end
            return s
        if c == "[":
            self.pos += 1
            items = []
            if self.peek() == "]":
                self.pos += 1
                return tuple(items)
            while True:
                items.append(self.value())
                if self.peek() == ",":
                    self.pos += 1
                elif self.peek() == "]":
                    self.pos += 1
                    return tuple(items)
                else:
                    self.error("expected ',' or ']'")
        if c in isa.DIRS:
            self.pos += 1
            return isa.StreamRef(c, self.integer())
        after = self.text[self.pos + 1:self.pos + 1 + 1]   # the character after c, or ""
        if c == "-" and not after.isdigit():
            self.pos += 1
            return None
        if c == "-" or c.isdigit():
            n = self.integer()
            if self.peek() == ":":
                self.pos += 1
                ref = self.value()
                if not isinstance(ref, isa.StreamRef):
                    self.error("expected a StreamRef after ':'")
                return (n, ref)
            return n
        self.error("expected a value")

    def instruction(self):
        name = self.word()
        cls = _CLASSES.get(name)
        if cls is None:
            self.error(f"unknown instruction {name!r}")
        names = [f.name for f in fields(cls)]
        kwargs = {}
        while True:
            self.skip_spaces()
            if self.pos >= len(self.text):
                break
            key = self.word()
            if key not in names:
                self.error(f"{name} has no field {key!r}")
            if key in kwargs:
                self.error(f"field {key!r} given twice")
            if self.peek() != "=":
                self.error("expected '='")
            self.pos += 1
            kwargs[key] = self.value()
            if self.peek() not in ("", " "):
                self.error("expected a space between fields")
        try:
            return cls(**kwargs)
        except TypeError as e:
            raise ProgramError(f"line {self.lineno}: {e}") from None


def parse_instr(line, lineno=0):
    """Inverse of format_instr."""
    return _Parser(line.strip(), lineno).instruction()


def assemble(text, config):
    """Parse disassemble() output back into {unit: [instructions]} in canonical unit order.

    Blank lines and lines starting with ';' are ignored.
    """
    units = config.units()
    queues = {}
    current = None
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("unit ") or line == "unit":
            name = line[len("unit"):].strip()
            if name not in units:
                raise ProgramError(f"line {lineno}: unknown unit {name!r}")
            if name in queues:
                raise ProgramError(f"line {lineno}: unit {name} given twice")
            queues[name] = []
            current = name
            continue
        if current is None:
            raise ProgramError(f"line {lineno}: instruction before any 'unit' line")
        queues[current].append(parse_instr(line, lineno))
    return {u: queues[u] for u in units if u in queues}


# =============================================================================
# Static expansion
# =============================================================================
def dispatch_times(queue, config):
    """[(cycle, instr)] for every dispatch of one queue, by the table of plan 2.6.

    Assumes the Notify is dispatched at cycle 0 (B14), so the element after the
    leading Sync or Notify starts at cycle config.barrier_cycles (T15).  A data
    instruction occupies 1 cycle, Nop(n) n cycles (T14), and Repeat(n, d)
    n * d cycles, re-dispatching the previous data instruction on the last
    cycle of each block of d (T18).  At most one dispatch per cycle (T16).
    A queue without a leading Sync/Notify starts at cycle 0.
    """
    out = []
    t = 0
    last = None
    for i, instr in enumerate(queue):
        if isinstance(instr, (isa.Sync, isa.Notify)):
            if i != 0:
                raise ProgramError(f"{type(instr).__name__} at position {i}; only allowed first")
            t = config.barrier_cycles
        elif isinstance(instr, isa.Nop):
            t += instr.n
            last = None
        elif isinstance(instr, isa.Repeat):
            if last is None:
                raise ProgramError(f"Repeat at position {i} not preceded by a data instruction")
            c = out[-1][0]
            for k in range(1, instr.n + 1):
                out.append((c + k * instr.d, last))
            t += instr.n * instr.d
        else:
            out.append((t, instr))
            last = instr
            t += 1
    return out
