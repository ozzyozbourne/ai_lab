/* SPDX-License-Identifier: BSD-3-Clause
 *
 * elem_peek.c - Chapter 5, example 4: element rings, peek and zero-copy.
 *
 *  1. An HTS element ring whose slots hold an 8-byte struct by value
 *     (no pointers, no mempool): rte_ring_create_elem(name, esize, ...).
 *  2. Peek: rte_ring_dequeue_bulk_elem_start() shows the head element
 *     without removing it; rte_ring_dequeue_elem_finish(r, 0) puts it back,
 *     finish(r, 1) takes it.
 *  3. Zero-copy enqueue: rte_ring_enqueue_zc_burst_elem_start() returns
 *     pointers INTO the ring's slot table. When the reservation crosses the
 *     end of the table it comes in two parts: n1 slots at ptr1 and n - n1
 *     slots at ptr2 (the start of the table).
 *  4. Two consumers (main lcore = flow 0, worker lcore = flow 1) share one
 *     HTS ring. Each peeks at the head element and takes it only if it
 *     belongs to its own flow. HTS makes start..finish exclusive, so two
 *     threads can safely peek at the same ring.
 *
 * Run:  ./elem_peek -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch05-peek
 */
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_errno.h>
#include <rte_pause.h>
#include <rte_ring.h>
#include <rte_ring_elem.h>
#include <rte_ring_peek.h>      /* *_start / *_finish */
#include <rte_ring_peek_zc.h>   /* zero-copy: struct rte_ring_zc_data */
#include <rte_debug.h>

/* The element: copied by value into the ring. Its size must be a multiple
 * of 4 bytes; 8 and 16 bytes take the fastest copy paths. */
struct item {
	uint32_t flow;
	uint32_t len;
};
#define ESZ sizeof(struct item)
#define N_ITEMS 2000

static struct rte_ring *ring;

struct taker {
	uint32_t flow;
	uint64_t taken, bytes, put_back;
	uint32_t first_seq;  /* len of first item taken: shows FIFO order */
	int ordered;
};

/* Consumer that peeks: take the head element only if it is ours. */
static int
peek_consumer(void *arg)
{
	struct taker *t = arg;
	struct item it;
	uint32_t last = 0;

	t->ordered = 1;
	while (t->taken < N_ITEMS / 2) {
		/* start: copies the head element into 'it', reserves it.
		 * Until finish, no other consumer can dequeue from 'ring'. */
		if (rte_ring_dequeue_bulk_elem_start(ring, &it, ESZ, 1, NULL) == 0) {
			rte_pause();          /* ring empty */
			continue;
		}
		if (it.flow == t->flow) {
			rte_ring_dequeue_elem_finish(ring, 1);   /* take it */
			if (t->taken == 0)
				t->first_seq = it.len;
			else if (it.len <= last)
				t->ordered = 0;
			last = it.len;
			t->taken++;
			t->bytes += it.len;
		} else {
			rte_ring_dequeue_elem_finish(ring, 0);   /* leave it */
			t->put_back++;
			rte_pause();
		}
	}
	return 0;
}

static void
print_zc(const struct rte_ring *r, const struct rte_ring_zc_data *z,
	 unsigned int n)
{
	const uint8_t *table = (const uint8_t *)&r[1];   /* slots follow header */
	printf("  zc start: n=%u  ptr1 -> slot %td, n1=%u", n,
	       ((const uint8_t *)z->ptr1 - table) / (ptrdiff_t)ESZ, z->n1);
	if (z->ptr2 != NULL)
		printf("  ptr2 -> slot %td, n2=%u\n",
		       ((const uint8_t *)z->ptr2 - table) / (ptrdiff_t)ESZ,
		       n - z->n1);
	else
		printf("  ptr2=NULL (no wrap)\n");
}

