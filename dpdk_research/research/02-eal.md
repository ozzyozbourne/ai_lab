# Research note 02: Environment Abstraction Layer (EAL)

Scope: `rte_eal_init`, EAL arguments, lcores (main/worker/service/non-EAL), launch API, service cores,
lcore variables, threads and affinity, logging, timers and TSC, alarms, multi-process (primary/secondary, IPC),
IOVA modes, VFIO/UIO, buses, devices, devargs, hotplug, and cleanup.

Version: DPDK **26.11.0** (`$DPDK_SRC/VERSION`). Every claim below was checked against the source tree, and
everything marked **[verified]** was run on this machine (4 vCPU KVM Xeon, AVX-512, no IOMMU, no `/dev/vfio`,
root, Linux 6.18, 1024 x 2 MB hugepages that other jobs also use).

Memory internals (memsegs, memzones, malloc heap, hugepage mapping modes) belong to the EAL but are probably
covered in more depth by the memory chapter. Here they appear only where they explain init order, multi-process
or IOVA. The section "Boundary with other chapters" says what to hand off.

---

## 0. Things that changed recently (a 2021-era tutorial gets these wrong)

| Change | Release | Teaching consequence |
|---|---|---|
| `rte_lcore_state_t` now has only `WAIT` and `RUNNING` (`FINISHED` is gone) | 21.x+ | Old code that checks `FINISHED` will not compile. `lib/eal/include/rte_launch.h:21` |
| EAL options are parsed with the **argparse** library (`rte_argparse`); the option table is `lib/eal/common/eal_option_list.h` | 25.07+ | `-h` output comes from argparse. Parsing still stops at `--`. |
| `-l` accepts the full `--lcores` syntax (`1@(1,2)`, groups) | 25.07 | Teach only `-l`. `-c` (coremask) and `-s` (service coremask) are marked **[Deprecated]**. |
| `-R/--remap-lcore-ids[=base]` gives contiguous lcore ids on arbitrary CPUs | 25.11 | `-l 2-3 -R` gives lcore ids 0,1 on CPUs 2,3 **[verified]** |
| `--numa-mem` / `--numa-limit` replace `--socket-mem` / `--socket-limit` (old names are kept as aliases) | 26.x | Use the new names in the course. |
| `--pagesz-mem <pagesz>:<limit>` | 26.07 | Runtime per-page-size VA limit |
| `-A/--no-auto-probing`, `--auto-probing` | 26.07 | The app probes devices itself (`rte_dev_probe`) |
| VFIO cdev (iommufd) mode is supported next to group mode; `rte_vfio_*` API made **internal** | 26.11 | Apps can no longer call `rte_vfio_*`; mention it only as background. |
| New prog_guide pages `devargs.rst` and `device_hotplug.rst` | 26.x | Very good source material |
| Lcore variables (`rte_lcore_var.h`) | 24.11 (still experimental) | Needs `-DALLOW_EXPERIMENTAL_API` **[verified]**, otherwise you get a deprecation warning |
| Logging moved out of EAL into `lib/log` | 23.11 | Header is `rte_log.h` in `lib/log/`. `RTE_LOG_LINE` forbids a trailing `\n` (static_assert). |
| `--log-timestamp[=ctime\|delta\|reltime\|iso]`, `--log-color[=auto\|always\|never]` | 24.x | **[verified]** |

---

## 1. Recommended teaching order (easy to hard)

Suggested chapter or section split (could be 2 or 3 course chapters: "EAL basics and lcores",
"EAL services: logs, time, services, lcore vars", "Multi-process, devices, IOVA and hotplug"):

1. **What the EAL is and why it exists.** It abstracts the OS and hardware: memory, cores, devices, time, IPC.
   Diagram: the app sits on DPDK libraries, which sit on the EAL, which sits on the OS and HW.
2. **Hello world.** `rte_eal_init()` → `rte_eal_mp_remote_launch()` → `rte_eal_mp_wait_lcore()` → `rte_eal_cleanup()`.
   Cover the return value (number of consumed args) and the `--` separator for app args.
3. **The EAL command line.** Option groups (lcore, device, memory, multi-process, logging, debug).
   The minimal sandbox set is `--no-huge -m 64 --no-pci --file-prefix=X`.
4. **Lcores in depth.** The lcore id vs CPU id distinction, `-l` syntax with `@` and groups, `--main-lcore`, `-R`.
   Roles: RTE / SERVICE / NON_EAL / OFF. The query API.
5. **Launching work.** `rte_eal_remote_launch` and its internals (pipes plus atomics, the WAIT→RUNNING→WAIT
   state machine, return codes). `CALL_MAIN` vs `SKIP_MAIN`.
6. **Threads.** EAL threads vs control threads (`dpdk-intr`, `dpdk-mp-msg`, `dpdk-telemet-v2`) vs non-EAL
   threads. `rte_thread_register()`, `rte_thread_create_control()`, affinity rules, starvation pitfalls.
7. **Per-lcore data.** `RTE_DEFINE_PER_LCORE` (TLS) vs static arrays indexed by `rte_lcore_id()` with
   `RTE_CACHE_GUARD` vs **lcore variables**. Memory-layout pictures.
8. **Logging.** Levels, logtypes, `RTE_LOG_REGISTER*`, `--log-level` patterns, `RTE_LOG_LINE`,
   `rte_openlog_stream`, syslog, timestamps and colors.
9. **Time.** TSC (`rte_rdtsc`, `rte_get_tsc_hz`, `rte_get_timer_cycles`), delays, HPET, the busy-poll
   measurement pattern. EAL alarms (`rte_eal_alarm_set`, which run in the interrupt thread). A pointer to
   the `rte_timer` library (skiplist, per-lcore `rte_timer_manage`).
10. **Service cores.** Components register services, the app maps them to service lcores (`-S`),
    run-states (component plus app), stats, `rte_service_run_iter_on_app_lcore`, MT-safe capability.
11. **Init sequence deep dive.** The full `rte_eal_init` timeline (see section 3), as an animated timeline.
12. **Buses, drivers, devices, devargs.** Constructors (`RTE_INIT`, `RTE_REGISTER_BUS`,
    `RTE_PMD_REGISTER_VDEV`) → scan → probe (vdev probed last). Devargs syntaxes. Allow/block lists.
    `-A`. `RTE_DEV_FOREACH`.
13. **Hotplug.** `rte_dev_probe` / `rte_dev_remove`, `rte_eal_hotplug_add/remove`, ethdev NEW/DESTROY events,
    kernel uevent monitoring, deferring work with alarms.
14. **Multi-process.** Shared config file, `fcntl` lock-based auto-detect, identical VA mapping, the runtime
    directory, `--file-prefix`, IPC (`rte_mp_*`), deployment models, limitations, hotplug sync.
15. **IOVA, VFIO, UIO.** PA vs VA vs DC, bus voting plus the heuristic, `--iova-mode`, VFIO group vs cdev,
    no-IOMMU, UIO's risks, `dpdk-devbind.py`. This machine can demonstrate only the *decision logic*:
    no IOMMU or VFIO, so `--no-huge` gives VA and hugepages as root give PA.
16. **Cleanup and lifecycle.** `rte_eal_cleanup` order, leftover runtime files and hugepage files, idempotence,
    signal safety.
17. **Expert extras.** Telemetry `/eal/*` endpoints, `rte_lcore_register_usage_cb`, trace (`--trace`),
    `--huge-worker-stack`, `--force-max-simd-bitwidth`, `rte_eal_get_runtime_dir`, `-d` plugins.

---

## 2. Concepts, APIs, internals

### 2.1 Entry points (`lib/eal/include/rte_eal.h`, Linux implementation `lib/eal/linux/eal.c`)

- `int rte_eal_init(int argc, char **argv)` returns the number of parsed args (≥0), or -1 with `rte_errno` set
  (EALREADY, EINVAL, ENOTSUP, ENODEV, EACCES, ENOMEM, EFAULT, EAGAIN). It may be called only once.
  A guard (`run_once` CAS) returns EALREADY on a second call. **On failure the guard is reset**
  (`err_out:` stores 0), so a retry is technically possible, but resources may leak. Tell students not to retry.
  Caveat **[verified]**: when the secondary cannot open the config, `rte_strerror(rte_errno)` printed "Success",
  because `rte_errno` is not always set on every path.
- `int rte_eal_cleanup(void)` is also guarded by `run_once` (a second call gives EALREADY plus a warning).
- `rte_eal_process_type()` returns `RTE_PROC_PRIMARY` or `RTE_PROC_SECONDARY` (or AUTO/INVALID in the enum).
- `rte_eal_primary_proc_alive(config_path)`, `rte_eal_has_hugepages()`, `rte_eal_has_pci()`, `rte_eal_iova_mode()`,
  `rte_eal_get_runtime_dir()`, `rte_eal_mbuf_user_pool_ops()`, `rte_eal_vfio_intr_mode()`, `rte_eal_create_uio_dev()`,
  `rte_eal_driver_path_next/count()` (new).
