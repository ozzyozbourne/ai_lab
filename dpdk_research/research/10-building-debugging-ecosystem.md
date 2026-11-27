# Research note 10: Building, debugging, tooling, ecosystem, and the capstone UDP/IP responder

Scope: developer workflow around DPDK 26.11.0. Topics: meson/ninja, pkg-config, static vs shared linking, writing an app (skeleton), cmdline, logging, telemetry, rte_trace, proc-info, debugging, testing (dpdk-test, meson test, DTS), contributing, ABI/API policy, cross-compiling, Windows/FreeBSD, real deployments, and a capstone: a user-space ARP + ICMP + UDP echo responder.

Every experiment below was run on this machine (DPDK 26.11.0 installed under `$DPDK_PREFIX`, static default, 4-core VM). Working code from the experiments is in `/home/user/ai_lab/dpdk_research/research/10-examples/`.

---

## 0. Facts about THIS environment the course planner must know (verified)

1. **Use static linking for every example.** The install prefix is under `/tmp/...`. With a shared-linked app, EAL always adds the default PMD directory (`RTE_EAL_PMD_PATH`, here `.../dpdk-install/lib/x86_64-linux-gnu/dpdk/pmds-27.0`). `verify_perms()` in `lib/eal/common/eal_common_options.c` walks every parent directory and rejects any that is world-writable (`S_IWOTH`). `/tmp` is world-writable, so the run aborts:
   ```
   EAL: Error, directory path /tmp is world-writable and insecure
   EAL: Cannot init plugins
   ```
   The shared build compiles fine and makes a good lesson ("why did my shared app abort?"), but it cannot run here. It also needs `LD_LIBRARY_PATH`: `ldd` shows `librte_eal.so.27 => not found`.
2. **`tests=false` in this build.** `dpdk-test` and `meson test` are not available. Reconfiguring and building `app/test` is a heavy build and is forbidden. Teach the unit-test framework from source (`app/test/test.h`, `app/test/test_version.c`) and show transcripts from the docs. A small home-made "xUnit-style" test harness can mimic `unit_test_suite_runner`.
3. **Tools that are installed** (in `$DPDK_PREFIX/bin`): dpdk-testpmd, dpdk-proc-info, dpdk-dumpcap, dpdk-pdump, dpdk-graph, dpdk-test-eventdev, dpdk-test-crypto-perf, dpdk-test-flow-perf, dpdk-telemetry.py, dpdk-telemetry-watcher.py, dpdk-telemetry-exporter.py, dpdk-cmdline-gen.py, dpdk-pmdinfo.py, dpdk-devbind.py, dpdk-hugepages.py, dpdk-rss-flows.py. All examples are prebuilt in `$DPDK_SRC/build/examples/dpdk-*`, including skeleton, helloworld, cmdline, l2fwd and l3fwd.
4. **Tools that are missing:** `ping`, `tcpdump`, `scapy`, `babeltrace`/`babeltrace2`, `perf`. Present: `nc`, `gdb`, `valgrind`, `python3`, `meson 1.12.1`, `ninja`. Traffic tests use Python sockets: UDP sockets, and raw ICMP sockets for ping.
5. **Buffered output.** stdout from an app redirected to a file is fully buffered, and a `timeout -s INT` kill loses the output (seen with dpdk-skeleton). Use `stdbuf -oL`, or `fflush` and `setvbuf` in course code.
6. **testpmd flags.** testpmd has no `--no-interactive`. Non-interactive is the default; use `--stats-period=N` and stop it with SIGINT.
7. **Secondary processes.** dpdk-proc-info and other secondaries need a primary that uses real hugepages and a `--file-prefix`, not `--in-memory`. `-m 64` works: 992 of the 1024 shared 2 MB pages were free when tested.

---

## 1. Recommended teaching order (easy to hard)

1. **Build system tour.** Meson/ninja concepts, `meson setup`, `meson configure`, options, `rte_build_config.h`, and how library and driver selection works.
2. **Consuming DPDK.** pkg-config, `libdpdk.pc`, static vs shared, `--whole-archive`, `-include rte_config.h`, `-march=native`. Build helloworld/skeleton from a Makefile and from your own meson project.
3. **First real app: the skeleton.** EAL init → mempool → port configure/queues/start → rx/tx burst loop → cleanup. Run it on `net_ring`/`net_null` vdevs.
4. **Logging.** `RTE_LOG_REGISTER*`, `--log-level` patterns, `--log-level=help`, `--log-timestamp`, `--syslog`, and the `RTE_LOG_DEFAULT_LOGTYPE` pitfall.
5. **Interactive control: the cmdline library.** Manual tokens, then `dpdk-cmdline-gen.py`.
6. **Observability I: telemetry.** Built-in endpoints, `dpdk-telemetry.py`, a hand-written SEQPACKET client, registering your own endpoint, FOREACH, the watcher and exporter tools.
7. **Observability II: proc-info and the secondary process model.** Stats, xstats, mempool, memory and ring dumps from outside the app.
8. **Observability III: rte_trace.** Tracepoints, CTF output, fast-path vs slow-path tracepoints, record modes.
9. **Debugging.** gdb, `rte_panic`/`rte_dump_stack`, ASan (`-Db_sanitize`), mbuf/mempool debug options, `buildtype=debug`, `RTE_LIBRTE_*_DEBUG`, the troubleshooting decision tree, packet capture with dumpcap/pdump.
10. **Testing.** dpdk-test (REGISTER_*_TEST, unit_test_suite_runner), meson test suites, DTS (Python, SUT/TG nodes).
11. **Contributing.** Mailing-list workflow, checkpatches, `Fixes:`/`Cc: stable`, MAINTAINERS, patchwork/CI, AGENTS.md (AI review guidelines in the tree).
12. **ABI/API policy and symbol versioning.** ABI_VERSION 27.0, sonames, LTS, `__rte_experimental`, `__rte_internal`, `RTE_EXPORT_SYMBOL`, `RTE_VERSION_SYMBOL`/`RTE_DEFAULT_SYMBOL`.
13. **Portability.** Cross-compiling with meson cross files (arm64, riscv, loongarch, mingw), Windows and FreeBSD specifics.
14. **Ecosystem and real deployments.** OVS-DPDK, VPP, SPDK, Suricata, TRex, Pktgen, F-Stack, Seastar, eRPC, cloud PMDs.
15. **Capstone.** A minimal user-space UDP/IP responder (ARP + ICMP echo + UDP echo) on net_tap and on veth+af_packet in a netns, instrumented with telemetry, logging and cmdline.

---

## 2. Build system (meson + ninja)

