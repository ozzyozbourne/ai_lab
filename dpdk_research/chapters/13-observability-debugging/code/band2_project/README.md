# Band 2 project: a multi-core L2 forwarder you can watch

Chapter 13 closes band 2 (chapters 5 to 13). This project uses all of it.

## Specification

Build `l2fwd_mc`, a DPDK application that:

1. **Ports and lcores.** Runs with `-l 0-2` and four `net_ring` ports
   (`--vdev=net_ring0 ... --vdev=net_ring3`). Lcore 1 owns ports 0 and 1,
   lcore 2 owns ports 2 and 3. No queue is ever touched by two lcores.
2. **Forwarding.** Each worker lcore receives on one port of its pair and
   sends on the other, in both directions, with an l2fwd-style MAC rewrite
   (ch10). Unsent mbufs are freed and counted as drops (ch8).
3. **A finite, exact test.** At start, inject `--frames N` (default 512)
   frames into the first port of each pair. Each frame carries a 32-bit hop
   budget (`--hops H`, default 200000) right after its UDP header. Every
   receive decrements it; at 0 the frame is freed and counted as a drop.
   A `net_ring` port is a loopback, so frames circulate inside their pair.
4. **Per-lcore statistics** `rx`, `tx`, `drop`: one cache-aligned entry per
   lcore, written only by that lcore with relaxed atomics, read by others.
5. **Observability on the main lcore:**
   * an `rte_timer` that prints a `[timer]` report line every 500 ms (ch11);
   * a `cmdline` shell on stdin with `show stats`, `show pool`, `quit`,
     answering with lines that start with `[shell]`. The main lcore must
     not block: poll stdin and feed `cmdline_in()` (26.11 has no
     `cmdline_poll()`). End of input counts as `quit`;
   * a telemetry endpoint `/band2/stats` returning `in_use` and a nested
     dict per lcore (`lcore1`, `lcore2`) with `rx`, `tx`, `drop` (ch13).
6. **Shutdown and self-check.** After `quit`, wait until the pool is full
   again, stop the workers, and print for each lcore whether
   `rx == tx + drop`, `rx == N*H` and `drop == N`, then
   `check mempool in_use == 0`, then `RESULT: PASS` or `RESULT: FAIL`.
   Use `--file-prefix=ch13-b2`, `--no-pci --no-huge -m 128`.

## Acceptance check

```sh
source <path>/dpdk-env.sh
make                      # builds the solution as ./l2fwd_mc
./run.sh                  # BAND 2 PROJECT: PASS
# your own version:
cp my_version.c my_l2fwd_mc.c && make mine && BIN=./my_l2fwd_mc ./run.sh
```

`run.sh` feeds `show stats`, `show pool`, `quit` with delays, reads
`/band2/stats` over the telemetry socket about 1 s after start, and prints
`BAND 2 PROJECT: PASS` only if the program's `RESULT` is PASS, telemetry
shows both lcores with `rx > 0`, and at least one `[timer]` and one
`[shell]` line were printed.

## Files

* `solution/l2fwd_mc.c` - the reference solution
* `Makefile` - builds the solution (`make`) or yours (`make mine`)
* `run.sh` - the acceptance check; its real output is section 12 of
  `../expected_output.txt`