- App args: `argc -= ret; argv += ret;` (pattern in every example). The user separates app args with `--`.

### 2.2 EAL options (authoritative table: `lib/eal/common/eal_option_list.h`; docs: `doc/guides/linux_gsg/eal_args.include.rst`, `linux_eal_parameters.rst`)

Macros `LIST_ARG/STR_ARG/OPT_STR_ARG/BOOL_ARG/STR_ALIAS` generate the argparse table in
`eal_common_options.c` (`struct rte_argparse eal_argparse`, line ~177).

- Lcore options: `-l/--lcores`, `--main-lcore`, `-S/--service-corelist`, `-R/--remap-lcore-ids`, and the
  deprecated `-c`, `-s`. Only one of `-l` or `-c` may be given.
- Device options: `-a/--allow`, `-b/--block` (mutually exclusive), `--vdev`, `-d/--driver-path`, `--no-pci`,
  `-A/--no-auto-probing`, `--auto-probing`.
- Multi-process options: `--proc-type primary|secondary|auto`, `--file-prefix`, `--base-virtaddr`.
- Memory options: `-m`, `--numa-mem`, `--numa-limit`, `--pagesz-mem`, `--in-memory`, `--no-huge`, `--legacy-mem`,
  `--single-file-segments`, `--huge-dir`, `--huge-unlink[=existing|always|never]`, `--match-allocations`,
  `--huge-worker-stack[=KB]`, `--iova-mode pa|va`, `-n`, `-r`.
- Logging and trace options: `--log-level`, `--log-timestamp`, `--log-color`, `--syslog[=facility]`, `--trace*`.
- Other options: `-v`, `-h`, `--no-telemetry`, `--telemetry`, `--no-hpet`, `--vmware-tsc-map`,
  `--force-max-simd-bitwidth`, `--mbuf-pool-ops-name`, `--vfio-intr`, `--vfio-vf-token`, `--create-uio-dev`,
  `--no-shconf`.
- `--no-huge` defaults to `MEMSIZE_IF_NO_HUGE_PAGE` (64 MB) if `-m` is not given. It uses memfd anonymous
  memory ("Using memfd for anonymous memory" **[verified]**). It implies no secondary-process support.
- `--in-memory` implies `--no-shconf` and creates no runtime-directory files **[verified]**.

`-l` syntax examples (from the docs, verify with `--log-level=lib.eal:debug`):

- `-l 0-3`
- `--lcores='0,(1-3)@(1,2)'` gave lcores 1, 2 and 3 all with cpuset [1-2] **[verified]**
- `--lcores='1,2@(5-7),(3-5)@(0,2),(0,6),7-8'` (the doc example: 9 threads)

Errors seen **[verified]**:

- `-l 0-5` on 4 CPUs fails with "lcore 4 unavailable … invalid coremask or core-list parameter, please check
  specified cores are part of 0-3".
- `--main-lcore 0` with `-l 1-2` fails with a generic "Error parsing command line arguments."
- `--vdev net_bogus0` fails with "failed to parse device", and `rte_errno`=ENODEV.
- `--iova-mode=pa --no-huge` fails with "Cannot use IOVA as 'PA' since physical addresses are not available".

### 2.3 Lcores (`lib/eal/include/rte_lcore.h`, `lib/eal/common/eal_common_lcore.c`, `eal_common_options.c`)

- An **lcore** is an EAL thread identity, an index in `[0, RTE_MAX_LCORE)`. `RTE_MAX_LCORE=128` in this build
  (`build/rte_build_config.h:218`). It is *not* necessarily a CPU id. Each lcore has a `cpuset`.
  `lcore_config[]` (`eal_private.h`) holds the thread id, pipes, function pointer, arg, return value, state,
  cpuset and socket id.
- Roles (`enum rte_lcore_role_t`): `RTE_LCORE_ROLE_RTE`, `_OFF`, `_SERVICE`, `_NON_EAL` (old aliases `ROLE_*`).
- Query API: `rte_lcore_id()` (TLS `per_lcore__lcore_id`, which is `LCORE_ID_ANY` = UINT32_MAX in
  unregistered threads; printed as -1 **[verified]**), `rte_get_main_lcore()`, `rte_lcore_count()`,
  `rte_lcore_index()`, `rte_socket_id()`, `rte_lcore_to_socket_id()`, `rte_lcore_to_cpu_id()`,
  `rte_lcore_cpuset()`, `rte_lcore_is_enabled()`, `rte_get_next_lcore(i, skip_main, wrap)`, `rte_socket_count()`,
  `rte_socket_id_by_idx()`, `rte_eal_lcore_role()`, `rte_lcore_has_role()`, `rte_lcore_dump(FILE*)`,
  `rte_lcore_iterate(cb)`.
- Iteration macros: `RTE_LCORE_FOREACH(i)` and `RTE_LCORE_FOREACH_WORKER(i)`. They visit only ROLE_RTE lcores,
  so service lcores are skipped. **Pitfall [verified]:** `rte_lcore_count()` returned 3 with `-l 0-2 -S 2`
  (the service lcore is still counted), while FOREACH_WORKER visited only lcore 1.
- Lifecycle callbacks: `rte_lcore_callback_register(name, init_cb, uninit_cb, arg)` is called for existing
  and future lcores, including registered non-EAL threads.
- Usage accounting: `rte_lcore_register_usage_cb(cb)` fills `struct rte_lcore_usage {total_cycles, busy_cycles}`
  and is shown by `rte_lcore_dump` and the telemetry `/eal/lcore/usage` endpoint.
- Non-EAL threads: `rte_thread_register()` / `rte_thread_unregister()` give an lcore id from the free pool
  (it got id 3 with `-l 0-2`, role NON_EAL=3 **[verified]**). This is **incompatible with multi-process**
  (header note in rte_lcore.h ~line 410).

### 2.4 Launch API (`lib/eal/include/rte_launch.h`, `lib/eal/common/eal_common_launch.c`, `lib/eal/common/eal_common_thread.c`, `lib/eal/unix/eal_unix_thread.c`)

- `rte_eal_remote_launch(f, arg, worker_id)` returns -EBUSY if the worker is not in WAIT.
- `rte_eal_mp_remote_launch(f, arg, CALL_MAIN|SKIP_MAIN)` runs f on all workers (and on main if CALL_MAIN,
  synchronously in the caller).
- `rte_eal_wait_lcore(id)` spins (`rte_pause`) until the worker is back in WAIT and returns `f`'s return
  value. `rte_eal_mp_wait_lcore()` does that for every worker. `rte_eal_get_lcore_state(id)` reads the state.
- **Internals (great animation material):**
  1. During init, for each worker: `pipe(pipe_main2worker)` and `pipe(pipe_worker2main)`, then
     `eal_worker_thread_create(i)`, then name it `dpdk-worker%d`, then set affinity. The main lcore then
     launches a dummy `sync_func` on all workers and waits, so all threads are known to be ready.
  2. The worker thread (`eal_thread_loop`) calls `__rte_thread_init(lcore_id, cpuset)` (sets TLS lcore id,
     socket and cpuset). It then loops forever: it blocks in `read()` on the m2w pipe
     (`eal_thread_wait_command`), stores `state=RUNNING` (release), writes an ack byte on w2m, spins until
     `lcore_config.f != NULL` (acquire), calls `ret = f(arg)`, clears f/arg, and stores `state=WAIT`
     (release).
  3. Main (`rte_eal_remote_launch`) checks state==WAIT (acquire), sets arg, stores f (release), then calls
     `eal_thread_wake_worker`, which writes 1 byte to m2w and blocks reading the ack from w2m.
  - Idle workers therefore sleep in the kernel (read on a pipe), so they do not burn CPU until launched.
    Once the function runs, the app's own loop is usually a busy poll.
- Rule: launch functions only from the main lcore. A worker cannot be relaunched while it is RUNNING.

### 2.5 Threads (`lib/eal/include/rte_thread.h`, `lib/eal/unix/rte_thread.c`, `lib/eal/common/eal_common_thread.c`)

- The portable thread API (originally driven by Windows support): `rte_thread_t`, `rte_thread_create`,
  `rte_thread_join`, `rte_thread_detach`, `rte_thread_self`, `rte_thread_set_name` (≤16 chars incl. NUL,
  `RTE_THREAD_NAME_SIZE`), `rte_thread_set_prefixed_name`, `rte_thread_attr_*` (priority, affinity),
  `rte_thread_set/get_affinity_by_id`, `rte_thread_set_affinity(cpuset)` (the current thread; also updates TLS
  `_cpuset` and `_socket_id`), `rte_thread_set/get_priority`, TLS keys `rte_thread_key_create`,
  `rte_thread_value_set/get`.
