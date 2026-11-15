#!/usr/bin/env python3
"""Interleaved A/B timing of several bench binaries on a workload filter.
Usage: ab.py <filter> <rounds> <binary>... ; prints min and median ns/op."""
import subprocess, sys
flt, rounds, bins = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
res = {}
for r in range(rounds):
    for b in (bins if r % 2 == 0 else bins[::-1]):
        out = subprocess.run(["taskset", "-c", "2", b, "0.4", flt], text=True,
                             capture_output=True).stdout
        for line in out.splitlines():
            p = line.split("\t")
            if len(p) >= 4 and p[2] not in ('NaN', 'nan') and float(p[2]) > 0:
                res.setdefault((p[0], int(p[1])), {}).setdefault(b, []).append(float(p[2]))
names = [b.split("/")[-1].replace("bench_", "").replace("b_", "") for b in bins]
print("%-22s %8s  " % ("workload", "n") + "  ".join("%14s" % n[:14] for n in names))
for k in res:
    cells = []
    for b in bins:
        xs = sorted(res[k][b])
        cells.append("%6.3f/%6.3f " % (xs[0], xs[len(xs) // 2]))
    print("%-22s %8d  " % k + "  ".join("%14s" % c for c in cells))