### Concepts
- **Two-phase build.** `meson setup <builddir> [-Dopt=val]` configures and writes `build.ninja`. `ninja -C <builddir>` builds. `meson install` (honours `DESTDIR`) installs. Once a build dir exists, you cannot run `meson setup` on it again: use `meson configure <builddir> -Dx=y`, and ninja re-runs meson automatically. Minimum meson is 0.61 on Linux and 1.5.2 on Windows.
- **Built-in meson options:** `buildtype` (debug/debugoptimized/release/plain), `default_library` (static/shared), `werror`, `b_sanitize`, `b_lto`, `b_lundef`, `prefix`, `libdir`.
- **DPDK options** (`meson_options.txt`): `platform` (native/generic/<SoC>), `cpu_instruction_set` (auto/generic/...), `max_lcores`, `max_numa_nodes`, `max_ethports`, `enable_drivers`/`disable_drivers` (globs such as `net/*,event/*`), `enable_libs`/`disable_libs`, `enable_apps`/`disable_apps`, `examples` (`all` or a list), `tests`, `enable_docs`, `enable_trace_fp`, `enable_iova_as_pa`, `pkt_mbuf_headroom`, `mbuf_refcnt_atomic`, `enable_stdatomic`, `developer_mode`, `check_includes`, `enable_driver_sdk`, `drivers_install_subdir` (default `dpdk/pmds-<VERSION>`), `use_hpet` (deprecated), `ibverbs_link`.
- **This machine's config** (`$DPDK_SRC/build/meson-info/intro-buildoptions.json`): buildtype=release, default_library=static, tests=false, examples=all, an enable_drivers list of about 26 drivers, and enable_apps=test-pmd,proc-info,dumpcap,pdump,test-eventdev,test-crypto-perf,test-flow-perf,graph.
- **Generated config.** `build/rte_build_config.h` holds about 128 `#define`s: `RTE_MAX_LCORE 128`, `RTE_MAX_ETHPORTS 32`, `RTE_CACHE_LINE_SIZE 64`, `RTE_NET_TAP 1` (one per enabled driver/lib), `RTE_EAL_PMD_PATH`, `RTE_VER_*`. It is included through `config/rte_config.h`, which pkg-config injects with `-include rte_config.h`. Apps can test `#ifdef RTE_NET_TAP` for optional features.
- **Both kinds of libraries are always built.** The install dir has 249 `.so` files plus the `.a` files. `default_library` only decides how DPDK's own apps and examples link. Libraries are `librte_<name>.{a,so.27.0}`; drivers are `librte_<class>_<name>`, e.g. `librte_net_null.a`.
- **Source tree map** (`doc/guides/prog_guide/source_org.rst`): `lib/` (eal, ethdev, mbuf, ...), `drivers/<class>/<name>`, `app/`, `examples/`, `buildtools/` (pmdinfogen.py, gen-version-map.py, dpdk-cmdline-gen.py, chkincs), `devtools/` (checkpatches.sh, test-meson-builds.sh, check-abi.sh, get-maintainer.sh), `usertools/`, `config/` (per-arch and per-SoC cross files), `dts/`, `doc/`, `kernel/` (freebsd contigmem/nic_uio). Also `ABI_VERSION` (27.0) and `VERSION` (26.11.0).
- **Per-library meson.** `lib/meson.build` loops over each library and adds `-DRTE_LOG_DEFAULT_LOGTYPE=lib.<name>` (line ~237). Each library's `meson.build` sets `sources`, `headers`, `deps`. Drivers work the same way through `drivers/meson.build`, which runs **pmdinfogen**: it scans object files for `RTE_PMD_REGISTER_*` info and embeds a JSON "PMD info string". `dpdk-pmdinfo.py <binary>` reads it back. Verified: it lists the 25 drivers inside a static binary, with `params` strings such as `net_af_packet iface=<string> qpairs=<int> ...`.
- **Driver registration.** `RTE_PMD_REGISTER_VDEV(net_null, pmd_null_drv)` (`drivers/net/null/rte_eth_null.c:775`) and `RTE_PMD_REGISTER_PARAM_STRING`. These expand to `RTE_INIT` constructors (`__attribute__((constructor))`) that register with the bus before `main()`. This is why static links need `--whole-archive`: nothing references driver symbols, so the linker would otherwise drop them.

### Example commands (from `prog_guide/build-sdk-meson.rst`)
```
meson setup build && ninja -C build && meson install
meson setup -Dexamples=l3fwd,l2fwd -Ddisable_drivers=event/*,net/tap -Dmax_lcores=8 build
meson setup --buildtype=debug -Db_sanitize=address dbg
meson setup -Denable_trace_fp=true tracebuild
meson setup -Dcpu_instruction_set=generic portable
meson configure build -Dexamples=helloworld   # change an existing dir
ninja -C build -j1 -v                         # serial, verbose
```
Do not actually rebuild DPDK in the course runs. `meson configure $DPDK_SRC/build` (read-only listing) is fine to show the options.

### Visualizations
- An animated **pipeline**: `meson.build` files → meson (introspects the compiler, finds deps such as libpcap/libbpf/openssl) → `build.ninja` + `rte_build_config.h` → ninja DAG (animate parallel compile nodes lighting up) → `.a`/`.so` + pmdinfo → `meson install` → `libdpdk.pc`.
- An **option explorer**: toggle `disable_drivers` globs and show which driver boxes grey out and which `RTE_NET_*` defines disappear.

---

## 3. Consuming DPDK: pkg-config, static vs shared, and your own build

### pkg-config output on this machine
- `pkg-config --cflags libdpdk` gives `-I<prefix>/include -include rte_config.h -march=native -mrtm` plus dbus/libnl include dirs. `-march=native` comes from `platform=native`. Binaries built this way may not run on older CPUs; that is the reason `cpu_instruction_set=generic` exists.
- `pkg-config --libs libdpdk` (shared) gives `-Wl,--as-needed -L... -lrte_node ... -lrte_log` (about 60 libs). With `--as-needed`, the final binary only needs 3 DPDK .so files for the devapp demo.
- `pkg-config --static --libs libdpdk` gives `-Wl,--whole-archive -l:librte_bus_pci.a ... -l:librte_crypto_openssl.a ... -Wl,--no-whole-archive` for the drivers, then the libs, then system libs (-lnuma, -lpcap, -lbpf, -lxdp, -lcrypto, ...). The `libdpdk.pc`/`libdpdk-libs.pc` split exists to produce this ordering.

### Measured on this machine
| build | command | size | notes |
|---|---|---|---|
| static | `gcc devapp.c -o x $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)` | 5.1 MB | all 25 PMDs embedded (pmdinfo), "EAL: Detected static linkage of DPDK" |
| shared | `... $(pkg-config --libs libdpdk)` | 17 KB | needs LD_LIBRARY_PATH; aborts here because of the `/tmp` world-writable plugin dir check |
| meson `dependency('libdpdk')` | shared | 109 KB | `ldd` shows 30 librte libs |
| meson `dependency('libdpdk', static: true)` | — | link FAILS | meson resolves *all* deps statically (libsystemd.a needs libcap: `undefined reference to cap_get_proc`) |
| meson `declare_dependency(link_args: <pkg-config --static --libs>)` | links | 1.1 MB | **silently has 0 PMDs**: meson deduplicated and reordered the flags into `-Wl,--whole-archive -Wl,--no-whole-archive -l:librte_bus_pci.a ...`. At runtime `--vdev=net_null0` fails with "EAL: Unable to open directory" |

Teaching points:
- For static linking outside the DPDK tree, a plain Makefile with `pkg-config --static --libs` is the reliable way (it is what `examples/*/Makefile` does: `build/$(APP)-static` and `build/$(APP)-shared` targets, `PC_FILE := $(shell pkg-config --path libdpdk)`).
- Always check that drivers are present with `dpdk-pmdinfo.py ./app`.
- Static linking means EAL does no plugin loading, gives a self-contained binary, and avoids ABI worries. Shared linking means `-d <driver.so|dir>`, an ABI-compatible upgrade path, and smaller binaries. Shared builds can load PMDs at runtime from `RTE_EAL_PMD_PATH` or `-d`.
- `is_shared_build()` in `eal_common_options.c` decides this by `dlopen("librte_eal.so.27", RTLD_NOLOAD)`. That explains the "Detected static/shared linkage" log line.
- Experimental APIs: the compiler warns `'__rte_trace_point_emit_field' is deprecated: Symbol is not yet part of stable ABI`. Define `ALLOW_EXPERIMENTAL_API` (`-DALLOW_EXPERIMENTAL_API`; meson: `allow_experimental_apis = true` inside the tree). `ALLOW_INTERNAL_API` exists for `__rte_internal`. The definitions are in `lib/eal/include/rte_compat.h`.