- **Control threads:** `rte_thread_create_control(&t, name, func, arg)`. Their affinity is the *original
  process affinity minus dataplane and service lcores*, falling back to the main lcore's CPU if nothing is
  left. With `--log-level=lib.eal:debug` you see "Control threads will use cores: 3" **[verified]**.
  Internal ones get the `dpdk-` prefix (`rte_thread_create_internal_control`).
- **Observed threads [verified]** for `dpdk-timer -l 1-2`:

  ```
  dpdk-timer      (main lcore 1) cpus 1
  dpdk-intr       (interrupt + alarm thread) cpus 0,3
  dpdk-mp-msg     (IPC thread)  cpus 0,3
  dpdk-worker2    cpus 2
  dpdk-telemet-v2 (telemetry socket) cpus 0,3
  ```

  This makes a great "process anatomy" diagram (`/proc/<pid>/task/*/comm` plus `Cpus_allowed_list`).
- Pitfalls: if every CPU is used as an lcore, control threads share the main lcore and starve. That causes
  delayed alarms, missed hotplug events, telemetry timeouts and secondary-process startup failures.
  SCHED_FIFO on a CPU shared with a control thread loses kernel events (docs warning).
- Per-thread TLS: `RTE_DEFINE_PER_LCORE(type, name)` and `RTE_PER_LCORE(name)` (`rte_per_lcore.h`) are
  plain `__thread`/`_Thread_local`.

### 2.6 Lcore variables (`lib/eal/include/rte_lcore_var.h`, `lib/eal/common/eal_common_lcore_var.c`, doc `prog_guide/lcore_var.rst` with figures `img/lcore_var_mem_layout.*` and `img/static_array_mem_layout.*`)

- Macros: `RTE_LCORE_VAR_HANDLE(type, name)`, `RTE_LCORE_VAR_ALLOC(h)`, `RTE_LCORE_VAR_ALLOC_SIZE[_ALIGN]`,
  `RTE_LCORE_VAR_INIT(h)` (constructor), `RTE_LCORE_VAR(h)` (the current lcore's value),
  `RTE_LCORE_VAR_LCORE(lcore_id, h)`, `RTE_LCORE_VAR_FOREACH(lcore_id, ptr, h)`.
- Implementation: buffers of `RTE_MAX_LCORE * RTE_MAX_LCORE_VAR` bytes (`RTE_MAX_LCORE_VAR=131072`,
  `config/rte_config.h:44`) come from the **libc heap, not hugepages**. The handle is `buffer->data + offset`.
  The value for lcore i is at `handle + i * RTE_MAX_LCORE_VAR`. A new buffer is chained when the offset
  overflows. Demand paging keeps the RSS small. Values are zero-initialized, can never be freed, and live
  until `rte_eal_cleanup` (`eal_lcore_var_cleanup`).
- Debug log line **[verified]**: "Allocated 64 bytes of per-lcore data with a 64-byte alignment".
- Why it exists: static arrays need `__rte_cache_aligned` plus `RTE_CACHE_GUARD` padding per element
  (organised per module). Lcore vars group each lcore's data from all modules contiguously, which needs no
  padding and avoids prefetcher-induced false sharing. Lcore vars are **not accessible from secondary
  processes**. The values may be read by other lcores, but that should be rare and use atomics.
- DPDK itself uses them, e.g. the service core state `RTE_LCORE_VAR(lcore_states)` in `rte_service.c`.
- History: Mattias Rönnblom (Ericsson), RFC Feb 2024, merged in 24.11.

### 2.7 Logging (`lib/log/rte_log.h`, `lib/log/log.c`, doc `prog_guide/log_lib.rst`)

- Levels: EMERG=1, ALERT, CRIT, ERR, WARNING, NOTICE, INFO, DEBUG=8.
- Static logtypes: `RTE_LOGTYPE_EAL`=0, `USER1..8`=24..31. Dynamic types are registered with
  `rte_log_register_type_and_pick_level(name, default)`, which picks up any `--log-level` pattern given on the
  command line, even though registration happens in a constructor before `main`. Parsing happens early in
  init (`eal_parse_log_options` → `eal_log_init`).
- Macros: `RTE_LOG_REGISTER(var, name, LEVEL)`, `RTE_LOG_REGISTER_DEFAULT`, `RTE_LOG_REGISTER_SUFFIX`
  (constructor at `RTE_PRIORITY_LOG`=101). `RTE_LOG(l, t, fmt...)` token-pastes `RTE_LOGTYPE_##t`, so the
  app must `#define RTE_LOGTYPE_TOUR tour_logtype`. `RTE_LOG_LINE(l, t, ...)` adds the newline and the
  "TOUR: " prefix and statically rejects '\n' in the format. `RTE_LOG_DP*` are compiled out above
  `RTE_LOG_DP_LEVEL`.
- **Pitfall [verified]:** using `PRIu64` in the format string requires `<inttypes.h>`. `RTE_LOG_LINE`'s
  static_assert error message is confusing.
- API: `rte_log_set_global_level`, `rte_log_set_level(type, lvl)`, `rte_log_set_level_pattern("lib.*", lvl)`
  (glob), `rte_log_set_level_regexp`, `rte_log_get_level`, `rte_log_can_log`, `rte_openlog_stream(FILE*)`,
  `rte_log_list_types`, `rte_log_dump`.
- CLI: `--log-level=lib.eal:debug`, `--log-level='lib.*:warning'`, `--log-level=5`, `--log-level=help`
  (lists all types **[verified]**), `--log-timestamp=delta` (produced `[<    0.000022>]`), `--log-color=always`,
  `--syslog=local0`.
- Naming convention: `lib.<x>`, `pmd.net.<drv>`, `bus.pci`, `user.<app>`.

### 2.8 Time: TSC, HPET, delays, alarms (`lib/eal/include/generic/rte_cycles.h`, `lib/eal/x86/include/rte_cycles.h`, `lib/eal/common/eal_common_timer.c`, `lib/eal/x86/rte_cycles.c`, `lib/eal/linux/eal_timer.c`, `rte_alarm.h`, `lib/eal/linux/eal_alarm.c`)

- `rte_rdtsc()` and `rte_rdtsc_precise()` (with a barrier), `rte_get_tsc_cycles()`, `rte_get_tsc_hz()`
  (=2.7 GHz here, "TSC frequency is ~2700000 KHz" **[verified]**), `rte_get_timer_cycles/hz()` (TSC or HPET),
  `rte_delay_us/ms()` (busy wait by default; `rte_delay_us_block`, `rte_delay_us_sleep`,
  `rte_delay_us_callback_register`).
- TSC frequency detection (`rte_eal_timer_init` → `set_tsc_freq`): first the arch method (CPUID leaf 0x15 or
  0x16, or MSR 0xCE on Intel), then Linux sysfs/clock-based estimation, then a 1-second-free measurement.
  In a secondary it is read from `mcfg->tsc_hz`.
- This CPU has `constant_tsc`, `nonstop_tsc` and `tsc_known_freq`, so the TSC is usable as wall-clock.
- HPET: `rte_eal_hpet_init` is only built with `RTE_LIBEAL_USE_HPET`. `--no-hpet`.
- **Alarms**: `rte_eal_alarm_set(us, cb, arg)` and `rte_eal_alarm_cancel(cb, arg)` (arg=(void*)-1 matches all).
  They run in the `dpdk-intr` thread via timerfd. They are one-shot, so re-arm in the callback for periodic
  work. Typical use: deferring hotplug or device close out of the interrupt context. **[verified]**: a 50 ms
  alarm fired within 100 ms.
- `rte_timer` library (`lib/timer/rte_timer.h`, doc `timer_lib.rst`): per-lcore skiplist (10 levels),
  states STOPPED/CONFIG/PENDING/RUNNING with owner in a CAS'd status word, `rte_timer_manage()` called in
  the lcore loop, PERIODICAL/SINGLE, and timers can be loaded on another lcore. `examples/timer`
  **[verified]**: timer0 on lcore 0, timer1 bouncing between lcores 0 and 1. It cannot run
  `rte_timer_manage` in unregistered threads.

### 2.9 Service cores (`lib/eal/include/rte_service.h`, `rte_service_component.h`, `lib/eal/common/rte_service.c`, doc `prog_guide/service_cores.rst`, `examples/service_cores`)

- Concept: a *service* is a component's "give me CPU cycles" callback (e.g. event_sw scheduler, eventdev
  adapters, SW crypto scheduler...). *Service lcores* (`-S`, role SERVICE) run a loop over the services mapped
  to them. This lets the same app work with HW (no service) or SW PMDs.
