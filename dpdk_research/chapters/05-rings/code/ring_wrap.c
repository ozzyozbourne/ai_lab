/* SPDX-License-Identifier: BSD-3-Clause
 *
 * ring_wrap.c - Chapter 5, example 2: the head/tail indexes.
 *
 *  1. A ring with 8 slots. 1000 rounds of "enqueue 3, dequeue 3".
 *     The indexes are never reset: they reach 3000 although the ring has 8
 *     slots. The slot actually used is  index & mask.
 *  2. The 32-bit wrap: we place an EMPTY ring's indexes just below 2^32
 *     (this pokes into struct rte_ring - only a demo, never do it in real
 *     code) and enqueue 5. prod.head wraps to a small number, yet
 *     count = prod.tail - cons.head is still 5, thanks to unsigned
 *     modulo-2^32 arithmetic.
 *  3. Capacity: count 8 gives capacity 7. RING_F_EXACT_SZ gives exactly
 *     the capacity you asked for (and works for non-powers of two).
 *
 * Run:  ./ring_wrap -l 0 --no-pci --no-huge -m 64 --file-prefix=ch05-wrap
 */
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_ring.h>
#include <rte_debug.h>

#define U2P(u) ((void *)(uintptr_t)(u))
#define P2U(p) ((unsigned int)(uintptr_t)(p))

static void
indexes(const struct rte_ring *r, const char *what)
{
	/* The four indexes live in r->prod and r->cons. Reading them is
	 * harmless (a real program uses rte_ring_count() instead). */
	uint32_t ph = r->prod.head, pt = r->prod.tail;
	uint32_t ch = r->cons.head, ct = r->cons.tail;
	printf("  %-28s prod.head=%-10u prod.tail=%-10u cons.head=%-10u "
	       "cons.tail=%-10u\n", what, ph, pt, ch, ct);
	printf("  %-28s slots: prod %u, cons %u (index & mask %u);"
	       " prod.tail - cons.head = %u\n", "",
	       ph & r->mask, ch & r->mask, r->mask, pt - ch);
}

int
main(int argc, char **argv)
{
	void *in[8], *out[8];
	unsigned int i, round;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");

	for (i = 0; i < 8; i++)
		in[i] = U2P(i + 1);

	/* ---- 1. indexes run freely ---------------------------------- */
	printf("== 1. 1000 x (enqueue 3, dequeue 3) on an 8-slot ring ==\n");
	struct rte_ring *r = rte_ring_create("wrap8", 8, SOCKET_ID_ANY,
					     RING_F_SP_ENQ | RING_F_SC_DEQ);
	if (r == NULL)
		rte_exit(EXIT_FAILURE, "create: %s\n", rte_strerror(rte_errno));
	printf("  size=%u mask=0x%x capacity=%u\n", rte_ring_get_size(r),
	       r->mask, rte_ring_get_capacity(r));
	indexes(r, "fresh:");
	for (round = 0; round < 1000; round++) {
		if (rte_ring_enqueue_bulk(r, in, 3, NULL) != 3 ||
		    rte_ring_dequeue_bulk(r, out, 3, NULL) != 3)
			rte_exit(EXIT_FAILURE, "round %u failed\n", round);
		if (round < 3)
			printf("  round %u: slots used %u,%u,%u\n", round,
			       (round * 3) & r->mask, (round * 3 + 1) & r->mask,
			       (round * 3 + 2) & r->mask);
	}
	indexes(r, "after 1000 rounds:");
	rte_ring_enqueue_bulk(r, in, 2, NULL);
	indexes(r, "after enqueue 2 more:");
	printf("  rte_ring_dump():\n");
	rte_ring_dump(stdout, r);

	/* ---- 2. the 32-bit wrap ------------------------------------- */
	printf("\n== 2. crossing 2^32: indexes start at UINT32_MAX - 1 ==\n");
	rte_ring_reset(r);                    /* empty, all indexes 0 */
	uint32_t start = UINT32_MAX - 1;      /* 4294967294 */
	/* DEMO ONLY: move all four indexes of an empty ring together.
	 * Equal values mean "empty", so the ring stays consistent. */
	r->prod.head = r->prod.tail = start;
	r->cons.head = r->cons.tail = start;
	indexes(r, "before:");
	unsigned int n = rte_ring_enqueue_bulk(r, in, 5, NULL);
	printf("  enqueue_bulk(5) -> %u\n", n);
	indexes(r, "after enqueue 5:");
	printf("  rte_ring_count()=%u free=%u  (prod.tail < cons.head, but"
	       " %u - %u = %u modulo 2^32)\n", rte_ring_count(r),
	       rte_ring_free_count(r), r->prod.tail,
	       r->cons.head, (uint32_t)(r->prod.tail - r->cons.head));
	n = rte_ring_dequeue_bulk(r, out, 5, NULL);
	printf("  dequeue_bulk(5) -> %u, values:", n);
	for (i = 0; i < n; i++)
		printf(" %u", P2U(out[i]));
	printf("  (FIFO order kept across the wrap)\n");
	indexes(r, "after dequeue 5:");
	rte_ring_free(r);

	/* ---- 3. capacity and RING_F_EXACT_SZ ------------------------- */
	printf("\n== 3. capacity: count vs RING_F_EXACT_SZ ==\n");
	struct {
		const char *name;
		unsigned int count;
		unsigned int flags;
	} t[] = {
		{ "c8",       8,    0 },
		{ "c8x",      8,    RING_F_EXACT_SZ },
		{ "c1000",    1000, 0 },
		{ "c1000x",   1000, RING_F_EXACT_SZ },
		{ "c1024",    1024, 0 },
		{ "c1024x",   1024, RING_F_EXACT_SZ },
	};
	printf("  %-8s %6s %-16s %6s %8s %10s\n", "name", "count", "flags",
	       "size", "capacity", "memsize");
	for (i = 0; i < RTE_DIM(t); i++) {
		struct rte_ring *x = rte_ring_create(t[i].name, t[i].count,
						     SOCKET_ID_ANY, t[i].flags);
		if (x == NULL) {
			printf("  %-8s %6u %-16s  -> NULL, rte_errno=%d (%s)\n",
			       t[i].name, t[i].count,
			       t[i].flags ? "RING_F_EXACT_SZ" : "0",
			       rte_errno, rte_strerror(rte_errno));
			continue;
		}
		printf("  %-8s %6u %-16s %6u %8u %10zd\n", t[i].name,
		       t[i].count, t[i].flags ? "RING_F_EXACT_SZ" : "0",
		       rte_ring_get_size(x), rte_ring_get_capacity(x),
		       rte_ring_get_memsize(rte_ring_get_size(x)));
		rte_ring_free(x);
	}
	printf("  sizeof(struct rte_ring)=%zu (header; the slot table follows it)\n",
	       sizeof(struct rte_ring));

	rte_eal_cleanup();
	return 0;
}