### Visualization
- A **linker animation**: object files and archives fall into the linker. Without `--whole-archive`, driver objects with constructors are "unreferenced" and bounce off. With it, they stick, and their `RTE_INIT` constructors light up before `main()` and register into the bus/driver lists.
- A side-by-side comparison of the static binary (one big box) and the shared binary (small box with arrows to .so files, plus a dlopen arrow to the pmds dir guarded by the permission check).

---

## 4. Writing an application: the skeleton (`examples/skeleton/basicfwd.c`)

Flow: `rte_eal_init(argc, argv)` (it returns the number of args consumed, so do `argc -= ret; argv += ret;` to reach app args after `--`) → `rte_eth_dev_count_avail()` (expects an even number of ports) → `rte_pktmbuf_pool_create("MBUF_POOL", 8191*nb_ports, 250, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id())` → per port `port_init()`:
`rte_eth_dev_info_get` → optional `RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE` → `rte_eth_dev_configure(port, 1, 1, &conf)` → `rte_eth_dev_adjust_nb_rx_tx_desc` → `rte_eth_rx_queue_setup(..., mbuf_pool)` → `rte_eth_tx_queue_setup(..., &txconf)` → `rte_eth_dev_start` → `rte_eth_macaddr_get` → `rte_eth_promiscuous_enable`.
The loop calls `rte_eth_rx_burst(port, 0, bufs, 32)` and then `rte_eth_tx_burst(port ^ 1, ...)`, and frees the mbufs that were not sent. Cleanup is `rte_eal_cleanup()`.

Runnable here:
```
timeout -s INT -k 5 6 stdbuf -oL $DPDK_SRC/build/examples/dpdk-skeleton --no-pci --no-huge -m 256 \
   --file-prefix=ch10sk -l 0 --vdev=net_ring0 --vdev=net_ring1
```
Packets need a source. Use `--vdev=net_null0 --vdev=net_null1`: null RX generates packets endlessly, so the skeleton forwards at line rate. Or pair `net_tap0`/`net_tap1` and inject from the kernel.

### Visualization
An app-lifecycle stepper (EAL → mempool → configure → queue setup → start → loop → stop/close → cleanup) with a port-pair animation: mbufs flowing 0→1 and 1→0, and unsent mbufs falling into a "free" bin.

---

## 5. Logging (`lib/log`, `doc/guides/prog_guide/log_lib.rst`)

- Register a log type with `RTE_LOG_REGISTER(type_var, name, LEVEL)`, `RTE_LOG_REGISTER_DEFAULT(type, LEVEL)` or `RTE_LOG_REGISTER_SUFFIX(type, suffix, LEVEL)`. The macros live in `lib/log/rte_log.h:479-517`. They are `RTE_INIT` constructors that call `rte_log_register_type_and_pick_level`.
- **PITFALL (verified):** `RTE_LOG_REGISTER_DEFAULT` uses `RTE_STR(RTE_LOG_DEFAULT_LOGTYPE)`. The DPDK build defines that macro only for in-tree libs/drivers (`lib/meson.build`: `-DRTE_LOG_DEFAULT_LOGTYPE=lib.<name>`). In an external app the log type gets the literal name "RTE_LOG_DEFAULT_LOGTYPE", so `--log-level=user.devapp:debug` silently does nothing. Use `RTE_LOG_REGISTER(devapp_logtype, user.devapp, INFO)` or define the macro yourself.
- Emit with `rte_log(RTE_LOG_DEBUG, type, fmt, ...)`, `RTE_LOG(level, USER1, ...)` (legacy static types), or `RTE_LOG_LINE(level, type, ...)` (adds the newline). There is also a debug variant that compiles out (see `RTE_LOG_DP*` in rte_log.h).
- EAL options: `--log-level=<pattern>:<level>` (glob or regex, repeatable and applied in order; e.g. `'*:warning'` then `user.devapp:info` was verified to work), `--log-level=help` (lists bus.pci, bus.vdev, lib.acl, ...), `--log-timestamp`, `--log-color`, `--syslog`.
- APIs: `rte_log_set_level_pattern`, `rte_log_set_level_regexp`, `rte_log_set_global_level`, `rte_openlog_stream(FILE*)`, `rte_log_dump`.

---

## 6. cmdline library (`lib/cmdline`, `prog_guide/cmdline.rst`, `examples/cmdline`)

- Six steps: (1) a result struct with one field per token; (2) token initializers: `TOKEN_STRING_INITIALIZER(struct, field, "literal" | NULL | "a#b#c")`, `TOKEN_NUM_INITIALIZER(struct, field, RTE_UINT16)`, `TOKEN_IPADDR_INITIALIZER`, `TOKEN_IPV4_INITIALIZER`, `TOKEN_IPV6_INITIALIZER`, `TOKEN_ETHERADDR_INITIALIZER`, `TOKEN_PORTLIST_INITIALIZER`; (3) a callback `void f(void *parsed_result, struct cmdline *cl, void *data)`; (4) a `cmdline_parse_inst_t` with `.f`, `.data`, `.help_str`, `.tokens = {..., NULL}`; (5) a NULL-terminated `cmdline_parse_ctx_t ctx[]`; (6) `cmdline_stdin_new(ctx, "prompt> ")` + `cmdline_interact(cl)` + `cmdline_stdin_exit(cl)`. Alternatives are `cmdline_new(ctx, prompt, fd_in, fd_out)` and `cmdline_file_new`. `cmdline_printf(cl, ...)` writes output and `cmdline_quit(cl)` ends the session.
- Features: tab completion and `?` help (the rdline layer has emacs-ish line editing and history), several commands sharing one callback, and scripted input.
- **dpdk-cmdline-gen.py** (`buildtools/`, installed in bin). It reads a list file in which each line is a command, with `<TYPE>name` variables and a `# help` comment. Types: STRING, UINT8..64, INT8..64, IP/IPv4/IPv6, and `<(a,b,c)>name` choice lists. **There is no MAC type** (verified: "unknown token type 'MAC'"); MAC tokens must be written manually with `TOKEN_ETHERADDR_INITIALIZER`. Flags: `-o file.h`, `--stubs` (writes `file.c` with callback stubs), and a custom context name. The callbacks are named `cmd_<fixed tokens>_parsed`, and a `__` prefix on a variable puts it into the name.
- Verified demo (`10-examples/cliapp.c` + `cmds.list`): piped stdin `show counter / add 5 / add 7 / show counter / set mode tx / set mode bogus / echo hello / foo / quit` printed `counter=12`, `mode=tx`, `Bad arguments`, `hello` and `Command not found`. Echoed lines contain `^M`. Run it with `printf ... | ./cliapp --no-pci --no-huge -m 32 --in-memory -l 0`.
- Library tests: `app/test-cmdline`, `app/test/test_cmdline*.c`.

### Visualization
A **token-matching automaton**: type "show port stats 3" and watch each token's parser (string, string, string, num) light up, the result struct fill field by field, and the callback fire. Show how an ambiguous prefix triggers completion.

---

## 7. Telemetry (`lib/telemetry`, `prog_guide/telemetry_lib.rst`, `howto/telemetry.rst`)

