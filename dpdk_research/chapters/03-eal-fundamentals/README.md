# Chapter 03: The EAL: Lcores, Launching Work, Threads, Logging and Time

Open `index.html` in a browser (works from `file://`, no network needed).
`ch03.js` holds the chapter widgets (init step-through, lcore/CPU mapper,
remote_launch swimlanes, log routing tree).

Topics: what `rte_eal_init()` does phase by phase, EAL option groups (`-c`/`-s`
deprecated), lcore vs CPU and the `-l`/`--lcores` syntax (`@`, groups,
`--main-lcore`, `-R`), lcore roles, `rte_eal_remote_launch()` and the
WAIT/RUNNING state machine, EAL/control/non-EAL threads, logging with
`RTE_LOG_REGISTER_SUFFIX` and `--log-level`, TSC time and delays, the
"how to measure on this machine" recipe, signals and clean shutdown.

## Code (`code/`)

| File | What it shows |
|---|---|
| `eal_tour.c` | lcore table, launch + return values, `-EBUSY`, `CALL_MAIN`, per-lcore TLS, `rte_thread_register`, `rte_thread_create_control`, `rte_lcore_dump`; `-- --serve N` mode for the /proc thread anatomy and SIGINT handling |
| `log_lab.c` | custom logtypes `user.ch03app[.rx]`, levels, patterns, `rte_log_can_log`, `rte_openlog_stream` |
| `tsc_lab.c` | TSC rate check, clock read costs, `rte_delay_us_block` vs `_sleep` (median/min/max of N=7) |
| `solutions/reverse_wait.c` | exercise 1 |
| `solutions/newline_bad.c` | exercise 3: must FAIL to compile (`make newline_bad`) |
| `solutions/clean_stop.c` | exercise 4: SIGINT stop + hugepage leftovers after SIGKILL |
| `Makefile` | `make` builds all (static, pkg-config, -Wall -Wextra) |
| `run.sh` | builds and runs everything (about 12 s), including the prebuilt `dpdk-helloworld` mapping lab |
| `expected_output.txt` | real output of `./run.sh` on the course machine |

## Run

```sh
source <path>/dpdk-env.sh      # sets PKG_CONFIG_PATH and DPDK_SRC
cd code
./run.sh                       # or: make && ./eal_tour -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch03-tour
```

All runs use `--no-pci --no-huge -m 64` (except exercise 4, which uses `-m 64`
hugepages on purpose), a unique `--file-prefix=ch03-*` and `timeout`. The exit
trap removes `/var/run/dpdk/ch03-*` and `/dev/hugepages/ch03-*map_*`.