- Component side: `struct rte_service_spec {name, callback, callback_userdata, capabilities (RTE_SERVICE_CAP_MT_SAFE), socket_id}`,
  `rte_service_component_register(&spec, &id)`, `rte_service_component_runstate_set(id, 1)`, `rte_service_component_unregister`.
- App side: `rte_service_get_count/by_name`, `rte_service_lcore_add/del/start/stop/reset_all/list/count`,
  `rte_service_map_lcore_set/get(id, lcore, enable)`, `rte_service_runstate_set(id,1)`,
  `rte_service_set_stats_enable`, `rte_service_attr_get(id, RTE_SERVICE_ATTR_CYCLES|CALL_COUNT|IDLE_CALL_COUNT|ERROR_CALL_COUNT)`,
  `rte_service_lcore_attr_get(lcore, RTE_SERVICE_LCORE_ATTR_LOOPS|CYCLES)`, `rte_service_dump`,
  `rte_service_may_be_active`, `rte_service_lcore_may_be_active`,
  `rte_service_run_iter_on_app_lcore(id, serialize)` (runs one iteration on any lcore, no service core needed **[verified]**).
- Internals: a service runs only if `comp_runstate==RUNNING && app_runstate==RUNNING && mapped`. Non-MT-safe
  services mapped to more than one core are serialized with `execute_lock` trylock (returns -EBUSY when
  contended). Stats count calls, and a callback return of -EAGAIN counts as an *idle* call and its cycles are
  not added. `service_runner_func` is launched with `rte_eal_remote_launch` on the service lcore. It loops
  while `cs->runstate==RUNNING` over the `mapped_services` bitset, incrementing `loops`.
- `rte_service_start_with_defaults()` is called by `rte_eal_init` after bus probe. It starts all service
  lcores and maps services round-robin, one service per core. (So with `-S`, vdev services such as event_sw
  start automatically.)
- `rte_service_init()` runs before `rte_bus_probe()` so that vdevs can register services during probe.
- **[verified]** `dpdk-service_cores -l 0-3` (3 service cores): it printed "insufficent cores to run (High
  Performance)" for profile 0, then the "Mid-High" profile with a per-core mapping table
  (`01 250 250 0 0 0` …). Beware that the output contains ANSI clear-screen codes.

### 2.10 Init sequence (`lib/eal/linux/eal.c: rte_eal_init`, line 566)

This is the exact order in 26.11, ideal for an animated timeline:

1. `run_once` CAS guard; `eal_save_args` (kept for telemetry `/eal/params`); `eal_collate_args` (argparse).
2. `eal_parse_log_options` → `eal_log_init` (logging works from here on).
3. `rte_cpu_is_supported()` (the binary's ISA vs the CPU), `eal_mmu_supported()`.
4. `eal_reset_internal_config`, `rte_eal_cpu_init()` (detects lcores and NUMA from sysfs: "Detected lcore 0 as
   core 0 on NUMA node 0").
5. `eal_parse_args()` (lcores, memory, ...) → `eal_plugins_init()` (`-d` .so drivers) → `eal_trace_init()` →
   `eal_option_device_parse()` (turns `-a/-b/--vdev` into the devargs list).
6. `rte_config_init()`: primary does `rte_eal_config_create` (mmap `<runtime>/config` and take an fcntl write
   lock). Secondary does attach (map read-only) → wait for `mcfg->magic` → reattach at the *same address*
   `mem_cfg_addr`. `--proc-type=auto` → `eal_proc_type_detect` (it is secondary if the file opens but the
   write lock fails).
7. `rte_eal_intr_init()` (the `dpdk-intr` thread, epoll), `rte_eal_alarm_init()`.
8. `rte_mp_channel_init()` (unix socket `<runtime>/mp_socket` for primary, `mp_socket_<pid>_<tsc>` for
   secondary **[verified]**; `dpdk-mp-msg` thread). This happens *before* bus scan so a secondary can fetch
   the primary's vdev list.
9. `dev_vfio_enable()` ("Probing VFIO support... VFIO modules not loaded, skipping" here).
10. `rte_bus_scan()`, which runs every registered bus's `scan()`.
11. IOVA decision: `rte_bus_get_iommu_class()` (each bus votes PA/VA/DC: "Bus pci wants IOVA as 'DC'"), then
    the heuristic (no PA access → VA; IOMMU present → VA; else PA), or `--iova-mode`. It fails if PA was
    requested but is unavailable.
12. Hugepage info (`eal_hugepage_info_init` in primary or `_read` in secondary), `--pagesz-mem` limits.
13. `rte_eal_memzone_init` → `rte_eal_memory_init` (VA reservations: "Ask a virtual area of …") →
    `rte_eal_malloc_heap_init` → `rte_eal_malloc_heap_populate` ("Added 64M to heap on socket 0").
14. `dev_vfio_init_mem`, `eal_mp_dev_hotplug_init` (IPC handlers for hotplug), `rte_eal_tailqs_init`.
15. `rte_eal_timer_init` (TSC Hz), `eal_rand_init`, `eal_check_mem_on_local_socket`.
16. Pin the main thread to its cpuset, `__rte_thread_init(main)`, then create the worker threads (pipes,
    names, affinity). Launch `sync_func` and wait.
17. `rte_service_init()` → `rte_bus_probe()` (**vdev bus last**, so that e.g. bonding/failsafe can refer to
    physical ports) → `rte_service_start_with_defaults()`.
18. `eal_clean_runtime_dir()` (unless no_shconf). Telemetry init (primary, unless `--no-telemetry`) creates
    the `dpdk_telemetry.v2` socket. `eal_mcfg_complete()` sets the magic, which signals secondaries.

`rte_eal_cleanup()` order: mark hugepages freeable (primary) → `rte_service_finalize` → `eal_bus_cleanup`
(drivers' remove/cleanup) → `dev_vfio_cleanup` → `rte_mp_channel_cleanup` → alarms → `rte_trace_save` /
trace fini → hotplug MP cleanup → `rte_eal_memory_detach` ("after this point, any DPDK pointers will become
dangling") → heap cleanup → config cleanup → `eal_lcore_var_cleanup` → log cleanup. Worker threads are *not*
joined; they stay blocked in read.

### 2.11 Buses, drivers, devices, classes (`lib/eal/include/bus_driver.h`, `dev_driver.h`, `rte_bus.h`, `rte_dev.h`, `rte_class.h`, `lib/eal/common/eal_common_bus.c`, `eal_common_dev.c`, `drivers/bus/vdev/`, `drivers/bus/pci/`)

- `struct rte_bus` has the ops scan, probe, find_device, match, probe_device, unplug_device, parse,
  dev_compare, devargs_parse, dma_map/unmap, get_iommu_class, dev_iterate, hot_unplug_handler,
  sigbus_handler, free_device and cleanup, plus a device list and a driver list. It is registered with
  `RTE_REGISTER_BUS(nm, bus)` (constructor at `RTE_PRIORITY_BUS`=110).
- `struct rte_device {name, bus_info, driver, bus, numa_node, devargs}`, which is embedded in bus-specific
  structs (`rte_pci_device`, `rte_vdev_device`). Drivers register by constructor:
  `RTE_PMD_REGISTER_VDEV(net_null, drv)`, `RTE_PMD_REGISTER_PCI`, and metadata with
  `RTE_PMD_REGISTER_PARAM_STRING` / `_KMOD_DEP`, which `dpdk-pmdinfo.py` reads from the binary.
- Generic probe (`rte_bus_generic_probe`): for each device, skip it if it is ignored (block list, or not in
  the allow list) or already probed, then find a matching driver and call `probe_device`.
- Classes (`rte_class`, e.g. "eth") are used by devargs `class=` filters and `RTE_DEV_FOREACH`.
- Linux PCI: devices are found in `/sys/bus/pci/devices`, must be bound to `vfio-pci`/`uio_pci_generic`/
  `igb_uio` (`usertools/dpdk-devbind.py --status`), or the driver must be bifurcated (mlx5). On this VM the
  only NIC is virtio eth0, which carries the session network, so **always use `--no-pci`** and never bind it.

### 2.12 Devargs (`lib/eal/include/rte_devargs.h`, `lib/eal/common/eal_common_devargs.c`, doc `prog_guide/devargs.rst`)

- Simplified syntax: `[bus:]id[,k=v...]`, e.g. `net_ring0`, `vdev:net_pcap0,rx_pcap=in.pcap`,
  `0000:02:00.0,txq_inline=128`. If the bus is omitted, every bus's `parse` is tried in turn.
- Multi-layer syntax: `bus=vdev,name=net_ring0/class=eth/driver=...,args`. It is driver-centric and can
  match many devices.
- `struct rte_devargs {type, policy, name, drv_str/args, bus, cls, bus_str, cls_str, data}`. API:
  `rte_devargs_parse`, `rte_devargs_layers_parse`, `rte_devargs_insert/remove`, `rte_devargs_dump`.
  Drivers parse args with `rte_kvargs_parse(devargs->args, valid_keys)` and `rte_kvargs_process`.
- `RTE_DEV_FOREACH(dev, "bus=vdev", &it)` listed `net_null0` (from `--vdev`) and `net_null7` (hotplugged)
  **[verified]**. `RTE_ETH_FOREACH_MATCHING_DEV(port, "class=eth,mac=…", &it)`.

### 2.13 Hotplug (`rte_dev.h`, `eal_common_dev.c`, `hotplug_mp.c`, `lib/eal/linux/eal_dev.c`, doc `device_hotplug.rst`)

- `rte_dev_probe(devargs)` parses → inserts the devargs → `bus->scan` → `find_device` → `probe_device` →
  sends an MP sync to the secondaries. `rte_dev_remove(dev)` checks `rte_dev_is_probed`, coordinates the
  secondaries first, then calls `bus->unplug_device`. The device struct is freed only at cleanup.
  `rte_eal_hotplug_add("vdev","net_ring0","")` and `rte_eal_hotplug_remove("vdev","net_ring0")`.
- Multi-process: either side may initiate. The primary broadcasts, waits with a timeout, and rolls back on
  failure. Vdevs: at startup a secondary asks the primary for its vdev list. A vdev given with `--vdev` in a
  secondary is process-local.
- **[verified]** with `dpdk-hotplug_mp`: the secondary ran `attach net_null5`, so `list` showed `0 net_null5`;
  `detach` removed it. (The primary's `list` has to come after the attach; races are easy to show.)
- Events: ethdev `RTE_ETH_EVENT_NEW/DESTROY` (via `rte_eth_dev_callback_register`). Kernel uevents need
  `rte_dev_hotplug_handle_enable()` (SIGBUS handler) plus `rte_dev_event_monitor_start()` (a
  NETLINK_KOBJECT_UEVENT socket) plus `rte_dev_event_callback_register(NULL, cb, arg)`. Callbacks run in the
  interrupt thread, so **never allocate or probe there**; defer with `rte_eal_alarm_set`. `RTE_DEV_EVENT_ADD`
  is reported only for PCI.

### 2.14 Multi-process (doc `prog_guide/multi_proc_support.rst`, `sample_app_ug/multi_process.rst`, `lib/eal/common/eal_common_proc.c`, `lib/eal/common/eal_memcfg.h`, `examples/multi_process/{simple_mp,symmetric_mp,client_server_mp,hotplug_mp}`)

- **Runtime dir:** `$RUNTIME_DIRECTORY/dpdk/<prefix>`, else `/var/run/dpdk/<prefix>` for root, else
  `$XDG_RUNTIME_DIR/dpdk` or `/tmp/dpdk`. The default prefix is `rte`. Contents **[verified]**: `config`
  (the `rte_mem_config`, 25 KB), `fbarray_memseg-2048k-0-0`, `fbarray_memzone`, `hugepage_info`, the
  `mp_socket` and `dpdk_telemetry.v2` sockets. Hugepage files are `/dev/hugepages/<prefix>map_<list>_<seg>`
  (e.g. `ch02mpmap_0_17`).
- `struct rte_mem_config` (`eal_memcfg.h`): magic, version (it rejects a different DPDK version), the locks
  mlock, qlock, mplock, tlock, ethdev_lock and memory_hotplug_lock, the memzones fbarray, the memseg lists,
  the tailq heads (named rings, mempools, hashes...), malloc heaps, `mem_cfg_addr`, and the `legacy_mem` and
  `single_file_segments` flags.
- **Same virtual addresses:** a secondary maps the config and every memseg at the primary's VA (the
  `--base-virtaddr` hint exists for when that fails). **[verified]**: memzone `va=0x1021fdf40` was identical
  in primary and secondary, and the secondary wrote into it while the primary read the new value.
- Requirements: same DPDK version, same binary for function pointers, same `-a/-b`, same mount and PID
  namespaces, same `--legacy-mem`/`--single-file-segments`, **disjoint lcores**. Interrupts arrive only in
  the primary. A secondary cannot allocate new hugepages without the primary alive (allocation goes through
  the primary via IPC). Lcore vars and registered non-EAL threads do not work across processes. ASLR can
  break the mapping.
- `--no-huge` primary → secondary fails: "Failed to open shared memory! Cannot get hugepage information"
  **[verified]**. A secondary with no primary fails: "Cannot open '/var/run/dpdk/X/config'" **[verified]**.
- **IPC API (`rte_eal.h`):** `struct rte_mp_msg {name[64], len_param, num_fds, param[256], fds[8]}`,
  `rte_mp_action_register(name, cb)`, `rte_mp_action_unregister`, `rte_mp_sendmsg` (fire-and-forget),
  `rte_mp_request_sync(&req, &reply, &ts)` (the caller must `free(reply.msgs)`), `rte_mp_request_async(&req,
  &ts, cb)`, `rte_mp_reply(&msg, peer)`. Direction: a primary broadcasts to all secondaries, and a secondary
  can send only to the primary. Callbacks run in the `dpdk-mp-msg` thread (async timeouts run in the
  interrupt thread). No recursive requests, and no malloc inside IPC callbacks (deadlock). You must always
  reply explicitly. **[verified]** round trip: `[S] sent=1 received=1 reply='pong to 'ping' from pid …'`.
- Deployment models: symmetric peers (`symmetric_mp`, RSS queue per process), asymmetric client/server
  (`client_server_mp`: `mp_server` and `mp_client` with rings), independent instances (distinct
  `--file-prefix`), and tools (`dpdk-proc-info`, `dpdk-pdump`, `dpdk-dumpcap` attach as secondaries).

### 2.15 IOVA, VFIO, UIO (doc `env_abstraction_layer.rst` §IOVA Mode Detection, `linux_gsg/linux_drivers.rst`, `lib/eal/linux/eal_vfio*.c`)

- IOVA is the address a device uses for DMA. **PA** means the physical address (`/proc/self/pagemap`, needs
  root; contiguity matters). **VA** means IOVA == process VA (needs an IOMMU through VFIO, or a vdev or a
  driver that does not DMA). **DC** means "don't care".
- Bus voting: if all buses say PA, use PA; if all say VA, use VA; if they mix or say DC, use DC. DC then
  falls back to the heuristic: no PA access → VA; `/sys/kernel/iommu_groups` not empty → VA; else PA. A PCI
  driver with `RTE_PCI_DRV_NEED_IOVA_AS_VA` forces VA. Build option `enable_iova_as_pa=false`
  (`RTE_IOVA_IN_MBUF=0`) forces VA and removes `buf_iova` from the mbuf.
- **[verified] on this VM:** `--no-huge` gives VA (memfd, no PA). Hugepages as root give **PA** (simple_mp,
  mp_ipc printed iova=0x168ffdf40 ≠ va). `--iova-mode=pa --no-huge` gives an error. This is a nice
  side-by-side demo.
- VFIO: `vfio-pci` gives an IOMMU-protected DMA mapping (`VFIO_IOMMU_MAP_DMA` for each memseg; a memory
  event callback maps new hugepages). Group mode uses `/dev/vfio/vfio` plus `/dev/vfio/<grp>`; cdev mode
  (26.11) uses `/dev/iommu` plus `/dev/vfio/devices/vfioX`. Group mode is preferred when available, and there
  is no option to force either. No-IOMMU mode: `enable_unsafe_noiommu_mode=1`. Interrupt modes:
  `--vfio-intr legacy|msi|msix`. SR-IOV VF token: `--vfio-vf-token`. The DMA entry limit
  `dma_entry_limit`=64K, and locked-memory rlimits apply.
- UIO: `uio_pci_generic` (in-kernel, no MSI-X, no VFs) or `igb_uio` (dpdk-kmods). Unsafe, root only, needs
  IOMMU off or passthrough, may be blocked by Secure Boot. The interrupt thread polls `/dev/uioX`.
- RX interrupts per queue (`rte_eth_dev_rx_intr_*`, epoll via `rte_epoll.h`) need VFIO MSI-X. Under UIO
  they share a vector with LSC.
- This machine has no `/sys/module/vfio` and an empty `/sys/kernel/iommu_groups`, so VFIO and UIO **can only
  be taught conceptually** (with diagrams, plus the log lines "VFIO modules not loaded, skipping VFIO
  support").

### 2.16 Misc EAL facilities worth a sidebar

- CPU flags: `rte_cpu_get_flag_enabled(RTE_CPUFLAG_AVX512F)`; `rte_vect_get/set_max_simd_bitwidth`;
  `--force-max-simd-bitwidth=64` disables vector paths.
- `rte_panic` and `rte_exit` (calls cleanup... prints and exits), `rte_dump_stack`, signal-safe function list
  (env_abstraction_layer.rst "Signal Safety").
- `rte_hypervisor_get()`, which reports KVM here.
- The interrupt framework `rte_interrupts.h` (`rte_intr_callback_register` on the `dpdk-intr` epoll loop).
- `rte_keepalive.h`, `rte_random.h` (`rte_rand`, per-lcore state), `rte_tailq.h`.
- Telemetry `/eal/*` endpoints **[verified]**: `/eal/lcore/list` → `[1, 2]`; `/eal/lcore/info,2` →
  `{"lcore_id":2,"socket":0,"role":"RTE","cpuset":[2]}`; `/eal/params` (the saved argv); `/eal/lcore/usage`.
  Use `dpdk-telemetry.py -f <prefix>` (installed in `$DPDK_PREFIX/bin`).
- Trace: `--trace='lib.eal.thread*' --trace-dir=…`. It writes CTF, which you view with babeltrace or Trace
  Compass. Service and thread tracepoints exist (`rte_eal_trace_thread_remote_launch`,
  `…lcore_running/stopped`, `service_run_begin/end`).

---

## 3. Runnable examples that work on THIS machine

Common prefix: `source …/dpdk-env.sh`. Build with
`gcc x.c -o x $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk)` (add
`-DALLOW_EXPERIMENTAL_API` for lcore vars). This takes about 1 s. Use a unique `--file-prefix=chNN…`, and
wrap every run in `timeout -s INT -k 5 N`.

Prebuilt binaries are in `$DPDK_SRC/build/examples/`: dpdk-helloworld, dpdk-timer, dpdk-service_cores,
dpdk-simple_mp, dpdk-symmetric_mp, dpdk-mp_server, dpdk-mp_client, dpdk-hotplug_mp, dpdk-l2fwd-keepalive,
dpdk-skeleton, and more. Tools in `$DPDK_PREFIX/bin` are dpdk-testpmd, dpdk-proc-info, dpdk-telemetry.py,
dpdk-devbind.py, dpdk-hugepages.py and dpdk-pmdinfo.py.

| # | Example | Command / idea | What it shows | Status |
|---|---|---|---|---|
| E1 | helloworld | `dpdk-helloworld -l 0-3 --no-huge -m 64 --no-pci --file-prefix=c02a` | prints "hello from core N" in nondeterministic order | verified |
| E2 | lcore mapping | `dpdk-helloworld --lcores='0,(1-3)@(1,2)' … --log-level=lib.eal:debug` | "lcore 1 is ready (cpuset=[1-2])", control-thread CPUs | verified |
| E3 | remap | `-l 2-3 -R` | lcore ids 0,1 on CPUs 2,3 | verified |
| E4 | init trace | any app with `--log-level=lib.eal:debug --log-timestamp=delta` | the full init sequence with timings (good for the timeline animation) | verified |
| E5 | **eal_tour.c** (written, compiled and run; source in this session's scratch `ch02/eal_tour.c`; reproduce in the course) | `./eal_tour -l 0-2 --no-huge -m 64 --no-pci --vdev net_null0 --file-prefix=c02t` | remote_launch with return codes (10, 20), lcore vars per lcore, `rte_thread_register` (id -1 → 3), alarm, a service run on the app lcore, `rte_dev_probe("net_null7")`, `RTE_DEV_FOREACH`, `rte_lcore_dump`, cleanup | verified |
| E6 | errors lab | `-l 0-5`, `--main-lcore` not in the list, `--iova-mode=pa --no-huge`, `--vdev net_bogus0`, secondary without primary | read EAL error messages; debug them with `lib.eal:debug` | verified |
| E7 | thread anatomy | run `dpdk-timer -l 1-2 …` in the background, then `for t in /proc/$P/task/*; do cat $t/comm; grep Cpus_allowed_list $t/status; done` | main/worker/intr/mp-msg/telemetry threads and their affinities | verified |
| E8 | service cores sample | `stdbuf -oL timeout -s INT 8 dpdk-service_cores -l 0-3 --no-huge -m 64 --no-pci` | profiles, mapping table, `rte_service_dump`. With only 4 CPUs profile 0 says "insufficient cores" | verified |
| E9 | own service + `-S` | register 2 services, `-l 0-2 -S 2`, map both to lcore 2, read `RTE_SERVICE_ATTR_CALL_COUNT/CYCLES`, toggle runstate, show the MT-unsafe trylock -EBUSY when mapped to 2 service cores | full service lifecycle | to build (API verified) |
| E10 | timer lib | `dpdk-timer -l 0-1 --no-huge -m 64 --no-pci` | periodic plus one-shot timers moving between lcores | verified |
| E11 | TSC lab | measure `rte_rdtsc` overhead, compare with `clock_gettime`, `rte_delay_us_block` vs `rte_delay_us_sleep` CPU usage | time sources | to build |
| E12 | log lab | `RTE_LOG_REGISTER(t, user.myapp, INFO)`; run with `--log-level='user.*:debug'`, `--log-level=help`, `rte_openlog_stream(fopen(...))`, `--syslog` | logging | verified (register and help) |
| E13 | lcore var vs array benchmark | false sharing: an array of counters without padding vs cache-guarded vs lcore var, 3 workers incrementing for 1 s; also `dpdk-test` `lcore_var_perf_autotest` if `build/app/dpdk-test` exists | why lcore vars exist | to build |
| E14 | multi-process basics | primary `dpdk-simple_mp -l 0-1 -m 64 --no-pci --file-prefix=c02mp --proc-type=primary`, secondary `-l 2-3 --proc-type=auto`; feed commands on stdin with `(sleep 6; echo "send hi"; sleep 4; echo quit) \|` | "Auto-detected process type: SECONDARY", ring messaging, `ls /var/run/dpdk/c02mp` | verified |
| E15 | **mp_ipc.c** (written and verified) | primary reserves memzone `ch02_shared` and registers action `ch02_ping`; secondary looks it up, overwrites it, `rte_mp_request_sync` | same VA in both processes, IPC round trip, PA vs VA iova | verified |
| E16 | hotplug across processes | `dpdk-hotplug_mp` primary `-l 0 -m 32` plus secondary `-l 1`; commands `attach net_null5`, `list`, `detach net_null5` | MP-synchronized hotplug | verified |
| E17 | hotplug in one process | `rte_dev_probe("net_ring1")` → `RTE_ETH_FOREACH_MATCHING_DEV` → configure → stop → `rte_dev_remove`; register an `RTE_ETH_EVENT_NEW` callback | device lifecycle | to build (probe verified) |
| E18 | devargs lab | `--vdev 'net_ring0' --vdev 'net_null1,size=128'`; `rte_devargs_parse` on several strings and print bus/name/args; `-A` plus a manual `rte_dev_probe` | parsing layers | to build |
| E19 | testpmd hotplug | `dpdk-testpmd -l 0-1 --no-huge -m 256 --no-pci --vdev net_null0 --file-prefix=c02tp -- -i`, then `port attach net_ring1`, `show port summary`, `port stop 1`, `port detach 1` | interactive hotplug | to try |
| E20 | telemetry | `dpdk-telemetry.py -f c02tel` with input `/eal/lcore/list`, `/eal/lcore/info,2`, `/eal/params` | live introspection | verified |
| E21 | IOVA demo | the same program with `--no-huge` (VA) vs hugepages `-m 32` (PA as root); print `rte_mem_virt2iova(ptr)` and `mz->iova` | IOVA modes | verified |
| E22 | cleanup and leftovers | run with `-m 32` and kill with SIGKILL, then show `/dev/hugepages/<prefix>map_*` and `free_hugepages` drop; then show that a clean `rte_eal_cleanup` exit and `--in-memory` leave no hugepage files (the runtime dir files config/fbarray remain) | resource hygiene | verified (clean exits) |
| E23 | veth + af_packet | `ip link add c02v0 type veth peer name c02v1; ip link set c02v0 up; ip link set c02v1 up`, `--vdev net_af_packet0,iface=c02v0`, then delete the pair | a kernel-visible vdev via the bus | standard; delete afterwards |
| E24 | `--no-auto-probing` | `-A --vdev net_null0`: per the docs the vdev bus is not affected by auto-probing (a vdev needs an explicit flag anyway) | probing control | to try |

Verified output snippets for the course:

```
EAL: Bus pci wants IOVA as 'DC'
EAL: Bus vdev wants IOVA as 'DC'
EAL: Buses did not request a specific IOVA mode.
EAL: Physical addresses are unavailable, selecting IOVA as VA mode.
EAL: Selected IOVA mode 'VA'
EAL: TSC frequency is ~2700000 KHz
EAL: Main lcore 0 is ready (tid=7f9053516a00;cpuset=[0])
EAL: lcore 1 is ready (tid=7f904e1fc6c0;cpuset=[1-2])
```

```
TOUR: lcore 1 (cpu 1, socket 0) did 8134427 loops
lcore 1 returned 10
non-EAL thread before register: lcore_id=-1
non-EAL thread after register: lcore_id=3 role=3
service 'tour_svc' id=0 ran 1000 times on app lcore
rte_dev_probe(net_null7) = 0
vdev bus device: net_null0
vdev bus device: net_null7
lcore 2, socket 0, role SERVICE, cpuset 2      (with -S 2)
```

```
[P] memzone va=0x1021fdf40 iova=0x168ffdf40
[S] memzone va=0x1021fdf40 content='written by primary pid 20156'
[S] sent=1 received=1 reply='pong to 'ping' from pid 20156'
[P] memzone now: overwritten by secondary pid 20161
```

Code skeleton for the IPC example (complete and verified; the course should include the full file):
the primary calls `rte_memzone_reserve("ch02_shared",64,SOCKET_ID_ANY,0)`, then
`rte_mp_action_register("ch02_ping", on_ping)`, where `on_ping` builds a reply `rte_mp_msg` with the same
name and calls `rte_mp_reply(&reply, peer)`. The secondary calls `rte_memzone_lookup`, then
`rte_mp_request_sync(&req,&rep,&(struct timespec){2,0})`, then `free(rep.msgs)`. It needs `<rte_memory.h>`
for `SOCKET_ID_ANY` and `<stdlib.h>` for `free`.

---

## 4. Visualization and animation ideas

1. **EAL layer cake** (static SVG): App → libs (ethdev, mempool, ring…) → EAL services (memory, lcores,
   devices/buses, IPC, timers, logs, interrupts) → Linux (hugetlbfs, sysfs, VFIO, pthreads, epoll, unix
   sockets).
2. **`rte_eal_init` timeline** (animated, step-through): the 18 phases from §2.10 light up in order. Each
   step shows the matching debug log line from E4 and the threads, files and sockets it creates
   (`config` file appears, `mp_socket` appears, threads spawn, `dpdk_telemetry.v2` appears). Have a toggle
   for primary vs secondary paths (create vs attach/reattach, `hugepage_info_init` vs `_read`).
3. **lcore ↔ CPU mapper** (interactive): the student types a `-l` string such as `0,(1-3)@(1,2)` and the
   page draws lcore boxes with arrows to CPU boxes, highlights where control threads land (process affinity
   minus the lcores), and flags oversubscription. Implement the grammar in JS: digits, ranges, groups, `@`.
4. **remote_launch state machine**: main and worker swimlanes. Animate the 1-byte pipe write, the worker
   waking from `read()`, the state flip WAIT→RUNNING (release store), the ack byte, the spin on `f`,
   running f, the return value, then RUNNING→WAIT and `rte_eal_wait_lcore` spinning. Show the -EBUSY path.
5. **Process anatomy** of a running DPDK process: thread boxes (main lcore, workers, dpdk-intr, dpdk-mp-msg,
   dpdk-telemet-v2, service lcores) placed on CPU columns, with real data from E7.
6. **Lcore variables memory layout**: two side-by-side grids. Static arrays are organised per module, with
   padding shown as hatching. Lcore var buffers are organised per lcore slice of `RTE_MAX_LCORE_VAR` bytes.
   Animate "lcore 2 touches its data" and count the cache lines touched in each layout. Also animate false
   sharing: two cores ping-ponging one cache line (MESI states).
7. **Service core scheduler**: a matrix of services (rows) × service lcores (columns) with toggles for
   mapping, comp_runstate and app_runstate. A "loop" animation shows each service lcore cycling through its
   mapped services. An MT-unsafe service mapped to two cores shows the trylock, with one core getting
   -EBUSY. Counters for calls, idle calls and cycles tick up.
8. **Log routing**: a logtype tree (`lib.eal`, `lib.ethdev`, `pmd.net.null`, `user.myapp`) with level
   sliders. A `--log-level` pattern input highlights the matching nodes. Messages flow and are filtered by
   level before they reach stderr, syslog or a file stream.
9. **Time**: a TSC counter ticking at 2.7 GHz, converting cycles to µs, and a busy-poll loop with a deadline
   (`if (rte_rdtsc() - last > period)`). Alarm vs `rte_timer` comparison: the alarm runs in dpdk-intr, while
   the timer runs in the lcore that calls `rte_timer_manage`. Add a skiplist insertion animation for
   rte_timer.
10. **Bus/driver/device graph**: constructors run before `main` (RTE_INIT priority bands LOG 101 < BUS 110 <
    CLASS 120 < default). Drivers attach to bus driver lists, scan fills the device lists, probe draws
    matching edges, and vdev goes last. Clicking a device shows its devargs.
11. **Devargs parser playground**: type a devargs string and show the parse into bus / class / driver layers
    plus the kvargs table.
12. **Hotplug sequence diagram**: primary, secondary1 and secondary2 lifelines. Attach → broadcast → replies
    → success, or failure → rollback. A variant shows the secondary-initiated flow.
13. **Multi-process shared memory**: two process address spaces (columns) whose hugepage segments map to the
    same physical pages, at identical VAs. The runtime dir file tree. The fcntl lock icon on `config`
    explains auto-detection. IPC messages travel over unix sockets (`mp_socket`, `mp_socket_<pid>_<tsc>`).
14. **IOVA decision flowchart** (interactive): checkboxes "root?", "hugepages?", "IOMMU groups present?",
    "VFIO loaded?", "bus votes", "--iova-mode" and the build option. The path animates to PA or VA or an
    error. Prefill it with this machine's facts (no IOMMU, root) to show both outcomes from E21.
15. **VFIO vs UIO vs bifurcated**: a DMA path diagram. Device → IOMMU (IOVA→PA translation table) → RAM for
    VFIO, vs device → PA directly for UIO (unsafe, can scribble anywhere), vs mlx5-style kernel netdev
    sharing.
16. **Cleanup checklist animation**: resources unwind in reverse order. Then a "crash" button leaves
    `rtemap_*` files and shows `free_hugepages` drop.

---

## 5. Common pitfalls (with fixes)

- Forgetting `argc -= ret; argv += ret;` or the `--` before app args, so the app parses EAL flags or EAL
  rejects app flags.
- Calling `rte_eal_init` twice (EALREADY), or continuing after it fails. Use `rte_exit(EXIT_FAILURE, ...)`.
- Creating DPDK objects (rings, mempools, hashes, memzones) from several threads concurrently. The create
  functions are not MT-safe, so create them on the main lcore during init.
- Assuming lcore id == CPU id. Use `rte_lcore_to_cpu_id()`. `rte_lcore_count()` includes service lcores.
  Iterate with FOREACH macros, not `0..count`.
- Binding several lcores to one CPU (`(1-3)@1`) while they use rings, mempools or spinlocks. Preemption of
  a lock holder can cause livelock or deadlock. Non-preemptive `rte_ring` MP/MC must never be used by
  SCHED_FIFO/RR threads.
- Using all CPUs as lcores, which starves control threads (alarms, IPC, telemetry, hotplug, secondary
  startup).
- Unregistered threads: `rte_lcore_id()==LCORE_ID_ANY`, mempool cache bypass (slow), no `rte_timer_manage`,
  no per-lcore stats. Use `rte_thread_register()`, but not in multi-process.
- Lcore vars: experimental (needs `ALLOW_EXPERIMENTAL_API`), unusable in secondaries, cannot be freed, size
  ≤ 128 KB. Do not add cache-line padding.
- Logging: `RTE_LOG(INFO, MYAPP, ...)` needs `#define RTE_LOGTYPE_MYAPP <var>`. `RTE_LOG_LINE` with a
  trailing `\n` fails to compile. `PRIu64` needs `<inttypes.h>`. Logging from a signal handler is not
  async-signal-safe.
- Calling DPDK functions inside signal handlers. Only the listed signal-safe functions are allowed. Set a
  `volatile`/atomic flag instead.
- Time: using `rte_get_timer_hz()` vs `rte_get_tsc_hz()` inconsistently. `rte_delay_ms` burns CPU, so use
  `rte_delay_us_sleep` in control paths. A TSC on a VM without `constant_tsc` is unreliable.
- Alarms and device-event callbacks run in the interrupt thread. Do not block, allocate memory, probe or
  close devices there; reschedule instead. Do not close an ethdev from its own removal callback.
- Service cores: forgetting either runstate (component or app), forgetting to map the service, or calling
  `rte_service_lcore_start` without `rte_service_lcore_add`. An MT-unsafe service mapped to two cores
  serializes (shows as -EBUSY). Profile with stats enabled, since stats cost some cycles.
- Multi-process: different binaries or DPDK versions, overlapping `-l` lists between processes, a primary
  started with `--no-huge`/`--in-memory`/`--no-shconf`, a mismatched `--file-prefix`, ASLR address
  conflicts ("Could not map memory at the same address" → `--base-virtaddr`), a secondary needing interrupts
  or LSC, function pointers in shared memory (e.g. `rte_hash` hash function; use `*_with_hash` APIs),
  forgetting `free(reply.msgs)` after `rte_mp_request_sync`, malloc inside an IPC callback (deadlock), not
  replying to a request (the requester times out).
- Leftovers: crashed or killed processes leave `/dev/hugepages/<prefix>map_*` files and runtime-dir files,
  so hugepages leak for everyone. Fix with `rm /dev/hugepages/<prefix>map_*` or use `--in-memory` /
  `--huge-unlink`. On a shared machine you **must** use a unique `--file-prefix`, otherwise you clobber or
  attach to someone else's primary (the default prefix "rte" is shared).
- IOVA: forcing `--iova-mode=va` with a UIO-bound NIC (no IOMMU) lets the device DMA to wrong addresses.
  Forcing PA without root or hugepages fails. `RTE_PCI_DRV_NEED_IOVA_AS_VA` drivers fail in PA.
- Never bind the management NIC to vfio-pci or uio. On this VM, always use `--no-pci` and vdevs.
- Hotplug: `rte_dev_remove` without stopping the port first. Expecting device memory to be freed
  immediately; it is freed only at cleanup. Calling `rte_dev_probe` from a uevent callback (it deadlocks).
- `-a` and `-b` are mutually exclusive. `-b` is invalid together with `-A`. A vdev is never auto-probed;
  it always needs `--vdev`.
- `--legacy-mem` without `-m` grabs **all** hugepages, which is bad on this shared box.

---

## 6. Boundary with other chapters (what to hand off)

- Memory deep-dive (memsegs, fbarray, memzones, the `rte_malloc` heap with `malloc_elem` split and merge,
  dynamic vs legacy mode, `--single-file-segments`, `--huge-unlink=never` with dirty segments, external heaps
  and `rte_extmem_*`, memory event callbacks and validators) goes to the **memory chapter**. This chapter
  should only show where memory init sits in the timeline and the VA-sharing rule for multi-process.
- `rte_timer` library details could go to a "timers and scheduling" or "utilities" chapter.
  `rte_ring`/`rte_mempool` preemption caveats belong to those chapters, and EAL references them.
- Ethdev hotplug events and port configuration belong to the ethdev chapter. Eventdev SW and service-core use
  belong to the eventdev chapter.
- Telemetry and trace may have their own chapter. Here, use them only as introspection tools.

---

## 7. Source references (paths relative to `$DPDK_SRC`)

Docs:

- `doc/guides/prog_guide/env_abstraction_layer.rst` (1251 lines: init, memory, lcores, threads, IOVA,
  signal safety, malloc). Figures: `img/linuxapp_launch.*`, `img/malloc_heap.*`.
- `doc/guides/prog_guide/{multi_proc_support,service_cores,lcore_var,log_lib,devargs,device_hotplug,timer_lib,trace_lib,telemetry_lib,thread_safety}.rst`
- `doc/guides/linux_gsg/{eal_args.include,linux_eal_parameters,linux_drivers,sys_reqs,enable_func}.rst`
- `doc/guides/sample_app_ug/{hello_world,multi_process,service_cores,timer,l2fwd_keepalive}.rst`
- `doc/guides/rel_notes/release_25_07.rst` (`-l` enhancement, argparse), `release_25_11.rst` (`-R`),
  `release_26_07.rst` (`--pagesz-mem`, `-A`), `release_26_11.rst` (VFIO cdev, `rte_vfio_*` internal).

Code:

- `lib/eal/linux/eal.c` (rte_eal_init :566, rte_eal_cleanup, config create/attach/reattach :174/:261/:300,
  eal_proc_type_detect :346)
- `lib/eal/common/eal_common_options.c`, `eal_option_list.h`, `eal_internal_cfg.h`
- `lib/eal/common/eal_common_launch.c`, `eal_common_thread.c` (eal_thread_loop :156),
  `lib/eal/unix/eal_unix_thread.c` (pipe wake/ack), `lib/eal/unix/rte_thread.c`
- `lib/eal/common/eal_common_lcore.c`, `eal_common_lcore_var.c`, `include/rte_lcore.h`, `rte_lcore_var.h`,
  `rte_per_lcore.h`, `rte_launch.h`, `rte_thread.h`
- `lib/eal/common/rte_service.c` (service_runner_func, service_run, start_with_defaults :617),
  `include/rte_service.h`, `rte_service_component.h`
- `lib/log/rte_log.h`, `lib/log/log.c`, `log_timestamp.c`, `log_color.c`, `log_syslog.c`
- `lib/eal/common/eal_common_timer.c`, `lib/eal/x86/rte_cycles.c`, `include/generic/rte_cycles.h`,
  `lib/eal/linux/eal_timer.c`, `eal_alarm.c`, `eal_interrupts.c`
- `lib/eal/common/eal_common_proc.c` (rte_mp_*), `eal_memcfg.h`, `eal_common_mcfg.c`, `hotplug_mp.c`,
  `malloc_mp.c`
- `lib/eal/common/eal_common_bus.c` (rte_bus_scan :60, generic probe :82, rte_bus_probe :161 with vdev last),
  `eal_common_dev.c`, `eal_common_devargs.c`, `eal_common_class.c`, `include/bus_driver.h` (struct rte_bus
  :353), `dev_driver.h`, `rte_devargs.h`, `rte_dev.h`
- `drivers/bus/vdev/vdev.c`, `bus_vdev_driver.h` (RTE_PMD_REGISTER_VDEV :121), `drivers/bus/pci/linux/`
- `lib/eal/linux/eal_vfio.c`, `eal_vfio_group.c`, `eal_vfio_cdev.c`, `eal_vfio_mp_sync.c`, `eal_dev.c`
  (uevent)
- `lib/eal/include/rte_common.h:370` (RTE_PRIORITY_LOG/BUS/CLASS, RTE_INIT)
- `config/rte_config.h` (RTE_MAX_LCORE_VAR), `build/rte_build_config.h` (RTE_MAX_LCORE=128)

Examples:

- `examples/helloworld`, `examples/timer`, `examples/service_cores`,
  `examples/multi_process/{simple_mp,symmetric_mp,client_server_mp,hotplug_mp}`, `examples/l2fwd-keepalive`,
  `examples/skeleton`
- `app/test/test_lcores.c`, `test_service_cores.c`, `test_lcore_var*.c`, `test_eal_flags.c` (a great source
  of option edge cases)

Web and history:

- Memory hotplug / dynamic memory (18.05, Anatoly Burakov, a 70-patch series):
  https://mails.dpdk.org/archives/dev/2018-April/096691.html and Intel's "Memory in DPDK" article series:
  https://intel.com/content/www/us/en/developer/articles/technical/memory-in-dpdk-part-4-1811-and-beyond.html
- Lcore variables RFC (Mattias Rönnblom, 2024; merged 24.11):
  https://mails.dpdk.org/archives/dev/2024-September/300817.html, https://doc.dpdk.org/guides/prog_guide/lcore_var.html
- Background I know but did not re-check online:
  - DPDK began at Intel around 2010 and became the Linux Foundation project dpdk.org in 2013 (6WIND hosted
    it) and 2017.
  - Service cores arrived in 17.05 (Harry van Haaren), driven by event_sw.
  - IOVA-as-VA became the default preference around 19.x.
  - The `rte_thread` API was generalized for the Windows port (21.x–22.x).
  - The log library was split from EAL in 23.11.

---

## 8. Scratch artifacts from this research (for re-use by the implementers)

Copied into the course tree at `/home/user/ai_lab/dpdk_research/research/02-eal-examples/` (`eal_tour.c`, `mp_ipc.c`, `hw2.txt` debug init log, `tour.txt`, `ipc_p.txt`, `ipc_s.txt`). The originals are in the session scratchpad:

- `/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/ch02/eal_tour.c`
  (verified; build with `-DALLOW_EXPERIMENTAL_API`)
- `/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/ch02/mp_ipc.c` (verified)
- Captured outputs: `hw1.txt`, `hw2.txt` (debug init log), `tour.txt`, `mp_primary.txt`, `mp_secondary.txt`,
  `ipc_p.txt`, `ipc_s.txt`, `svc.txt` and `hp_p.txt`/`hp_s.txt`, all in the same directory.