### Internals (lib/telemetry/telemetry.c)
- It is enabled by default (`--no-telemetry` disables it). The socket is `<runtime_dir>/dpdk_telemetry.v2`. The runtime dir is `/var/run/dpdk/<file-prefix>/` for root. With `--in-memory` and the same prefix, later processes get `dpdk_telemetry.v2:1`, `:2`, and so on (client flag `-i`).
- The socket is an `AF_UNIX`, `SOCK_SEQPACKET` socket. A listener thread starts one `pthread` per connection, with `MAX_CONNECTIONS 10`. On connect the server sends `{"version":"DPDK 26.11.0","pid":N,"max_output_len":16384}`. A request is the command, optionally `,params`. `MAX_CMD_LEN 56`, `MAX_OUTPUT_LEN 16 KiB`. There is also a legacy v1 socket (`telemetry_legacy_init`), created only when legacy callbacks exist.
- Register an endpoint with `rte_telemetry_register_cmd("/lib/cmd", cb, "help")` or `rte_telemetry_register_cmd_arg(cmd, cb, void *arg, help)`. Names may only contain `[A-Za-z0-9_/]`. The callback is `int cb(const char *cmd, const char *params, struct rte_tel_data *d)` and fills `d` with `rte_tel_data_start_dict`/`start_array(d, RTE_TEL_INT_VAL|UINT|STRING|CONTAINER)`, `rte_tel_data_add_dict_{int,uint,string,container,uint_hex}`, `rte_tel_data_add_array_*`, `rte_tel_data_string`, `rte_tel_data_alloc`/`free` (for nested containers). Telemetry serializes `d` to JSON. Callbacks run on the telemetry thread, so shared data needs care (atomics/locks).
- Built-in endpoints seen live: `/`, `/help`, `/info`, `/eal/params`, `/eal/app_params`, `/eal/lcore/list|info|usage`, `/eal/heap_list|heap_info`, `/eal/memzone_list|info`, `/eal/memseg_*`, `/ethdev/list|info|stats|xstats|link_status|macs|dcb|fec|flow_ctrl|dump_priv`, `/cryptodev/*`, `/dmadev/*`, `/mempool/*`, `/ring/*`, `/eventdev/*`, and more. `/eal/lcore/usage` is empty unless the app registers `rte_lcore_register_usage_cb()`. testpmd does that only with `--record-core-cycles`.

### Verified runs
- `dpdk-telemetry.py -l` lists live prefixes. `printf '/devapp/counter\n/help,/devapp/counter\nquit\n' | dpdk-telemetry.py -f ch10dev` returned `{"/devapp/counter": {"counter": 15, "version": "DPDK 26.11.0"}}`.
- With testpmd (`-m 64 --file-prefix=ch10pi --vdev=net_null0 --vdev=net_null1 -- --forward-mode=io --stats-period=100 --total-num-mbufs=2048`), `/ethdev/stats,0` returned `ipackets 546 M` after about 5 s (net_null on 2 lcores), and `/eal/heap_info,0` returned `Heap_size 67108864, Alloc_count 515`.
- A hand-written 10-line Python SEQPACKET client (`10-examples/telclient.py`) works and shows that the protocol is plain JSON over a Unix socket.
- Newer client features (26.11 docs): `FOREACH /ethdev/list /ethdev/stats .opackets`, the loop-var form `FOREACH i /ethdev/list /ethdev/info,$i .name`, alias files (`~/.config/dpdk/telemetry_aliases`), `help FOREACH`. Also `dpdk-telemetry-watcher.py` (a top-like monitor: `-f prefix /ethdev/stats,0.ipackets`, with `-d` for deltas) and `dpdk-telemetry-exporter.py` (Prometheus-style export via `usertools/telemetry-endpoints`).

### Visualization
A **sequence diagram**: the app's main lcore is busy polling, the telemetry thread sleeps in accept(), the client connects, the hello JSON comes back, the client sends `/ethdev/stats,0`, the thread runs the callback, which reads the per-port counters, and JSON comes back. A live dashboard mock-up shows counters ticking as watcher polls (animated).

---

## 8. proc-info and multi-process inspection (`app/proc-info`, `tools/proc_info.rst`)

- It runs as a **secondary process** (`--proc-type=secondary` is implied by its code). It attaches to the primary's hugepage memory through `/var/run/dpdk/<prefix>/config` + `mp_socket`, so it sees the same ports, mempools and rings.
- Options after `--`: `--stats`, `--xstats[=hide_zero]`, `--stats-reset`, `--xstats-reset`, `-m` (memory segments/zones), `--show-port`, `--show-mempool[=name]`, `--iter-mempool=name`, `--show-ring[=name]`, `--show-crypto`, `--show-tm`, `--show-rss-reta`, `--show-rx-descriptor q:off:n`, eventdev xstats, `--version`, `--firmware-version`.
- Verified: `dpdk-proc-info --file-prefix=ch10pi --no-pci --log-level=lib.eal:warning -- --stats` printed NIC stats boxes. `--show-mempool` printed `mb_pool_0`: size 2048, elt_size 2304, total_obj_size 2368, ops `ring_mp_mc`, 3 memory chunks, `cache_size=250`, per-lcore `cache_count[0]=137`. `-m` printed `Segment 0-N: IOVA:..., len:2097152, virt:..., hugepage_sz:2097152, fd:N`. IOVA mode PA was selected with hugepages vs VA with `--no-huge`, which is a nice tie-in.
- Failure mode when there is no primary: "EAL: failed to send to (/var/run/dpdk/<p>/mp_socket) ... No primary DPDK process is running."
- The same primary/secondary mechanism powers `dpdk-pdump` and `dpdk-dumpcap` (pcapng capture from a running app; the app must call `rte_pdump_init()` — testpmd does).

### Visualization
Two processes share the hugepage file-backed memory (shm boxes). The secondary maps the same virtual addresses (show identical virt addrs), and the mp_socket request/response arrows (bus_vdev_mp) appear.

---

## 9. Tracing (`lib/eal/common/eal_common_trace*.c`, `rte_trace.h`, `rte_trace_point.h`, `prog_guide/trace_lib.rst`)

- Define a tracepoint in a header:
  ```c
  #include <rte_trace_point.h>
  RTE_TRACE_POINT(app_trace_tick,
      RTE_TRACE_POINT_ARGS(uint64_t n, const char *tag),
      rte_trace_point_emit_u64(n); rte_trace_point_emit_string(tag);)
  ```
  Register it in exactly one .c file, which must include `rte_trace_point_register.h` *before* `rte_trace_point.h`: `RTE_TRACE_POINT_REGISTER(app_trace_tick, app.tick)`. Emit helpers include `rte_trace_point_emit_{u8..u64,i*,int,long,float,double,ptr,string,blob,size_t}`. The library naming rule is `rte_<lib>_trace_[<domain>_]<name>`. Built-in generic tracepoints are `rte_eal_trace_generic_{void,u64,u32,...,str,ptr,func}` in `rte_eal_trace.h`. **You must `#include <rte_eal_trace.h>`** (verified link error otherwise) and compile with `-DALLOW_EXPERIMENTAL_API` (verified warnings).
- `RTE_TRACE_POINT_FP` creates fast-path tracepoints that are compiled out unless meson has `-Denable_trace_fp=true`. Slow-path tracepoints are always compiled in. A disabled tracepoint costs about 1 cycle (a check of the enabled bit in `rte_trace_point_t`), and an enabled one about 20 cycles.
- Runtime control: `--trace=<regex>` (repeatable), `--trace-dir=`, `--trace-bufsz=` (per-thread), `--trace-mode=o|d` (overwrite/discard). APIs: `rte_trace_regexp`, `rte_trace_pattern`, `rte_trace_point_enable/disable/lookup`, `rte_trace_mode_set/get`, `rte_trace_save`, `rte_trace_dump`, `rte_trace_metadata_dump`, `rte_trace_is_enabled`.
- Output is **CTF** (Common Trace Format, LTTng-compatible). It is saved on `rte_trace_save()` or `rte_eal_cleanup()` into `<trace-dir>/<prefix>-YYYY-MM-DD-[AP]M-hh-mm-ss/` with a `metadata` file (TSDL text; here 112 KB, because it describes every registered event) and per-thread `channel0_N` binary streams. Verified: 4 s of a 10 Hz loop produced a 2552-byte channel0_2 (one per lcore or thread). The memory layout is packet.header (magic + uuid) → packet.context (thread_id, thread_name[32]) → events with a 64-bit header (`event_id[63:48] | timestamp[47:0]`) + payload. Trace memory is per thread (`__rte_trace_mem_per_thread_alloc`), which keeps emission lock-free.
- Viewing: `babeltrace` (not installed here) or Trace Compass. For the course, a tiny Python CTF reader can decode the fixed event header and the u64 payload from `channel0_*`. The `metadata` file is readable text, which is good for showing TSDL. The docs' quick-start uses `echo quit | dpdk-test --no-huge --trace=.*`, which is not available here, so use the devapp.

