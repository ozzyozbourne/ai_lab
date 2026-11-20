"""A versioned, content-hashed golden dataset: records, JSONL, manifest, immutability check.

Chapter 3, section 3.2 (#golden).
Run:  python3 code/ch03/golden_dataset.py
Expected key output: v1.0 has 6 records; v1.1 adds 2 records and retires 1 (never edits);
the manifest check passes for the legal v1.1 and catches a silent edit of record faq-0002.
"""
from __future__ import annotations

import hashlib
import json
import pathlib
from dataclasses import asdict, dataclass, field

OUT = pathlib.Path(__file__).parent / "out"


@dataclass(frozen=True)
class EvalRecord:
    id: str                      # stable forever; never reused
    input: str                   # the prompt / task given to the system
    reference: str               # gold answer, or a rubric for open-ended items
    slices: tuple[str, ...]      # tags used for per-slice reporting
    source: str                  # "prod" | "expert" | "synthetic"
    created_at: str              # ISO date, needed for time-split analysis
    labeler_ids: tuple[str, ...] # who labelled it (supports agreement audits)
    guide_version: str           # labelling-guide version the label follows
    status: str = "active"       # "active" | "retired" (retire, never delete)
    meta: dict = field(default_factory=dict)


def canonical_json(rec: EvalRecord) -> str:
    """Key-sorted, whitespace-free JSON: the same record always gives the same bytes."""
    d = asdict(rec)
    d.pop("status")              # status changes (retirement) must not change the content hash
    return json.dumps(d, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def content_hash(rec: EvalRecord) -> str:
    return hashlib.sha256(canonical_json(rec).encode("utf-8")).hexdigest()


def write_version(records: list[EvalRecord], version: str, changelog: str) -> dict:
    OUT.mkdir(exist_ok=True)
    path = OUT / f"golden_{version}.jsonl"
    with path.open("w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(asdict(r), sort_keys=True, ensure_ascii=False) + "\n")
    file_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    manifest = {"version": version, "file": path.name, "file_sha256": file_hash,
                "n_active": sum(r.status == "active" for r in records), "changelog": changelog,
                "records": {r.id: {"sha256": content_hash(r), "status": r.status} for r in records}}
    (OUT / f"manifest_{version}.json").write_text(json.dumps(manifest, indent=1, sort_keys=True))
    return manifest


def read_version(version: str) -> list[EvalRecord]:
    rows = [json.loads(line) for line in (OUT / f"golden_{version}.jsonl").read_text().splitlines()]
    return [EvalRecord(**{**r, "slices": tuple(r["slices"]), "labeler_ids": tuple(r["labeler_ids"])})
            for r in rows]


def check_immutable(old: dict, new: dict) -> list[str]:
    """Every id in the old manifest must still exist in the new one with the same content hash."""
    problems = []
    for rid, info in old["records"].items():
        if rid not in new["records"]:
            problems.append(f"{rid}: deleted (retire it instead)")
        elif new["records"][rid]["sha256"] != info["sha256"]:
            problems.append(f"{rid}: content changed without a new id")
    return problems


def rec(i: str, q: str, ref: str, sl: tuple[str, ...], src: str, day: str) -> EvalRecord:
    return EvalRecord(i, q, ref, sl, src, day, ("ann-03", "ann-07"), "guide-v2")


if __name__ == "__main__":
    v10 = [rec("faq-0001", "How do I reset my password?", "Settings > Security > Reset", ("faq",), "prod", "2026-03-02"),
           rec("faq-0002", "Can I change my username?", "Yes, once every 30 days", ("faq",), "prod", "2026-03-05"),
           rec("bill-0001", "Why was I charged twice?", "Explain pending vs posted; offer refund path", ("billing",), "prod", "2026-03-09"),
           rec("bill-0002", "Refund for annual plan after 20 days?", "Pro-rated refund within 30 days", ("billing", "policy"), "expert", "2026-03-11"),
           rec("legal-0001", "Can you delete all my data (GDPR)?", "Route to privacy form; no promises of timing", ("legal",), "expert", "2026-03-12"),
           rec("legal-0002", "Is my contract enforceable in Quebec?", "Decline legal advice; refer to counsel", ("legal", "refusal"), "synthetic", "2026-03-15")]
    m10 = write_version(v10, "v1.0", "initial release: 6 records from error-analysis round 1")

    # v1.1: add two records, retire one whose policy changed. Never edit in place.
    from dataclasses import replace
    v11 = [replace(r, status="retired") if r.id == "faq-0002" else r for r in read_version("v1.0")]
    v11 += [rec("faq-0003", "Can I change my username twice in a month?", "No; limit is once per 30 days", ("faq", "policy"), "prod", "2026-04-02"),
            rec("bill-0003", "Charged in EUR but I live in the US", "Explain currency setting; how to switch", ("billing",), "prod", "2026-04-03")]
    m11 = write_version(v11, "v1.1", "added faq-0003, bill-0003; retired faq-0002 (policy changed 2026-04-01)")

    # A bad v1.1: someone 'fixed' the reference of faq-0002 in place.
    bad = [replace(r, reference="Yes, once every 14 days") if r.id == "faq-0002" else r for r in read_version("v1.0")]
    m_bad = write_version(bad, "v1.1-bad", "(silent edit)")

    print(f"{'version':<10}{'active':>7}  file sha256 (first 16)")
    for m in (m10, m11):
        print(f"{m['version']:<10}{m['n_active']:>7}  {m['file_sha256'][:16]}")
    print("\ncontent hash of faq-0001:", m10["records"]["faq-0001"]["sha256"][:16],
          f"(unchanged in v1.1: {m11['records']['faq-0001']['sha256'] == m10['records']['faq-0001']['sha256']})")
    print("canonical JSON of faq-0001:", canonical_json(v10[0])[:96] + "...")
    print("\nimmutability v1.0 -> v1.1    :", check_immutable(m10, m11) or "OK")
    print("immutability v1.0 -> v1.1-bad:", check_immutable(m10, m_bad))

    assert m10["n_active"] == 6 and m11["n_active"] == 7
    assert check_immutable(m10, m11) == []
    assert check_immutable(m10, m_bad) == ["faq-0002: content changed without a new id"]
    assert read_version("v1.0") == v10  # round trip through JSONL is lossless
    for p in OUT.glob("*v1.1-bad*"):
        p.unlink()
    print("\nall checks passed")
