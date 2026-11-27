# Chapter 9: Testing Without Hardware: Buses, devargs, Virtual PMDs and testpmd

Open `index.html` in a browser (works from `file://`, no network needed).

## What is here

- `index.html`, `ch09.js`: the chapter and its six widgets (same app/many
  backends, device model explorer, vdev probe stepper, AF_XDP rings,
  measured throughput ladder, testpmd forward modes).
- `code/kvargs_demo.c`: `rte_kvargs_parse/process/process_opt/count/get`, the
  devargs stored for a `--vdev`, and `rte_devargs_parse()`.
- `code/vdev_runtime.c`: `rte_vdev_init()`, `rte_dev_probe()`, `rte_vdev_uninit()`,
  `rte_dev_remove()` at run time, including the failure cases.
- `code/devargs_iter.c`: `RTE_DEV_FOREACH` and `RTE_ETH_FOREACH_MATCHING_DEV`
  with many filters; `-- --crash` reproduces a 26.11 iterator crash.
- `code/testpmd_recipes.sh` + `code/recipes/*.txt`: nine testpmd recipes and the
  "testpmd as a debugger" runs (vhost-user + virtio_user, net_null + hotplug).
- `code/ladder.sh`: software-PMD throughput ladder (median of 5), writes `ladder.csv`.
- `code/lib.sh`: shared helpers and the cleanup trap; `mkpcap.py`, `read_pcap.py`,
  `count_flows.py`, `sendraw.py`: Python packet helpers (run with `python3 -I`).
- `code/solutions/`: exercise 1 (flowgen flow count) and 2 (csum flags).
- `code/expected_output.txt`: real output captured on the course VM.

## How to run

```sh
source /path/to/dpdk-env.sh          # puts pkg-config and dpdk-testpmd on PATH
cd code
make                                 # builds the three C programs (-Wall -Wextra, static)
sudo ./run.sh                        # everything, ~9 minutes; LADDER=0 skips the ladder
./testpmd_recipes.sh                 # only the recipes
./ladder.sh                          # only the ladder (RUNS=5 SECS=5 by default)
```

Root is needed for the tap and veth labs. Every run uses `--no-pci`,
`--no-huge -m <= 256`, a unique `--file-prefix=ch09-*`, `timeout -s INT`, and
`--total-num-mbufs` for testpmd. The scripts create only `ch09tap0`, veths
`ch09a/ch09b` and `ch09c/ch09d`, and sockets `/tmp/ch09-*.sock`, and remove them
(plus `/run/dpdk/ch09-*`) in a trap. They never touch `eth0`.

Not runnable here: binding a real NIC with `dpdk-devbind.py` (no spare NIC, and
the tool needs `lspci`, which is missing; the captured error is in the output).
