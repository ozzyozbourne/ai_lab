# Chapter 11: EAL Services in One Evolving App

Timers, service cores, alarms, keepalive, a control shell and app options.
Open `index.html` in a browser (works from `file://`, no network needed).

## What is here

| Path | What |
|---|---|
| `index.html`, `ch11.js` | The chapter page and its widgets (evolving app, timer skiplist stepper, service mapping matrix, keepalive watchdog, cmdline token matcher) |
| `code/evolve/app_common.h` | The unchanging part of the app: chapter 10's mini_l2fwd as helpers (ports, inject, forward pass, counters) |
| `code/evolve/step1_timer.c` | Step 1: PERIODICAL stats timer + SINGLE stop timer, `rte_timer_manage()` every 100 us |
| `code/evolve/step2_service.c` | Step 2: the stats work as a service on service lcore 2 (`-l 0,2 -S 2`), runstates, stats, shutdown order |
| `code/evolve/step3_keepalive.c` | Step 3: keepalive watchdog; `--stall-after 3` makes the worker hang and the failure callback fire |
| `code/evolve/step4_cli.c` | Step 4: cmdline shell on the main lcore (`show stats`, `set burst N`, `show keepalive`, `stall`, `help`, `quit`); timers moved to the service lcore |
| `code/evolve/step5_options.c` | Step 5 (final app): `rte_argparse` options + `rte_cfgfile` (`app.ini`), precedence default < file < command line |
| `code/alarm_demo.c` | EAL alarms: where they run (`dpdk-intr`), re-arming, cancel semantics, why never to block |
| `code/toolbox.c` | Appendix: rte_common.h macros, rand, bitset/bitmap, reciprocal, errno/strings, hexdump, TAILQ, uuid |
| `code/solutions/` | Exercise solutions: ex1 (timers driven by a service), ex3 (cost of `rte_timer_manage()`), ex4 (`--burst` range check in argparse) |
| `code/app.ini`, `bad.ini`, `cmds.list` | Config files and the command list for `dpdk-cmdline-gen.py` |
| `code/run.sh`, `code/Makefile` | Build and run everything; `expected_output.txt` is the real captured output |

## How to run

```sh
source <path>/dpdk-env.sh          # PKG_CONFIG_PATH and DPDK_SRC
cd code
make                               # static link via pkg-config libdpdk, -Wall -Wextra
./run.sh                           # or: ./run.sh 2>&1 | tee expected_output.txt
```

Every run uses `--no-pci --no-huge -m 64..256`, two `net_ring` loopback vdevs,
a unique `--file-prefix=ch11-*` and `timeout -s INT`. At most 3 lcores are
used (`-l 0-2 -S 2`). Nothing touches a real NIC; no veth, tap or netns is
created. `run.sh` also runs the prebuilt samples `dpdk-timer`,
`dpdk-service_cores`, `dpdk-l2fwd-keepalive`, `dpdk-l2fwd-jobstats` and
`dpdk-cmdline` from `$DPDK_SRC/build/examples`.

Single step by hand, for example the shell:

```sh
./step4_cli -l 0-2 -S 2 --no-pci --no-huge -m 128 --file-prefix=ch11-s4 \
    --vdev=net_ring0 --vdev=net_ring1
```

`-DALLOW_EXPERIMENTAL_API` is needed because `rte_argparse_parse()` and the
`rte_bitset` functions are experimental in DPDK 26.11.
