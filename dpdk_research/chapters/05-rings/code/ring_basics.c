/* SPDX-License-Identifier: BSD-3-Clause
 *
 * ring_basics.c - Chapter 5, example 1.
 *
 * Part A (one thread): create a ring, look at its size and capacity, and
 *   see the three API families side by side on a nearly full ring:
 *     - single object : rte_ring_enqueue()        0 or -ENOBUFS / -ENOENT
 *     - bulk          : rte_ring_enqueue_bulk()   all n or nothing (returns n or 0)
 *     - burst         : rte_ring_enqueue_burst()  as many as fit (0..n)
 *   Also: errors from rte_ring_create() and rte_ring_lookup() by name.
 *
 * Part B (two lcores): the main lcore produces the integers 1..N (cast to
 *   void *) in bursts of 32, a worker lcore consumes them, checks that they
 *   arrive in order and sums them.
 *
 * Run:  ./ring_basics -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch05-basic
 *
 * Exercise 1 asks you to rebuild Part B with RING_F_SP_ENQ | RING_F_SC_DEQ.
 * You can do that without editing: make ring_basics_spsc (see the Makefile),
 * which compiles this file with -DPIPE_FLAGS="RING_F_SP_ENQ|RING_F_SC_DEQ".
 */
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <errno.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_errno.h>
#include <rte_cycles.h>
#include <rte_ring.h>
#include <rte_debug.h>

#ifndef PIPE_FLAGS
#define PIPE_FLAGS 0          /* 0 = default MP/MC ring */
#endif
#define STR2(x) #x
#define STR(x) STR2(x)

#define N_OBJS  (8u * 1000 * 1000)   /* objects sent in Part B */
#define BURST   32

/* Turn a small integer into a "pointer" and back. A pointer ring only
 * stores void * values; it never dereferences them, so any value works. */
#define U2P(u) ((void *)(uintptr_t)(u))
#define P2U(p) ((uint64_t)(uintptr_t)(p))

static void
show(const struct rte_ring *r, const char *what)
{
	printf("  %-34s count=%-3u free=%-3u full=%d empty=%d\n", what,
	       rte_ring_count(r), rte_ring_free_count(r),
	       rte_ring_full(r), rte_ring_empty(r));
}

/* ------------------------------------------------------------------ */
/* Part A: one thread, one small ring                                  */
/* ------------------------------------------------------------------ */
static void
part_a(void)
{
	void *objs[32] = { NULL }, *out[32];
	unsigned int i, n, free_space, avail;
	void *one;
	int ret;

	for (i = 0; i < 32; i++)
		objs[i] = U2P(100 + i);

	printf("== Part A: one ring of 16 slots, used by one thread ==\n");

	/* count must be a power of two; the flags pick the default sync
	 * mode (0 = multi-producer / multi-consumer). SOCKET_ID_ANY lets
	 * EAL pick the NUMA node. */
	struct rte_ring *r = rte_ring_create("demo", 16, SOCKET_ID_ANY, 0);
	if (r == NULL)
		rte_exit(EXIT_FAILURE, "rte_ring_create: %s\n",
			 rte_strerror(rte_errno));
	printf("  size=%u capacity=%u (one slot is kept empty)\n",
	       rte_ring_get_size(r), rte_ring_get_capacity(r));

	/* Same name again: names are unique (the ring lives in a memzone
	 * called "RG_demo"). */
	struct rte_ring *dup = rte_ring_create("demo", 16, SOCKET_ID_ANY, 0);
	printf("  create(\"demo\") again   -> %s, rte_errno=%d (%s)\n",
	       dup ? "ring" : "NULL", rte_errno, rte_strerror(rte_errno));
	struct rte_ring *bad = rte_ring_create("bad", 10, SOCKET_ID_ANY, 0);
	printf("  create(count=10)       -> %s, rte_errno=%d (%s)\n",
	       bad ? "ring" : "NULL", rte_errno, rte_strerror(rte_errno));
	printf("  rte_ring_lookup(\"demo\") -> %s\n",
	       rte_ring_lookup("demo") == r ? "same pointer" : "different!");

	show(r, "fresh ring:");

	/* Fill 13 of the 15 usable slots, then ask for 4 more. */
	n = rte_ring_enqueue_bulk(r, objs, 13, &free_space);
	printf("  enqueue_bulk(13)  -> %2u  free_space=%u\n", n, free_space);
	show(r, "after 13:");

	n = rte_ring_enqueue_bulk(r, objs + 13, 4, &free_space);
	printf("  enqueue_bulk(4)   -> %2u  (all or nothing: 4 > %u free)\n",
	       n, free_space);
	n = rte_ring_enqueue_burst(r, objs + 13, 4, &free_space);
	printf("  enqueue_burst(4)  -> %2u  (as many as fit) free_space=%u\n",
	       n, free_space);
	show(r, "ring is now full:");

	ret = rte_ring_enqueue(r, objs[20]);
	printf("  enqueue(1 obj)    -> %d (-ENOBUFS = %d)\n", ret, -ENOBUFS);

	/* Dequeue side mirrors it. */
	n = rte_ring_dequeue_bulk(r, out, 20, &avail);
	printf("  dequeue_bulk(20)  -> %2u  available=%u\n", n, avail);
	n = rte_ring_dequeue_burst(r, out, 20, &avail);
	printf("  dequeue_burst(20) -> %2u  available=%u  first=%" PRIu64
	       " last=%" PRIu64 "\n", n, avail, P2U(out[0]), P2U(out[n - 1]));
	ret = rte_ring_dequeue(r, &one);
	printf("  dequeue(1 obj)    -> %d (-ENOENT = %d)\n", ret, -ENOENT);
	show(r, "empty again:");

	printf("  rte_ring_dump():\n");
	rte_ring_dump(stdout, r);
	rte_ring_free(r);
	printf("  after rte_ring_free, lookup(\"demo\") -> %s\n\n",
	       rte_ring_lookup("demo") ? "found" : "NULL");
}

