#!/bin/bash
# Exercise 2 solution: list the net PMDs embedded in a static binary.
# dpdk-pmdinfo.py reads the "PMD_INFO_STRING=" JSON blobs that
# RTE_PMD_REGISTER_* macros place in the binary (see buildtools/pmdinfogen.py).
source "${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}"
BIN=${1:-./hello}
dpdk-pmdinfo.py "$BIN" | python3 -c '
import json, sys
d = json.load(sys.stdin)
net = sorted(x["name"] for x in d if x["name"].startswith("net_"))
print(f"{len(d)} drivers, {len(net)} net PMDs:")
for n in net:
    print("  ", n)'