### Visualization
A **tape recorder** animation (the doc's own metaphor): per-lcore ring buffers fill with event blocks (header bits split into 16-bit id + 48-bit TSC), overwrite vs discard mode at the wrap point, then a "save" that flushes to CTF files and draws the timeline view.

---

## 10. Debugging techniques

- **Build flavours:** `--buildtype=debug` or `debugoptimized` (`-g -O2`). For external apps, `-g -O0` on your own code is often enough; static libs come from a release build here, so they have no symbols.
- **gdb:** `gdb --args ./app --no-huge ...`. Lcores are pthreads named `dpdk-worker<N>`; use `info threads` and `thread apply all bt`. Good breakpoints: `rte_eth_rx_burst` is inline (`rte_ethdev.h`) and calls through `rte_eth_fp_ops[port].rx_pkt_burst`. Break on the PMD function (e.g. `eth_null_rx`) or print `rte_eth_fp_ops[0]`.
- **Crashes:** `rte_panic()` prints a message and a backtrace via `rte_dump_stack()`, then aborts. `rte_exit()` cleans up and exits. EAL installs no SIGSEGV handler by default, so use core dumps. Hugepage memory is not included in cores unless the dump filter is set (`/proc/self/coredump_filter`). FreeBSD has a contigmem coredump knob, `hw.contigmem.coredump_enable`.
- **ASan:** `meson setup -Db_sanitize=address` (clang also needs `-Db_lundef=false`). DPDK instruments `rte_malloc`, so ASan catches overflows of `rte_zmalloc(9)` (`prog_guide/asan.rst`). For an app-only ASan build against non-ASan DPDK, only libc malloc is covered, which is a pitfall. UBSan and valgrind are possible; valgrind works best with `--no-huge`.
- **Library debug knobs:** `RTE_LIBRTE_MBUF_DEBUG`, `RTE_LIBRTE_MEMPOOL_DEBUG`, `RTE_LIBRTE_ETHDEV_DEBUG` (via `-Dc_args=-D...`), `rte_mbuf_sanity_check`, `rte_pktmbuf_dump(stdout, m, len)`, `rte_mempool_audit`, `rte_mempool_dump`, `rte_memzone_dump`, `rte_malloc_dump_stats`, `rte_dump_physmem_layout`. `usertools/dpdk-mbuf-history-parser.py` decodes mbuf history (a new 26.x feature).
- **Packet capture:** `dpdk-dumpcap -i <port>`, `dpdk-pdump` (secondary process, pcapng), the `net_pcap` vdev for offline replay, and `rte_eth_add_rx_callback` taps (`examples/rxtx_callbacks`).
- **Troubleshooting tree** (`howto/debug_troubleshoot.rst`): RX rate mismatch (check config, `rx_nombuf`, `imissed`, per-queue stats), drops at RX/TX, ring producer/consumer stalls (`rte_ring_full/empty` counts), mempool NUMA locality, crypto enqueue/dequeue, service cores, eventdev, TM/WRED, packet format corruption (pdump before and after a stage), and multi-process issues. The diagram for this is a decision flowchart.
- **Profiling:** `perf top`/`perf record` (busy-poll loops show up as 100% CPU; use `rte_lcore_usage` or testpmd `--record-core-cycles` for busy/idle cycles), `rte_rdtsc()` timing, `lib/pmu` (`rte_pmu_read()`; needs `perf_event_paranoid` ≤ 2 and `CAP_PERFMON`), VTune/uProf/Arm SPE (`prog_guide/profile_app.rst`), and LTO (`-Db_lto=true`, `prog_guide/lto.rst`).

---

## 11. Testing

### dpdk-test (`app/test/`)
- Three modes: an interactive `RTE>>` prompt, `DPDK_TEST=version_autotest ./dpdk-test ...`, and command-line args (`dpdk-test ... version_autotest ring_autotest`). Return code 0 means OK. `DPDK_TEST_PARAMS` passes extra parameters.
- Registration: `REGISTER_FAST_TEST(name, NOHUGE_OK|NOHUGE_SKIP, ASAN_OK|ASAN_SKIP, func)`, `REGISTER_PERF_TEST`, `REGISTER_DRIVER_TEST`, `REGISTER_STRESS_TEST`. These macros also generate meson test entries (`buildtools/get-test-suites.py`).
- Structure: `struct unit_test_suite { suite_name, setup, teardown, unit_test_cases[] = { TEST_CASE_ST(setup, teardown, fn), TEST_CASE(fn), TEST_CASES_END() }, unit_test_suites[] }`, run with `unit_test_suite_runner(&suite)`. Assertions such as `TEST_ASSERT_EQUAL`, `TEST_ASSERT_SUCCESS` and `TEST_ASSERT_NOT_NULL` live in `app/test/test.h`. Return codes are TEST_SUCCESS, TEST_FAILED and TEST_SKIPPED.
- Meson suites: `meson test -C build --suite fast-tests | perf-tests | driver-tests | debug-tests`, or a single test by name (`meson test -C build version_autotest`). See `prog_guide/meson_ut.rst`.
- **Not runnable here** (tests=false). The course can provide a 60-line mini-harness that imitates the suite/case/setup/teardown model, so the structure is still hands-on.

### Other in-tree test apps
testpmd (functional plus perf), test-eventdev, test-crypto-perf, test-flow-perf, test-dma-perf, test-bbdev, test-compress-perf, test-acl, test-fib, test-sad, test-regex, test-mldev, test-security-perf, test-cmdline, fips_validation, wycheproof_validation. There are also `devtools/test-null.sh` (testpmd with net_null as a smoke test) and `devtools/test-memif.sh`.

### DTS (`dts/`, `doc/guides/tools/dts.rst`)
- It is a Python framework, managed with Poetry (`poetry install; poetry run ./main.py`), that uses Fabric/SSH to drive nodes. Terminology: DTS runtime environment, **SUT** (system under test, runs DPDK) and **TG** (traffic generator, scapy or TRex). Config files are `dts/configurations/nodes.example.yaml`, `test_run.example.yaml` and `tests_config.example.yaml`.
- Suites live in `dts/tests/TestSuite_*.py`: hello_world, smoke_tests, l2fwd, mac_filter, mtu, vlan, qinq, rss, checksum_offload, flow_offload, port_stats, promisc_support, queue_toggle, rx_tx_offload, virtio_forward, pvp_*_perf, single_core_forward_perf, cryptodev_*, packet_capture, softnic, and others. The framework is in `dts/framework/` (runner.py, test_run.py, testbed_model/, remote_session/), and there is a Dockerfile.
- It replaced the old out-of-tree "DTS" (dts.git). The new framework was merged into the main repo starting with 23.x.
- DTS is not runnable here (it needs SSH nodes and NICs), so teach it with an architecture diagram.

### CI ecosystem
Patchwork (patches.dpdk.org) gets checks from the UNH-IOL Community Lab (real-hardware CI), Intel/Loongson/Marvell labs, GitHub Actions (`.ci/` scripts in the tree), OBS builds, Coverity, and ABI checks (`devtools/check-abi.sh` with libabigail; `devtools/libabigail.abignore`).

---

## 12. Contributing (`doc/guides/contributing/*`)

- The workflow is email-based: patches go to `dev@dpdk.org` via `git send-email` (`--to dev@dpdk.org`, `--cc` the maintainers found by `devtools/get-maintainer.sh`), with `-v2 --in-reply-to <msgid>` for revisions and a changelog below the `---`. Patches are tracked in Patchwork. Trees and sub-trees are listed in `MAINTAINERS` (next-net, next-crypto, next-eventdev, ...), and a technical board handles escalation.
- Commit messages: a `<component>: <summary>` prefix (lower case, ≤60 chars, checked by `devtools/check-git-log.sh`), a body, a mandatory `Signed-off-by:` (DCO), `Fixes: <12-char-sha> ("title")` for bug fixes (`git config alias.fixline`), `Cc: stable@dpdk.org` for backports, and `Acked-by`/`Reviewed-by`/`Tested-by`. `Depends-on: series-NNNNN` marks a dependency.
- Checks: `devtools/checkpatches.sh` (kernel checkpatch.pl + codespell + DPDK rules: forbidden tokens, SPDX via `check-spdx-tag.sh`, symbol changes via `check-symbol-change.py`), `devtools/test-meson-builds.sh` (gcc/clang/static/shared/cross matrix), `devtools/check-doc-vs-code.sh`, `devtools/check-meson.py`, `devtools/cocci.sh`.
- Style (`coding_style.rst`): BSD-ish, tabs, return type on its own line, SPDX header, Doxygen in public headers, and release notes in `doc/guides/rel_notes/release_XX_YY.rst`.
- **AGENTS.md** (new in 2026, by Stephen Hemminger) is guidance for AI review tools. It splits correctness bugs (report at ≥50% confidence: UAF, leaks on error paths, `volatile` used instead of atomics, missing error checks) from style rules. `devtools/ai/review-patch.py` exists. This is a modern touch for the course, and also a gentle nudge: the course's own `volatile int quit` pattern, which mirrors DPDK examples, would be flagged. Mention atomics.
- New library/driver guides: `new_library.rst`, `new_driver.rst`, `design.rst`, `documentation.rst`, `vulnerability.rst` (security@dpdk.org, embargo process), `linux_uapi.rst`.
- Release cadence: four releases a year (YY.03, .07, .11; historically .02/.05/.08/.11). Each has rc1–rc4, with a merge window before rc1. The `.11` release is LTS (`stable.rst`: maintained for **3 years**, at least 3 updates a year, at dpdk-stable git). Ordinary stable releases are N-1 backports.

---

## 13. ABI/API stability policy and symbol versioning

- `ABI_VERSION` = **27.0** for 26.11, giving sonames `librte_eal.so.27`. A major ABI version is declared at most once a year, normally at the .11 LTS (e.g. ABI 21 = 20.11, ABI 22 = 21.11; 26.11 introduces ABI 27). Minor versions bump for compatible quarterly releases (`.so.27.1`, ...). Inside a major ABI, removing a symbol or making an incompatible change is not allowed. Adding symbols is fine.
- Changing the ABI needs 3 acks from the techboard plus the maintainer, a deprecation notice in `doc/guides/rel_notes/deprecation.rst` (116 lines in this tree; e.g. `-c coremask` deprecated in EAL, HPET deprecated), and versioned symbols for backward compatibility. `RTE_NEXT_ABI` can preview changes.
- `__rte_experimental`: not covered by the ABI and can change without notice. Users must define `ALLOW_EXPERIMENTAL_API`, otherwise they get a deprecation warning (or an error with `-Werror`). The doxygen markup carries `@warning EXPERIMENTAL`. The state is not permanent: promotion goes through a deprecation notice.
- `__rte_internal`: for driver-to-lib use only, never for apps (`ALLOW_INTERNAL_API`).
- **New since 25.07:** no hand-written `version.map` files. Symbols are exported by markers next to the definition in .c files: `RTE_EXPORT_SYMBOL(rte_eth_iterator_init)` (`lib/ethdev/rte_ethdev.c:171`), `RTE_EXPORT_EXPERIMENTAL_SYMBOL(sym, ver)`, `RTE_EXPORT_INTERNAL_SYMBOL(sym)`. They are defined as empty macros in `lib/eal/common/eal_export.h`. `buildtools/gen-version-map.py` greps them to generate `<lib>_version.map` at build time (DPDK_27 / EXPERIMENTAL / INTERNAL nodes).
- Function versioning, as in the ABI-versioning guide's `rte_acl_create` example: `RTE_VERSION_SYMBOL(21, int, rte_acl_create, (params))` keeps the old implementation as `rte_acl_create_v21` bound to `rte_acl_create@DPDK_21`. `RTE_DEFAULT_SYMBOL(22, ...)` creates `@@DPDK_22`, the default for newly linked apps. `RTE_VERSION_EXPERIMENTAL_SYMBOL` gives an alias for promoted symbols. The implementation uses `__attribute__((symver("name@DPDK_ver")))`, or a `.symver` asm fallback, only under `RTE_BUILD_SHARED_LIB`. A static build ignores versions. The library's meson.build needs `use_function_versioning = true`, otherwise there is a VERSIONING_WARN pragma.
- The policy does not apply to the Windows build, because Windows does not support function versioning.
- Tools: `devtools/check-abi.sh` (abidiff vs a reference build), `devtools/check-symbol-change.py`, `buildtools/check-symbols.sh`.
- Visualization: an **ABI timeline**. A horizontal axis of releases (24.11 LTS = ABI 25, 25.03, 25.07, 25.11 LTS = ABI 26, 26.03, 26.07, 26.11 LTS = ABI 27) shows soname bands, an experimental "sandbox" lane where APIs enter and graduate, and a symbol-version table animation: an old binary resolves `rte_acl_create@DPDK_21` and a new binary resolves `@@DPDK_22`, both against the same .so.

---

## 14. Cross-compiling and other OSes

- **Cross:** `meson setup arm-build --cross-file config/arm/arm64_armv8_linux_gcc`. The file has `[binaries]` (c, cpp, ar, strip, pkg-config, using aarch64-linux-gnu-*), `[host_machine]` (system linux, cpu_family aarch64, cpu armv8-a, endian little) and `[properties] platform='generic'`. Per-SoC files include `arm64_graviton2/3/4_linux_gcc`, `arm64_bluefield3`, `arm64_cn10k`, `arm64_cn20k`, `arm64_ampereone`, `arm64_grace`, `arm64_kunpeng920`, and others; `config/arm/meson.build` maps implementer/part numbers to flags. For Arm, `cpu_instruction_set` is ignored; use `-Dplatform=<SoC>`. Also covered: `cross_build_dpdk_for_riscv.rst`, `cross_build_dpdk_for_loongarch.rst`, ppc, `config/x86/cross-mingw` (Windows from Linux), and clang cross files (`arm64_armv8_linux_clang_ubuntu`). Dependencies such as libnuma must be cross-built and found through `PKG_CONFIG_LIBDIR`/sysroot.
- Not runnable here (no cross toolchain). Show `meson setup --cross-file` failing gracefully and the cross file anatomy. Optionally run `meson env2mfile`.
- **Windows** (`windows_gsg/`): toolchains are Clang + MSVC linker, MinGW-w64 (native or cross), or MSVC (needs `-Denable_stdatomic=true`); 64-bit only; meson ≥ 1.5.2. Runtime needs `SeLockMemoryPrivilege` for large pages and the kernel drivers **virt2phys** (IOVA translation) and **netuio** (in the dpdk-kmods repo, unsigned, so test-signing mode is required). Only some libraries and PMDs are supported, there is no ABI policy, and there is no multi-process support. Microsoft co-maintains it.
- **FreeBSD** (`freebsd_gsg/`): `pkg install meson pkgconf py311-pyelftools` or the `net/dpdk` port. Kernel modules are **contigmem** (physically contiguous buffers reserved at boot: `hw.contigmem.num_buffers`, `hw.contigmem.buffer_size` in `/boot/loader.conf`) and **nic_uio** (binds NICs), built from `kernel/freebsd`. There is no hugetlbfs; contigmem plays that role. EAL parameters are in `freebsd_eal_parameters.rst`.
- Visualization: a **porting matrix**. EAL is the per-OS layer (`lib/eal/{linux,freebsd,windows}` + `common`), with OS shims drawn for memory (hugetlbfs / contigmem / VirtualAlloc2 large pages), device access (VFIO/UIO / nic_uio / netuio), interrupts (epoll / kqueue / IOCP) and threads (pthread / rte_thread).

---

## 15. Real deployments and ecosystem (for a "DPDK in the wild" chapter)

- **Virtual switching:** Open vSwitch with DPDK (OVS-DPDK, `dpdkvhostuser` ports with vhost-user to VMs). Intel's 2017 case study reports Yahoo! JAPAN running OvS-DPDK in production with about 2x HTTP performance vs Linux bridge. OpenStack/OPNFV NFV installers support OVS-DPDK and VPP datapaths. Juniper Contrail/Tungsten Fabric vRouter (DPDK mode) is another user.
- **Routers/forwarders:** FD.io **VPP** (vector packet processing; DPDK as an input plugin; Cisco origin), DANOS/Vyatta, 6WIND VSR (6WIND was an early DPDK steward and launched dpdk.org in 2013), and Graphene/`lib/graph` (VPP-like nodes inside DPDK).
- **Security/monitoring:** **Suricata** IDS/IPS DPDK capture mode (since 7.0; it grew from Lukas Sismis's master's thesis), Snort 3 DAQ, Zeek, and ntop's tools.
- **Traffic generators:** Cisco **TRex**, **Pktgen-DPDK**, **MoonGen** (Lua scripting, IMC 2015 paper), testpmd txonly.
- **Storage:** **SPDK** reuses DPDK's EAL, memory, PCI and VFIO for user-space NVMe.
- **User-space TCP/IP stacks:** **F-Stack** (Tencent; FreeBSD stack on DPDK), mTCP (NSDI'14), Seastar/ScyllaDB (native DPDK stack option), TLDK, Demikernel (SOSP'21), **eRPC** (NSDI'19), Shenango/Caladan, TAS.
- **Cloud/telco:** cloud PMDs exist for AWS ENA (`net/ena`), Azure (`net/netvsc`, `net/mana`), Google (`net/gve`), virtio, vmxnet3, and others. There are 5G UPFs (e.g. OMEC/BESS-based UPF, many vendor UPFs), vRAN (FlexRAN uses bbdev), and load balancers (e.g. iQiYi DPVS). These show why ABI stability and LTS matter: distros (RHEL, Ubuntu, Debian) ship LTS DPDK as shared libs.
- **Governance:** the Linux Foundation project since 2017 (moved from 6WIND stewardship), a governing board plus a technical board, and the dpdk.org user stories page.
- Sources: https://dpdk.org/category/user-stories , https://www.dpdk.org/ecosystem/ , https://www.intel.com/content/www/us/en/developer/articles/case-study/yahoo-japan-accelerates-l7-performance-using-open-vswitch-with-dpdk.html , https://www.dpdk.org/?p=3597 (Suricata) , DPDK Summit 2016 "DPDK in production" (https://dpdk.org/wp-content/uploads/sites/23/2016/08/Day02-Session14-FranckBaudin-DPDKUSASummit2016.pdf). Symbol export rework: https://mails.dpdk.org/archives/dev/2025-April/316781.html (v7 0/8 "Symbol versioning and export rework", applied for 25.07).
- Caveat: the case-study figures above are vendor-published and dated, and F-Stack production claims were not verified.

---

## 16. CAPSTONE: minimal user-space UDP/IP responder (verified working)

File: `10-examples/responder.c` (about 150 lines). Build it statically:
`gcc -O2 -Wall responder.c -o responder $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)`

### Design
- Single lcore, single port, one RX and one TX queue, mempool of 4095 mbufs (cache 256), 512 descriptors per queue. The IP address comes from the app args after `--`, and the MAC comes from `rte_eth_macaddr_get`.
- Per burst of 32, dispatch on `eth->ether_type` (be16):
  - **ARP** (`RTE_ETHER_TYPE_ARP`, `struct rte_arp_hdr`, `rte_arp.h`): if the opcode is `RTE_ARP_OP_REQUEST` and `arp_tip == my_ip`, rewrite the packet in place as a reply: opcode REPLY, tha=sha, tip=sip, sha=my_mac, sip=my_ip, eth dst=src, src=my_mac.
  - **IPv4** (`struct rte_ipv4_hdr`, `rte_ipv4_hdr_len()`): drop if dst≠my_ip or if the packet is a fragment (`fragment_offset & (RTE_IPV4_HDR_MF_FLAG|RTE_IPV4_HDR_OFFSET_MASK)`).
    - **ICMP** echo request (`RTE_ICMP_TYPE_ECHO_REQUEST`) becomes a reply: set the type, set the checksum to 0, then `~rte_raw_cksum(icmp, total_len - ihl)`.
    - **UDP**: swap the ports. The payload echoes back.
    - In both cases: swap the IPs, set TTL to 64, set `hdr_checksum=0` and `rte_ipv4_cksum(ip)`. For UDP, set `dgram_cksum=0` and `rte_ipv4_udptcp_cksum(ip, udp)`. Swap the MACs.
  - Anything else gets `rte_pktmbuf_free` and a counter. Replies go out with one `rte_eth_tx_burst`, and any that were not sent are freed.
- SIGINT handling sets a flag, then the app prints counters, `rte_eth_dev_stop/close`, `rte_eal_cleanup`.
- Zero-copy and in-place: the request mbuf *becomes* the reply. This is a core DPDK idiom worth animating.

### Run recipe A: net_tap (verified)
```
timeout -s INT -k 5 25 stdbuf -oL ./responder --no-pci --no-huge -m 128 --file-prefix=ch10resp -l 1 \
     --vdev=net_tap0,iface=ch10tap -- 10.10.0.2 &
sleep 3; ip addr add 10.10.0.1/24 dev ch10tap; ip link set ch10tap up
python3 udp_client.py      # sendto(b"hello dpdk", ("10.10.0.2", 9000)) → echoed back
python3 icmp_ping.py       # raw ICMP socket; replies type=0, csum ok, RTT 29–143 µs
```
Result: `arp=1 icmp=3 udp=0 ignored=0` (and in another run `arp=1 udp=1`). The tap interface disappears when the app exits.
**Subtlety:** with net_tap, the DPDK port MAC equals the kernel interface MAC (`CE:26:2F:...` on both sides; the kernel's neighbour entry for 10.10.0.2 points at its own MAC). That works because the tap fd is the "wire", but it is conceptually confusing.

### Run recipe B: veth + af_packet in a netns (verified; more realistic L2)
```
ip netns add ch10ns; ip link add ch10a type veth peer name ch10b; ip link set ch10b netns ch10ns
ip link set ch10a up; ip -n ch10ns addr add 10.10.1.1/24 dev ch10b; ip -n ch10ns link set ch10b up
./responder --no-pci --no-huge -m 128 --file-prefix=ch10resp2 -l 1 --vdev=net_af_packet0,iface=ch10a -- 10.10.1.2 &
ip netns exec ch10ns python3 -c '...sendto(b"ping 0",("10.10.1.2",7))...'   # 3/3 echoed
ip -n ch10ns neigh   # 10.10.1.2 lladdr 02:fb:87:de:45:b8 REACHABLE (the DPDK port = veth's MAC)
ip link del ch10a; ip netns del ch10ns
```
Result: `arp=1 icmp=0 udp=3`. Using a netns guarantees the kernel does not answer locally.

### ICMP test without ping
A Python raw socket, as root (code was used in the experiment):
```python
s=socket.socket(socket.AF_INET,socket.SOCK_RAW,socket.IPPROTO_ICMP)
hdr=struct.pack('!BBHHH',8,0,0,0x1234,seq); c=csum(hdr+payload)
s.sendto(struct.pack('!BBHHH',8,0,c,0x1234,seq)+payload,('10.10.0.2',0)); data,_=s.recvfrom(2000)
```

### Suggested capstone extensions (graded steps)
1. Add the telemetry endpoint `/responder/stats` (arp/icmp/udp/drop counters, using atomics) and watch it with `dpdk-telemetry-watcher.py -f ch10resp /responder/stats.udp`.
2. Add a cmdline thread: `show stats`, `set ip <IPv4>ip`, `quit` (MAC types need manual tokens).
3. Add a custom tracepoint per reply type and inspect the CTF channel file sizes.
4. Add a small ARP cache (`rte_hash`) and send gratuitous ARP at start (`RTE_ARP_OP_REQUEST` with sip=tip).
5. Use TX checksum offload when the port supports it (`RTE_ETH_TX_OFFLOAD_IPV4_CKSUM|UDP_CKSUM`, `m->ol_flags |= RTE_MBUF_F_TX_IPV4|RTE_MBUF_F_TX_IP_CKSUM|RTE_MBUF_F_TX_UDP_CKSUM`, l2_len/l3_len, `rte_ipv4_phdr_cksum`). net_tap supports some offloads; check `dev_info.tx_offload_capa`.
6. Multi-queue with RSS on af_packet `qpairs=2`, one lcore per queue.
7. Handle VLAN (`RTE_ETHER_TYPE_VLAN`) and IPv6 ND/ICMPv6 as stretch goals.
8. Benchmark with a second DPDK process via memif: a client generator using `net_memif` (role=client) against the responder (`role=server`).

### Visualizations for the capstone
- A **packet surgery** animation: the incoming ARP request header fields animate their swaps (sha↔tha, sip↔tip, opcode 1→2). The same for ICMP (type 8→0, checksum recompute shown as 16-bit one's-complement sum folding) and UDP (port swap, pseudo-header checksum).
- A **topology diagram**: kernel netns (10.10.1.1) ↔ veth ↔ af_packet PMD ↔ responder lcore loop, with arrows for the ARP who-has, is-at, then the UDP datagram and its echo.
- A **checksum calculator** widget: input bytes and step through the one's-complement addition.

---

## 17. Common pitfalls (consolidated)

1. Forgetting `argc -= ret; argv += ret;` after `rte_eal_init` and parsing EAL args as app args. App args go after `--`.
2. Static link without `--whole-archive`, which gives zero PMDs and "No Ethernet ports". Meson `declare_dependency(link_args: ...)` reorders flags and causes this silently. `dependency('libdpdk', static:true)` pulls every system lib statically and fails. Check with `dpdk-pmdinfo.py`.
3. Shared builds: `LD_LIBRARY_PATH`/rpath, the PMD dir permission check (world-writable parents such as /tmp abort), and the need for `-d` when drivers are outside the default path.
4. `RTE_LOG_REGISTER_DEFAULT` in external apps registers the literal name "RTE_LOG_DEFAULT_LOGTYPE".
5. Using experimental APIs without `-DALLOW_EXPERIMENTAL_API`: deprecation warnings, which become build errors under `-Werror`.
6. Tracepoints: register in exactly one TU, include `rte_trace_point_register.h` first, include `rte_eal_trace.h` for generic points, and remember that FP points are compiled out by default.
7. Telemetry: command names have strict characters and a 56-byte max, output is capped at 16 KB, and callbacks run on another thread.
8. Concurrent DPDK processes without a unique `--file-prefix` collide on `/var/run/dpdk/rte`. `--in-memory` disables secondaries (proc-info/pdump cannot attach). `--no-huge` primaries cannot have secondaries.
9. stdout buffering plus SIGINT/timeout kills lose output: use `stdbuf -oL` or `fflush`.
10. testpmd option drift (no `--no-interactive`). Always check `--help` for the installed version.
11. cmdline-gen has no MAC type, and interactive echo shows `^M` when piped.
12. `-march=native` binaries are not portable. Use `cpu_instruction_set=generic` or an explicit platform for distribution.
13. Expecting ABI stability from `__rte_experimental` or `__rte_internal` symbols. A static build has no symbol versioning at all.
14. The capstone needs checksums recomputed after edits, fragments dropped, the ARP target IP checked, unsent TX mbufs freed, and a netns if you do not want the kernel to answer.
15. Using `volatile` flags across threads: DPDK review guidance (AGENTS.md) prefers `rte_atomic`/C11 atomics.

---

## 18. Suggested chapter split for this area (for the planner)

- **Ch A: "Building DPDK and your first app".** Meson/ninja, options, pkg-config, static vs shared, the skeleton, logging. Labs: build devapp static and shared, pmdinfo, a meson project, the whole-archive bug demo.
- **Ch B: "Instrumenting and controlling a DPDK app".** cmdline, telemetry (custom endpoint and a raw client), proc-info (secondary), rte_trace (CTF). Labs: devapp + cliapp + telclient + testpmd/proc-info.
- **Ch C: "Debugging, testing and the community".** gdb, ASan, dumps, pdump/dumpcap, the troubleshooting tree, the dpdk-test model, meson suites, DTS, contribution workflow, ABI policy and symbol versioning, LTS, cross/Windows/FreeBSD, the ecosystem.
- **Ch D (capstone): "A UDP/IP responder from scratch".** ARP, ICMP and UDP with in-place reply, tap and veth/af_packet recipes, extensions with telemetry/cmdline/trace.

## 19. Key source references
- Docs: `doc/guides/prog_guide/{build-sdk-meson,build_app,cmdline,log_lib,telemetry_lib,trace_lib,meson_ut,asan,profile_app,lto,source_org}.rst`, `doc/guides/howto/{telemetry,debug_troubleshoot}.rst`, `doc/guides/tools/{proc_info,dts,dumpcap,pdump,pmdinfo,telemetrywatcher}.rst`, `doc/guides/contributing/{abi_policy,abi_versioning,patches,unit_test,stable,coding_style,new_library,new_driver,vulnerability}.rst`, `doc/guides/linux_gsg/{build_dpdk,cross_build_dpdk_for_arm64,linux_eal_parameters}.rst`, `doc/guides/windows_gsg/*`, `doc/guides/freebsd_gsg/*`, `doc/guides/rel_notes/deprecation.rst`.
- Code: `meson_options.txt`, `lib/meson.build`, `drivers/meson.build`, `buildtools/{pmdinfogen.py,gen-version-map.py,dpdk-cmdline-gen.py,get-test-suites.py}`, `lib/eal/common/eal_common_options.c` (plugins, `verify_perms`, `is_shared_build`), `lib/eal/common/eal_export.h`, `lib/eal/include/{rte_compat.h,rte_trace.h,rte_trace_point.h,rte_trace_point_register.h,rte_eal_trace.h,rte_lcore.h}`, `lib/log/rte_log.h`, `lib/telemetry/{telemetry.c,rte_telemetry.h}`, `lib/cmdline/*.h`, `app/proc-info/main.c`, `app/test/test.h`, `examples/{skeleton,helloworld,cmdline}`, `drivers/net/null/rte_eth_null.c`, `dts/`, `devtools/`, `usertools/`, `AGENTS.md`, `config/arm/arm64_armv8_linux_gcc`, `ABI_VERSION`.
- Verified example code: `/home/user/ai_lab/dpdk_research/research/10-examples/` (devapp.c with logging, telemetry and trace; app_trace.{h,c}; cliapp.c + cmds.list; responder.c; telclient.py; mesonapp/meson.build).