int
main(int argc, char **argv)
{
	struct item buf[16], it;
	unsigned int i, n;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");

	/* ---- 1. HTS element ring ------------------------------------ */
	printf("== 1. element ring: esize=%zu, 16 slots, HTS on both sides ==\n", ESZ);
	ring = rte_ring_create_elem("items", ESZ, 16, SOCKET_ID_ANY,
				    RING_F_MP_HTS_ENQ | RING_F_MC_HTS_DEQ);
	if (ring == NULL)
		rte_exit(EXIT_FAILURE, "create_elem: %s\n", rte_strerror(rte_errno));
	printf("  capacity=%u prod sync=%d cons sync=%d (3 = RTE_RING_SYNC_MT_HTS)\n",
	       rte_ring_get_capacity(ring), rte_ring_get_prod_sync_type(ring),
	       rte_ring_get_cons_sync_type(ring));
	struct rte_ring *bad = rte_ring_create_elem("bad", 6, 16, SOCKET_ID_ANY, 0);
	printf("  create_elem(esize=6) -> %s, rte_errno=%d (%s)\n",
	       bad ? "ring" : "NULL", rte_errno, rte_strerror(rte_errno));

	for (i = 0; i < 4; i++)
		buf[i] = (struct item){ .flow = i % 2, .len = 100 + i };
	n = rte_ring_enqueue_bulk_elem(ring, buf, ESZ, 4, NULL);
	printf("  enqueue_bulk_elem(4 items by value) -> %u, count=%u\n",
	       n, rte_ring_count(ring));

	/* ---- 2. peek ------------------------------------------------ */
	printf("\n== 2. peek: look at the head, put it back, then take it ==\n");
	n = rte_ring_dequeue_bulk_elem_start(ring, &it, ESZ, 1, NULL);
	printf("  start  -> %u: head is {flow=%u len=%u}\n", n, it.flow, it.len);
	rte_ring_dequeue_elem_finish(ring, 0);
	printf("  finish(0): left in place, count=%u\n", rte_ring_count(ring));
	n = rte_ring_dequeue_bulk_elem_start(ring, &it, ESZ, 1, NULL);
	printf("  start  -> %u: head is {flow=%u len=%u} (the same one)\n",
	       n, it.flow, it.len);
	rte_ring_dequeue_elem_finish(ring, 1);
	printf("  finish(1): removed, count=%u\n", rte_ring_count(ring));
	n = rte_ring_dequeue_bulk_elem(ring, buf, ESZ, 3, NULL);
	printf("  drain the other %u\n", n);

	/* ---- 3. zero-copy enqueue across the end of the table -------- */
	printf("\n== 3. zero-copy enqueue that wraps the end of the table ==\n");
	/* 4 items went in and out, so the indexes are at 4. Move them to
	 * 12 with 8 more in/out, so 8 new slots must span 12..15 and 0..3. */
	for (i = 0; i < 8; i++)
		buf[i] = (struct item){ .flow = 9, .len = i };
	rte_ring_enqueue_bulk_elem(ring, buf, ESZ, 8, NULL);
	rte_ring_dequeue_bulk_elem(ring, buf, ESZ, 8, NULL);
	printf("  prod.head=%u  (slot %u)\n", ring->hts_prod.ht.pos.head,
	       ring->hts_prod.ht.pos.head & ring->mask);

	struct rte_ring_zc_data zcd = { 0 };   /* untouched if start returns 0 */
	n = rte_ring_enqueue_zc_burst_elem_start(ring, ESZ, 8, &zcd, NULL);
	print_zc(ring, &zcd, n);
	/* Write straight into the ring's memory: no staging array.
	 * (In a real app rte_eth_rx_burst() could fill ptr1/ptr2.) */
	struct item *p1 = zcd.ptr1, *p2 = zcd.ptr2;
	for (i = 0; i < zcd.n1; i++)
		p1[i] = (struct item){ .flow = 7, .len = 1000 + i };
	for (i = 0; i < n - zcd.n1; i++)
		p2[i] = (struct item){ .flow = 7, .len = 1000 + zcd.n1 + i };
	rte_ring_enqueue_zc_elem_finish(ring, n);
	n = rte_ring_dequeue_burst_elem(ring, buf, ESZ, 16, NULL);
	printf("  dequeued %u:", n);
	for (i = 0; i < n; i++)
		printf(" %u", buf[i].len);
	printf("  (in order across the wrap)\n");
	rte_ring_free(ring);

	/* ---- 4. two consumers, each takes only its own flow ---------- */
	unsigned int worker = rte_get_next_lcore(-1, 1, 0);
	if (worker >= RTE_MAX_LCORE)
		rte_exit(EXIT_FAILURE, "part 4 needs 2 lcores (-l 0-1)\n");
	printf("\n== 4. two peeking consumers on one HTS ring (lcore %u: flow 0,"
	       " lcore %u: flow 1) ==\n", rte_lcore_id(), worker);
	ring = rte_ring_create_elem("flows", ESZ, 4096, SOCKET_ID_ANY,
				    RING_F_SP_ENQ | RING_F_MC_HTS_DEQ);
	if (ring == NULL)
		rte_exit(EXIT_FAILURE, "create_elem: %s\n", rte_strerror(rte_errno));
	/* Items alternate in runs: 0,0,0,1,1,0,1,... The len field holds the
	 * sequence number so each consumer can check its order. */
	uint32_t seed = 12345;
	for (i = 0; i < N_ITEMS; i++) {
		seed = seed * 1103515245u + 12345u;     /* tiny LCG */
		it.flow = (i < N_ITEMS / 2) ? ((seed >> 16) & 1) : 0;
		it.len = i + 1;
		buf[0] = it;
		rte_ring_enqueue_elem(ring, &buf[0], ESZ);
	}
	/* Make it exactly N/2 per flow: count and fix up the tail. */
	{
		struct item all[N_ITEMS];
		unsigned int c1 = 0;
		n = rte_ring_dequeue_bulk_elem(ring, all, ESZ, N_ITEMS, NULL);
		for (i = 0; i < n; i++)
			c1 += all[i].flow;
		for (i = n; i-- > 0 && c1 < N_ITEMS / 2; )
			if (all[i].flow == 0) { all[i].flow = 1; c1++; }
		rte_ring_enqueue_bulk_elem(ring, all, ESZ, n, NULL);
		printf("  enqueued %u items, %u for flow 0 and %u for flow 1\n",
		       n, n - c1, c1);
	}

	static struct taker t0 = { .flow = 0 }, t1 = { .flow = 1 };
	rte_eal_remote_launch(peek_consumer, &t1, worker);
	peek_consumer(&t0);
	rte_eal_wait_lcore(worker);
	printf("  flow 0: taken=%" PRIu64 " in order=%s, put back %" PRIu64
	       " foreign heads\n", t0.taken, t0.ordered ? "yes" : "NO",
	       t0.put_back);
	printf("  flow 1: taken=%" PRIu64 " in order=%s, put back %" PRIu64
	       " foreign heads\n", t1.taken, t1.ordered ? "yes" : "NO",
	       t1.put_back);
	printf("  ring count at the end: %u\n", rte_ring_count(ring));
	rte_ring_free(ring);

	rte_eal_cleanup();
	return 0;
}
