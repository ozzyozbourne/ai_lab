#!/usr/bin/env python3
"""Build a Mojo SlotMap variant, run it interleaved with the Rust reference,
and score it. Usage: compare.py <variant> [--rounds N] [--scale S] [--note ...]

Score = Mojo/Rust time ratio per (workload, size); <1.0 means Mojo is faster.
Times are in CPU cycles per op (each bench normalizes by a calibration
loop, so clock-speed drift cancels). The ratio is the median over rounds of
back-to-back paired runs; the cycle columns show each side's best run.
Appends a row to results/log.tsv and writes results/<variant>.tsv.
"""
import argparse, math, os, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(ROOT, "rust_bench/target/release/rust_bench")


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, capture_output=True, **kw)


def run(binary, scale, cpu, only=""):
    cmd = [binary, str(scale)] + ([only] if only else [])
    if cpu is not None and shutil.which("taskset"):
        cmd = ["taskset", "-c", str(cpu)] + cmd
    out = sh(cmd).stdout
    res = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) >= 4 and p[2] not in ('NaN', 'nan') and float(p[2]) > 0:
            res[(p[0], int(p[1]))] = (float(p[2]), p[3])
    return res


def substitute(src, name, pairs):
    text = open(src).read()
    for old, new in pairs:
        assert old in text, old
        text = text.replace(old, new)
    out = os.path.join(ROOT, "build", name)
    with open(out, "w") as f:
        f.write(text)
    return out


def make_pop_bench(src):
    """Variant of the bench whose removals use the Mojo-idiomatic
    `pop(key) raises` (as Dict.pop does) instead of `remove() -> Optional`."""
    text = open(src).read()
    for tag, var in (("REMOVE-I", "i"), ("REMOVE-J", "j")):
        old = ("        if case .Some(v) = sm.remove(kp[unsafe_offset=%s]):  # %s\n"
               "            sum += v\n" % (var, tag))
        new = ("        try:\n            sum += sm.pop(kp[unsafe_offset=%s])\n"
               "        except:\n            pass\n" % var)
        assert old in text
        text = text.replace(old, new)
    out = os.path.join(ROOT, "build", "bench_pop.mojo")
    with open(out, "w") as f:
        f.write(text)
    return out


