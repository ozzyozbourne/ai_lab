/* SPDX-License-Identifier: BSD-3-Clause
 *
 * distributor_reorder.c - Chapter 15: rte_distributor + rte_reorder.
 *
 * Part 1  the reorder buffer on its own: a scripted insert sequence with
 *         early and late packets, then drain (same as the page's widget).
 * Part 2  a distributor on the main lcore hands tagged packets to N workers.
 *         Workers check the distributor's promise (no two packets of one tag
 *         are processed at the same time on two workers), take a random
 *         amount of time per packet (so packets come back out of order),
 *         and return them. The main lcore restores the order with
 *         rte_reorder and checks that the drained sequence is monotonic.
 * --bench the same distributor on a net_null port with fixed work per packet,
 *         printing a RESULT line for compare.sh.
 *
 * Run:  ./distributor_reorder -l 0-2 --no-pci --no-huge -m 128 --file-prefix=ch15-dist
 *       ./distributor_reorder -l 0-2 --no-pci --no-huge -m 256 --file-prefix=ch15-distb \
 *            --vdev=net_null0,size=64 -- --bench --work 200 --seconds 2
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <rte_errno.h>
#include <rte_random.h>
#include <rte_stdatomic.h>
#include <rte_distributor.h>
#include <rte_reorder.h>

#include "ch15_common.h"

#define NB_FLOWS   64
#define DUMMY_SEQN UINT32_MAX	/* marks wake-up packets used at shutdown */
#define MAX_W      8

static struct rte_distributor *dist;
static unsigned int nb_workers;
static uint64_t work_cycles = 300;
static int bench;
static unsigned int seconds = 2;
static RTE_ATOMIC(int) quit;
static RTE_ATOMIC(int) alive;
/* who is processing flow f right now (0 = nobody, else worker id + 1) */
static RTE_ATOMIC(uint32_t) owner[NB_FLOWS];

struct __rte_cache_aligned wstats {
	uint64_t pkts, conflicts;
	uint64_t per_flow[NB_FLOWS];
};
static struct wstats ws[MAX_W];

/* ------------------------------------------------------------------ */
/* Part 1: scripted reorder buffer                                     */
/* ------------------------------------------------------------------ */
static struct rte_mbuf *
mk(struct rte_mempool *mp, uint32_t seq)
{
	struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
	if (m)
		*rte_reorder_seqn(m) = seq;
	return m;
}

static void
try_insert(struct rte_reorder_buffer *b, struct rte_mbuf *m)
{
	uint32_t seq = *rte_reorder_seqn(m);

	if (rte_reorder_insert(b, m) == 0) {
		printf(" %u:ok", seq);
		return;
	}
	/* insert failed: the caller still owns the mbuf */
	printf(" %u:%s", seq, rte_errno == ERANGE ? "ERANGE" :
	       rte_errno == ENOSPC ? "ENOSPC" : "error");
	rte_pktmbuf_free(m);
}

static void
drain_print(struct rte_reorder_buffer *b)
{
	struct rte_mbuf *out[32];
	unsigned int n = rte_reorder_drain(b, out, 32), i;

	printf("\n  drain -> %u packets:", n);
	for (i = 0; i < n; i++) {
		printf(" %u", *rte_reorder_seqn(out[i]));
		rte_pktmbuf_free(out[i]);
	}
	printf("\n");
}