/* ------------------------------------------------------------------ */
/* Part B: producer on the main lcore, consumer on a worker lcore      */
/* ------------------------------------------------------------------ */
struct cons_result {
	uint64_t sum;
	uint64_t received;
	uint64_t out_of_order;
	uint64_t empty_polls;   /* dequeue_burst returned 0 */
};

static struct rte_ring *pipe_ring;
static struct cons_result cres;

static int
consumer(void *arg __rte_unused)
{
	void *burst[BURST];
	uint64_t expect = 1;

	while (cres.received < N_OBJS) {
		/* Burst: take whatever is there, up to BURST. */
		unsigned int n = rte_ring_dequeue_burst(pipe_ring, burst,
							BURST, NULL);
		if (n == 0) {
			cres.empty_polls++;
			rte_pause();
			continue;
		}
		for (unsigned int i = 0; i < n; i++) {
			uint64_t v = P2U(burst[i]);
			if (v != expect)
				cres.out_of_order++;
			expect = v + 1;
			cres.sum += v;
		}
		cres.received += n;
	}
	return 0;
}

static void
part_b(void)
{
	void *burst[BURST];
	uint64_t next = 1, full_polls = 0;
	unsigned int worker = rte_get_next_lcore(-1, 1, 0);

	if (worker >= RTE_MAX_LCORE)
		rte_exit(EXIT_FAILURE, "Part B needs 2 lcores (-l 0-1)\n");

	printf("== Part B: lcore %u -> ring -> lcore %u, %u objects, flags=%s ==\n",
	       rte_lcore_id(), worker, N_OBJS, STR(PIPE_FLAGS));
	pipe_ring = rte_ring_create("pipe", 1024, rte_socket_id(), PIPE_FLAGS);
	if (pipe_ring == NULL)
		rte_exit(EXIT_FAILURE, "create pipe: %s\n",
			 rte_strerror(rte_errno));
	printf("  prod sync type=%d cons sync type=%d (0=MT 1=ST 2=RTS 3=HTS)\n",
	       rte_ring_get_prod_sync_type(pipe_ring),
	       rte_ring_get_cons_sync_type(pipe_ring));

	rte_eal_remote_launch(consumer, NULL, worker);

	uint64_t t0 = rte_rdtsc();
	while (next <= N_OBJS) {
		unsigned int want = BURST, i;
		if (N_OBJS - next + 1 < want)
			want = N_OBJS - next + 1;
		for (i = 0; i < want; i++)
			burst[i] = U2P(next + i);
		/* Burst enqueue may take only part; resend the rest. */
		unsigned int done = rte_ring_enqueue_burst(pipe_ring, burst,
							   want, NULL);
		if (done == 0)
			full_polls++;
		next += done;
	}
	rte_eal_wait_lcore(worker);
	uint64_t cyc = rte_rdtsc() - t0;

	uint64_t expect_sum = (uint64_t)N_OBJS * (N_OBJS + 1) / 2;
	printf("  received=%" PRIu64 " out_of_order=%" PRIu64 " sum %s\n",
	       cres.received, cres.out_of_order,
	       cres.sum == expect_sum ? "OK" : "WRONG");
	printf("  producer saw a full ring %" PRIu64 " times, consumer saw an"
	       " empty ring %" PRIu64 " times\n", full_polls, cres.empty_polls);
	printf("  %.1f cycles per object, %.1f Mobj/s (TSC %" PRIu64 " MHz)\n",
	       (double)cyc / N_OBJS,
	       N_OBJS / ((double)cyc / rte_get_tsc_hz()) / 1e6,
	       rte_get_tsc_hz() / 1000000);
	rte_ring_free(pipe_ring);
}

int
main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");

	part_a();
	part_b();

	rte_eal_cleanup();
	return 0;
}