def make_unrolled_bench(src):
    """Variant of the bench whose lookup driver loop is unrolled 4x by hand.
    rustc/LLVM unrolls the equivalent Rust loop automatically; Mojo 1.2.0
    does not unroll loops."""
    text = open(src).read()
    old = ("    for i in range(n):\n"
           "        if case .Some(p) = sm.get(kp[unsafe_offset=i]):\n"
           "            sum += p[]\n")
    one = ("        if case .Some(p) = sm.get(kp[unsafe_offset=i%s]):\n"
           "            sum += p[]\n")
    new = ("    var i = 0\n    while i + 4 <= n:\n"
           + "".join(one % x for x in ("", " + 1", " + 2", " + 3"))
           + "        i += 4\n    while i < n:\n"
           + (one % "").replace("        ", "        ", 1)
           + "        i += 1\n")
    assert old in text
    text = text.replace(old, new)
    out = os.path.join(ROOT, "build", "bench_unrolled.mojo")
    with open(out, "w") as f:
        f.write(text)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("variant")
    ap.add_argument("--rounds", type=int, default=7)
    ap.add_argument("--scale", type=float, default=0.4)
    ap.add_argument("--cpu", type=int, default=2)
    ap.add_argument("--note", default="")
    ap.add_argument("--only", default="", help="comma-separated workload substrings")
    ap.add_argument("--bench", default="bench.mojo")
    ap.add_argument("--unroll-lookups", action="store_true",
                    help="hand-unroll the Mojo lookup driver loop 4x, as rustc "
                         "does automatically for the Rust one")
    ap.add_argument("--optional-remove", action="store_true",
                    help="time remove() -> Optional[V] instead of pop() raises")
    a = ap.parse_args()

    # "final" is the top-level slotmap.mojo; anything else is a step of the
    # hill climb under variants/.
    vdir = ROOT if a.variant == "final" else os.path.join(ROOT, "variants", a.variant)
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    mojo_bin = os.path.join(ROOT, "build", "bench_" + a.variant)
    bench_src = os.path.join(ROOT, a.bench)
    has_pop = "def pop(" in open(os.path.join(vdir, "slotmap.mojo")).read()
    vsrc = open(os.path.join(vdir, "slotmap.mojo")).read()
    if "def key_to_ffi(" in vsrc:
        bench_src = substitute(bench_src, "bench_ffi.mojo", [(
            "    return k.as_ffi()  # KEY-FFI\n",
            "    return Map.key_to_ffi(k)\n")])
    if has_pop and not a.optional_remove:
        bench_src = make_pop_bench(bench_src)
    if a.unroll_lookups:
        bench_src = make_unrolled_bench(bench_src)
    r = subprocess.run(
        ["mojo", "build", "-I", vdir, bench_src, "-o", mojo_bin],
        text=True, capture_output=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit("mojo build failed")
    if not os.path.exists(RUST):
        sh(["cargo", "build", "--release"], cwd=os.path.join(ROOT, "rust_bench"))

    # The VM clock drifts between discrete speed levels on a timescale of
    # seconds, so the two sides are paired as tightly as possible: for every
    # workload, Rust and Mojo run back to back, and the score is the MEDIAN
    # over rounds of the per-round Mojo/Rust ratio.
    probe = run(RUST, 0.01, a.cpu, a.only)
    workloads = sorted({k[0] for k in probe}, key=[k[0] for k in probe].index)
    sizes = sorted({k[1] for k in probe})
    samples = {"rust": {}, "mojo": {}}
    chk = {"rust": {}, "mojo": {}}
    for rnd in range(a.rounds):
        for w in workloads:
            order = (("rust", RUST), ("mojo", mojo_bin))
            if rnd % 2:
                order = order[::-1]
            for side, binary in order:
                for k, (ns, c) in run(binary, a.scale, a.cpu, w).items():
                    if k[0] != w:
                        continue  # substring match of another workload
                    samples[side].setdefault(k, []).append(ns)
                    chk[side][k] = c

    def med(xs):
        xs = sorted(xs)
        m = len(xs) // 2
        return xs[m] if len(xs) % 2 else 0.5 * (xs[m - 1] + xs[m])

    rows, bad = [], []
    for n in sizes:
        for w in workloads:
            k = (w, n)
            if k not in samples["mojo"]:
                bad.append((k, "missing"))
                continue
            if chk["rust"][k] != chk["mojo"][k]:
                bad.append((k, "checksum %s != %s" % (chk["rust"][k], chk["mojo"][k])))
            r, m = samples["rust"][k], samples["mojo"][k]
            rows.append((w, n, min(r), min(m), med([y / x for x, y in zip(r, m)])))

    print("%-18s %9s %10s %10s %7s" % ("workload", "n", "rust cyc", "mojo cyc", "ratio"))
    for name, n, rn, mn, ratio in rows:
        flag = "" if ratio <= 1.0 else ("  <" if ratio <= 1.03 else "  <<<")
        print("%-18s %9d %10.3f %10.3f %7.3f%s" % (name, n, rn, mn, ratio, flag))
    ratios = [r[4] for r in rows]
    geo = math.exp(sum(map(math.log, ratios)) / len(ratios))
    worst = max(rows, key=lambda r: r[4])
    wins = sum(1 for x in ratios if x <= 1.0)
    print("\ngeomean %.4f | worst %.3f (%s@%d) | mojo<=rust on %d/%d" % (
        geo, worst[4], worst[0], worst[1], wins, len(ratios)))
    for k, why in bad:
        print("!! CHECKSUM/RESULT PROBLEM", k, why)

    with open(os.path.join(ROOT, "results", a.variant + ".tsv"), "w") as f:
        f.write("workload\tn\trust_cycles\tmojo_cycles\tratio\n")
        for row in rows:
            f.write("%s\t%d\t%.4f\t%.4f\t%.4f\n" % row)
    if a.only:
        sys.exit(1 if bad else 0)  # partial runs are not logged
    log = os.path.join(ROOT, "results", "log.tsv")
    new = not os.path.exists(log)
    with open(log, "a") as f:
        if new:
            f.write("time\tvariant\tgeomean\tworst\tworst_at\twins\ttotal\tchecksums_ok\tnote\n")
        f.write("%s\t%s\t%.4f\t%.3f\t%s@%d\t%d\t%d\t%s\t%s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%S"), a.variant, geo, worst[4], worst[0],
            worst[1], wins, len(ratios), "yes" if not bad else "NO", a.note))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