static void
part1(struct rte_mempool *mp)
{
	static const uint32_t script[] = { 1, 0, 3, 2, 5, 4, 20, 6 };
	struct rte_reorder_buffer *b;
	unsigned int i;

	printf("== Part 1: rte_reorder, window size 8 ==\n");
	/* The FIRST packet inserted sets min_seqn unless we set it. Arriving
	 * 1 before 0 would make 0 "late" forever. */
	b = rte_reorder_create("ch15_naive", rte_socket_id(), 8);
	printf("  without min_seqn_set, insert:");
	try_insert(b, mk(mp, 1));
	try_insert(b, mk(mp, 0));
	drain_print(b);
	rte_reorder_free(b);

	b = rte_reorder_create("ch15_rob", rte_socket_id(), 8);
	rte_reorder_min_seqn_set(b, 0);	/* we know the stream starts at 0 */
	printf("  min_seqn_set(0), insert:");
	for (i = 0; i < RTE_DIM(script); i++)
		try_insert(b, mk(mp, script[i]));
	drain_print(b);
	/* 7 is missing: the drain stopped at the gap. 12 still fits the
	 * window [7, 15).  16 is "early" (window..2*window ahead): to make
	 * room, insert slides the window and SKIPS the empty slots 7 and 8.
	 * Then 7 arrives too late (ERANGE) and the drain stops at gap 9. */
	printf("  insert:");
	try_insert(b, mk(mp, 12));
	try_insert(b, mk(mp, 16));
	try_insert(b, mk(mp, 7));
	drain_print(b);
	printf("  insert:");
	try_insert(b, mk(mp, 9));
	try_insert(b, mk(mp, 10));
	try_insert(b, mk(mp, 11));
	drain_print(b);
	printf("  insert:");
	try_insert(b, mk(mp, 13));
	try_insert(b, mk(mp, 14));
	try_insert(b, mk(mp, 15));
	drain_print(b);
	rte_reorder_free(b);
}

/* ------------------------------------------------------------------ */
/* Part 2: distributor workers                                         */
/* ------------------------------------------------------------------ */
static int
worker(void *arg)
{
	unsigned int id = (uintptr_t)arg;
	struct wstats *st = &ws[id];
	struct rte_mbuf *buf[8];
	int num = 0, i;

	rte_atomic_fetch_add_explicit(&alive, 1, rte_memory_order_relaxed);
	for (;;) {
		/* give back the previous burst, get a new one (blocks) */
		num = rte_distributor_get_pkt(dist, id, buf, buf, num);
		if (rte_atomic_load_explicit(&quit, rte_memory_order_acquire))
			break;
		for (i = 0; i < num; i++) {
			uint32_t flow = buf[i]->hash.usr % NB_FLOWS, expect = 0;

			if (!bench) {
				/* claim the flow; failing means another worker
				 * holds a packet of the same tag right now */
				if (!rte_atomic_compare_exchange_strong_explicit(&owner[flow],
						&expect, id + 1, rte_memory_order_acquire,
						rte_memory_order_relaxed))
					st->conflicts++;
				ch15_work(buf[i], work_cycles / 2 + rte_rand() % work_cycles);
				rte_atomic_store_explicit(&owner[flow], 0, rte_memory_order_release);
			} else {
				ch15_work(buf[i], work_cycles);
			}
			st->per_flow[flow]++;
		}
		st->pkts += num;
	}
	/* hand back what we hold, then leave */
	rte_distributor_return_pkt(dist, id, buf, num);
	rte_atomic_fetch_sub_explicit(&alive, 1, rte_memory_order_relaxed);
	return 0;
}

/* Workers block inside get_pkt until they are handed something. Send
 * dummy packets with distinct tags until every worker has seen quit. */
static void
stop_workers(struct rte_mempool *mp)
{
	struct rte_mbuf *ret[64];
	uint32_t tag = 0;
	int n, i;

	rte_atomic_store_explicit(&quit, 1, rte_memory_order_release);
	while (rte_atomic_load_explicit(&alive, rte_memory_order_relaxed) > 0) {
		struct rte_mbuf *d = rte_pktmbuf_alloc(mp);
		if (d != NULL) {
			*rte_reorder_seqn(d) = DUMMY_SEQN;
			d->hash.usr = 0x1000 + tag++;
			rte_distributor_process(dist, &d, 1);
		} else {
			rte_distributor_process(dist, NULL, 0);
		}
		while ((n = rte_distributor_returned_pkts(dist, ret, 64)) > 0)
			for (i = 0; i < n; i++)
				rte_pktmbuf_free(ret[i]);
	}
	rte_eal_mp_wait_lcore();
	rte_distributor_flush(dist);
	while ((n = rte_distributor_returned_pkts(dist, ret, 64)) > 0)
		for (i = 0; i < n; i++)
			rte_pktmbuf_free(ret[i]);
	rte_distributor_clear_returns(dist);
}

