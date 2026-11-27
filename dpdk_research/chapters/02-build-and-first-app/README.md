# Chapter 02: Building DPDK and Your First Application

Open `index.html` in a browser (works from `file://`, no network needed).

Topics: the DPDK source tree and meson/ninja build, the installed layout and
version numbers, `pkg-config` (static vs shared), driver constructors and the
`--whole-archive` pitfall, `main()` anatomy and the `--` separator, the shared
build's insecure-plugin-path failure (and a private mount-namespace fix), a
meson consumer project, and a first look at `testpmd` and the skeleton.

## Code (`code/`)

| File | What it shows |
|---|---|
| `hello.c` | helloworld from scratch: `rte_eal_init`, `rte_version`, launch on lcores, port count, `rte_eal_cleanup` |
| `args.c` | `argc -= ret; argv += ret;` and `getopt_long` for app options after `--` |
| `ports.c` | built twice: `ports_ok` (pkg-config --static) and `ports_broken` (no `--whole-archive`) |
| `hello_shared` | `hello.c` linked against the shared libraries (fails here, fixed with `unshare -m`) |
| `mesonapp/` | two-file meson project linking DPDK statically; `-Dlink_mode=declare_dep` shows the meson pitfall |
| `first_look.sh` | `dpdk-skeleton` and `testpmd` io forwarding on two `net_null` ports, plus 5 timed runs |
| `solutions/` | `verbose.c` (exercise 1), `pmdinfo.sh` (exercise 2) |
| `Makefile` | `make` builds all; `make pitfall`, `make shared` |
| `run.sh` | builds and runs everything (about 60 s); `--no-first-look` skips the testpmd lab |
| `expected_output.txt` | real output of `./run.sh` on the course machine |

## Run

```sh
source <path>/dpdk-env.sh      # sets PKG_CONFIG_PATH, DPDK_SRC, DPDK_PREFIX
cd code
./run.sh                       # or: make && ./hello -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch02-hello
```

All runs use `--no-pci --no-huge -m 64` (testpmd: `-m 256 --total-num-mbufs=8192`), a
unique `--file-prefix=ch02-*`, and `timeout`. The script removes its runtime
directories and temporary files on exit. The shared-build fix needs root (`unshare -m`).
