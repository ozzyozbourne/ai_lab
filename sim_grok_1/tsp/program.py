"""A compiled program: per-unit instruction queues plus the memory image."""

import json
from dataclasses import dataclass, field, fields, is_dataclass
from typing import Dict, List, Tuple

from . import isa
from .params import ChipConfig


@dataclass(frozen=True)
class TensorLoc:
    """Where a named tensor lives in MEM."""

    name: str
    dtype: str
    n: int                                  # logical length; lanes >= n are padding
    planes: Tuple[Tuple[str, int], ...]     # (MEM unit name, address) for each byte plane


@dataclass
class Program:
    config: ChipConfig
    queues: Dict[str, list] = field(default_factory=dict)             # unit -> instructions, in canonical unit order
    mem_image: Dict[Tuple[str, int], bytes] = field(default_factory=dict)  # (MEM unit, address) -> lanes bytes
    inputs: Dict[str, TensorLoc] = field(default_factory=dict)
    outputs: Dict[str, TensorLoc] = field(default_factory=dict)
    schedule: List[dict] = field(default_factory=list)                # planned routes, in cycles (plan 4.6)
    # (MEM unit, address) -> "tensor#plane": which tensor plane the compiler put there (debug data, ledger B16)
    mem_names: Dict[Tuple[str, int], str] = field(default_factory=dict)

    def to_json(self):
        """Canonical text form; byte-identical for equal programs."""
        doc = {
            "config": self.config.to_dict(),
            "queues": [[u, [instr_to_obj(i) for i in q]] for u, q in self.queues.items()],
            "mem_image": [[u, a, data.hex()] for (u, a), data in sorted(self.mem_image.items())],
            "inputs": [_loc_to_obj(v) for _, v in sorted(self.inputs.items())],
            "outputs": [_loc_to_obj(v) for _, v in sorted(self.outputs.items())],
            "schedule": self.schedule,
            "mem_names": [[u, a, name] for (u, a), name in sorted(self.mem_names.items())],
        }
        return json.dumps(doc, sort_keys=True, separators=(",", ":"))

    @classmethod
    def from_json(cls, text):
        doc = json.loads(text)
        return cls(
            config=ChipConfig.from_dict(doc["config"]),
            queues={u: [instr_from_obj(o) for o in q] for u, q in doc["queues"]},
            mem_image={(u, a): bytes.fromhex(h) for u, a, h in doc["mem_image"]},
            inputs={o["name"]: _loc_from_obj(o) for o in doc["inputs"]},
            outputs={o["name"]: _loc_from_obj(o) for o in doc["outputs"]},
            schedule=doc["schedule"],
            mem_names={(u, a): name for u, a, name in doc.get("mem_names", [])},
        )


def _loc_to_obj(loc):
    return {"name": loc.name, "dtype": loc.dtype, "n": loc.n, "planes": [list(p) for p in loc.planes]}


def _loc_from_obj(o):
    return TensorLoc(o["name"], o["dtype"], o["n"], tuple((u, a) for u, a in o["planes"]))


_CLASSES = {
    c.__name__: c
    for c in (isa.Sync, isa.Notify, isa.Nop, isa.Repeat, isa.Read, isa.Write, isa.Vxm,
              isa.Iw, isa.Abc, isa.Distribute, isa.Permute, isa.Shift)
}


def instr_to_obj(instr):
    """Instruction -> JSON-serialisable dict."""
    obj = {"i": type(instr).__name__}
    for f in fields(instr):
        obj[f.name] = _enc(getattr(instr, f.name))
    return obj


def instr_from_obj(obj):
    cls = _CLASSES[obj["i"]]
    kwargs = {}
    for f in fields(cls):
        kwargs[f.name] = _dec(f.name, obj[f.name])
    return cls(**kwargs)


def _enc(v):
    if isinstance(v, isa.StreamRef):
        return {"dir": v.dir, "s": v.s}
    if is_dataclass(v):
        raise TypeError(v)
    if isinstance(v, tuple):
        return [_enc(x) for x in v]
    return v


def _dec(name, v):
    if isinstance(v, dict):
        return isa.StreamRef(v["dir"], v["s"])
    if isinstance(v, list):
        if name == "entries":
            return tuple((row, isa.StreamRef(ref["dir"], ref["s"])) for row, ref in v)
        return tuple(v)
    return v
