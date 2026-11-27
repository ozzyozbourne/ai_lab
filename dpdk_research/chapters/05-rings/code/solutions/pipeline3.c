/* SPDX-License-Identifier: BSD-3-Clause
 *
 * solutions/pipeline3.c - Chapter 5, exercise 2 (medium).
 *
 * Three-stage pipeline:  lcore A --r1--> lcore B --r2--> lcore C
 *   A (main lcore) produces sequence numbers 1..N.
 *   B moves them from r1 to r2, adding 0 (a real stage would parse,
 *     classify, ...). It must cope with partial bursts on BOTH sides.
 *   C checks that every number arrives exactly once and in order.
 * Each ring has exactly one producer and one consumer, so both are
 * created SP/SC (the cheapest mode).
 *
 * Run: ./pipeline3 -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch05-pipe
 */
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_errno.h>
#include <rte_cycles.h>
#include <rte_pause.h>
#include <rte_ring.h>
#include <rte_debug.h>

#define N     (4u * 1000 * 1000)
#define BURST 32
#define U2P(u) ((void *)(uintptr_t)(u))
#define P2U(p) ((uint64_t)(uintptr_t)(p))

static struct rte_ring *r1, *r2;

static int
stage_b(void *arg __rte_unused)
{
	void *buf[BURST];
	uint64_t moved = 0;

	while (moved < N) {
		unsigned int n = rte_ring_dequeue_burst(r1, buf, BURST, NULL);
		unsigned int sent = 0;
		if (n == 0) {
			rte_pause();
			continue;
		}
		/* r2 may have less room than n: loop until all are sent,
		 * otherwise objects would be lost (or reordered). */
		while (sent < n)
			sent += rte_ring_enqueue_burst(r2, buf + sent, n - sent,
						       NULL);
		moved += n;
	}
	return 0;
}

static uint64_t c_got, c_bad;

static int
stage_c(void *arg __rte_unused)
{
	void *buf[BURST];
	uint64_t expect = 1;

	while (c_got < N) {
		unsigned int n = rte_ring_dequeue_burst(r2, buf, BURST, NULL);
		for (unsigned int i = 0; i < n; i++, expect++)
			if (P2U(buf[i]) != expect)
				c_bad++;
		c_got += n;
		if (n == 0)
			rte_pause();
	}
	return 0;
}

int
main(int argc, char **argv)
{
	void *buf[BURST];
	uint64_t next = 1;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");
	unsigned int lb = rte_get_next_lcore(-1, 1, 0);
	unsigned int lc = rte_get_next_lcore(lb, 1, 0);
	if (lc >= RTE_MAX_LCORE)
		rte_exit(EXIT_FAILURE, "need 3 lcores (-l 0-2)\n");

	r1 = rte_ring_create("r1", 512, rte_socket_id(), RING_F_SP_ENQ | RING_F_SC_DEQ);
	r2 = rte_ring_create("r2", 512, rte_socket_id(), RING_F_SP_ENQ | RING_F_SC_DEQ);
	if (r1 == NULL || r2 == NULL)
		rte_exit(EXIT_FAILURE, "ring create: %s\n", rte_strerror(rte_errno));

	rte_eal_remote_launch(stage_b, NULL, lb);
	rte_eal_remote_launch(stage_c, NULL, lc);
	uint64_t t0 = rte_rdtsc();
	while (next <= N) {
		unsigned int want = RTE_MIN((uint64_t)BURST, N - next + 1), i;
		for (i = 0; i < want; i++)
			buf[i] = U2P(next + i);
		next += rte_ring_enqueue_burst(r1, buf, want, NULL);
	}
	rte_eal_mp_wait_lcore();
	uint64_t cyc = rte_rdtsc() - t0;

	printf("pipeline A(lcore %u) -> r1 -> B(lcore %u) -> r2 -> C(lcore %u)\n",
	       rte_lcore_id(), lb, lc);
	printf("C received %" PRIu64 " of %u, out of order: %" PRIu64 " -> %s\n",
	       c_got, N, c_bad, (c_got == N && c_bad == 0) ? "PASS" : "FAIL");
	printf("%.1f cycles per object end to end\n", (double)cyc / N);
	rte_ring_free(r1);
	rte_ring_free(r2);
	rte_eal_cleanup();
	return 0;
}