static void
part2(struct rte_mempool *mp)
{
	const uint32_t total = 200000;
	struct rte_reorder_buffer *rob;
	uint32_t next_seq = 0, last_ret = 0, last_out = 0, returned = 0, out = 0;
	uint64_t ooo_before = 0, ooo_after = 0, migrated = 0;
	unsigned int lcore, i, w;
	uint64_t t0, t1;

	printf("\n== Part 2: distributor -> %u workers -> rte_reorder (%u packets, %u flows) ==\n",
	       nb_workers, total, NB_FLOWS);
	rob = rte_reorder_create("ch15_rob2", rte_socket_id(), 8192);
	rte_reorder_min_seqn_set(rob, 0);

	t0 = rte_rdtsc();
	while (out < total) {
		struct rte_mbuf *burst[32], *ret[64], *drained[64];
		int n = 0, r, k;

		/* 1. new packets: tag = flow id, seqn = arrival order */
		while (n < 32 && next_seq < total) {
			struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
			if (m == NULL)
				break;	/* pool empty: everything is in flight */
			m->hash.usr = next_seq % NB_FLOWS;
			*rte_reorder_seqn(m) = next_seq++;
			burst[n++] = m;
		}
		rte_distributor_process(dist, burst, n);

		/* 2. finished packets come back in completion order */
		r = rte_distributor_returned_pkts(dist, ret, 64);
		for (k = 0; k < r; k++) {
			uint32_t s = *rte_reorder_seqn(ret[k]);
			if (returned && s < last_ret)
				ooo_before++;
			last_ret = s;
			returned++;
			if (rte_reorder_insert(rob, ret[k]) != 0) {
				printf("  insert %u failed: %s\n", s, rte_strerror(rte_errno));
				rte_pktmbuf_free(ret[k]);
				out++;
			}
		}
		/* 3. drain whatever is now in order */
		r = rte_reorder_drain(rob, drained, 64);
		for (k = 0; k < r; k++) {
			uint32_t s = *rte_reorder_seqn(drained[k]);
			if (out && s != last_out + 1)
				ooo_after++;
			last_out = s;
			out++;
			rte_pktmbuf_free(drained[k]);
		}
	}
	t1 = rte_rdtsc();
	stop_workers(mp);

	printf("  returned out of order (before reorder): %" PRIu64 " of %u\n", ooo_before, returned);
	printf("  drained out of order  (after reorder) : %" PRIu64 " of %u\n", ooo_after, out);
	for (w = 0; w < nb_workers; w++) {
		unsigned int flows = 0;
		for (i = 0; i < NB_FLOWS; i++)
			flows += ws[w].per_flow[i] != 0;
		printf("  worker %u: %" PRIu64 " packets, %u distinct flows, tag conflicts %" PRIu64 "\n",
		       w, ws[w].pkts, flows, ws[w].conflicts);
	}
	for (i = 0; i < NB_FLOWS; i++) {
		unsigned int on = 0;
		for (w = 0; w < nb_workers; w++)
			on += ws[w].per_flow[i] != 0;
		migrated += on > 1;
	}
	printf("  flows that ran on more than one worker over the run: %" PRIu64 " of %u\n",
	       migrated, NB_FLOWS);
	printf("  (affinity holds only while a tag is in flight; idle flows may move)\n");
	printf("  %.2f Mpps through distributor + reorder\n",
	       total / ((double)(t1 - t0) / rte_get_tsc_hz()) / 1e6);
	(void)lcore;
	rte_reorder_free(rob);
}

/* ------------------------------------------------------------------ */
/* --bench: RX from net_null, distribute, TX the returns               */
/* ------------------------------------------------------------------ */
static void
bench_loop(struct rte_mempool *mp)
{
	uint64_t end = rte_rdtsc() + seconds * rte_get_tsc_hz(), txd = 0, tag = 0;
	struct rte_mbuf *pkts[32], *ret[64];
	int i;

	while (rte_rdtsc() < end) {
		uint16_t n = rte_eth_rx_burst(0, 0, pkts, 32), sent;
		int r;

		for (i = 0; i < n; i++)
			pkts[i]->hash.usr = tag++ % NB_FLOWS;	/* stand-in for an RSS hash */
		rte_distributor_process(dist, pkts, n);
		r = rte_distributor_returned_pkts(dist, ret, 64);
		sent = rte_eth_tx_burst(0, 0, ret, r);
		txd += sent;
		if (sent < r)
			rte_pktmbuf_free_bulk(ret + sent, r - sent);
	}
	stop_workers(mp);
	printf("RESULT model=distributor work=%" PRIu64 " mpps=%.3f\n", work_cycles,
	       txd / (seconds * 1e6));
}

int
main(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "bench", no_argument, NULL, 'b' },
		{ "work", required_argument, NULL, 'w' },
		{ "seconds", required_argument, NULL, 's' },
		{ NULL, 0, NULL, 0 },
	};
	struct rte_mempool *mp;
	unsigned int lcore, id = 0;
	int ret, c;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		switch (c) {
		case 'b': bench = 1; break;
		case 'w': work_cycles = strtoull(optarg, NULL, 0); break;
		case 's': seconds = atoi(optarg); break;
		default: rte_exit(EXIT_FAILURE, "bad option\n");
		}
	}
	nb_workers = rte_lcore_count() - 1;
	if (nb_workers < 1 || nb_workers > MAX_W)
		rte_exit(EXIT_FAILURE, "need 2..%d lcores\n", MAX_W + 1);
	if (work_cycles == 0)
		work_cycles = 1;

	mp = rte_pktmbuf_pool_create("ch15_dist_pool", 16383, 256, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	/* rte_reorder_create() registers the seqn dynfield; part 2 and the
	 * dummies need it, so make sure it exists before anything else. */
	rte_reorder_free(rte_reorder_create("ch15_init", rte_socket_id(), 8));
	printf("reorder seqn dynfield at mbuf offset %d\n", rte_reorder_seqn_dynfield_offset);

	dist = rte_distributor_create("ch15_dist", rte_socket_id(), nb_workers,
				      RTE_DIST_ALG_BURST);
	if (dist == NULL)
		rte_exit(EXIT_FAILURE, "distributor: %s\n", rte_strerror(rte_errno));

	if (bench) {
		struct rte_eth_conf conf;
		memset(&conf, 0, sizeof(conf));
		if (rte_eth_dev_count_avail() < 1 ||
		    rte_eth_dev_configure(0, 1, 1, &conf) != 0 ||
		    rte_eth_rx_queue_setup(0, 0, 1024, rte_socket_id(), NULL, mp) != 0 ||
		    rte_eth_tx_queue_setup(0, 0, 1024, rte_socket_id(), NULL) != 0 ||
		    rte_eth_dev_start(0) != 0)
			rte_exit(EXIT_FAILURE, "--bench needs --vdev=net_null0,size=64\n");
	} else {
		part1(mp);
	}

	RTE_LCORE_FOREACH_WORKER(lcore)
		rte_eal_remote_launch(worker, (void *)(uintptr_t)id++, lcore);
	/* stop_workers() counts live workers: wait until all are running */
	while (rte_atomic_load_explicit(&alive, rte_memory_order_relaxed) < (int)nb_workers)
		rte_pause();

	if (bench)
		bench_loop(mp);
	else
		part2(mp);

	if (bench) {
		rte_eth_dev_stop(0);
		rte_eth_dev_close(0);
	}
	rte_eal_cleanup();
	return 0;
}
