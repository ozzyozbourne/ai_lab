/* SPDX-License-Identifier: BSD-3-Clause
 *
 * pipeline_rings.c - Chapter 15: a ring pipeline with per-stage accounting.
 *
 *     RX lcore --ring w0--> worker 0 --\
 *              --ring w1--> worker 1 ---+--ring tx--> TX lcore
 *
 * The RX stage spreads bursts round-robin over one SP/SC ring per worker.
 * Workers do the synthetic per-packet work and push into one MP/SC ring that
 * the TX stage drains. Each stage counts busy cycles (iterations that had
 * packets) and total cycles, so the program can name the bottleneck stage.
 *
 * Options (after --):
 *   --seconds S        run time (default 2)
 *   --work C           cycles of work per packet in each worker (default 200)
 *   --slow-worker C    worker 0 burns C extra cycles per packet
 *   --policy drop|wait what RX does when a worker ring is full (default drop)
 *   --compress         carry 32-bit compressed mbuf pointers on all rings
 *                      (lib/ptr_compress), 4-byte ring elements
 *   --ring N           ring size (default 1024)
 *
 * Run:  ./pipeline_rings -l 0-3 --no-pci --no-huge -m 256 \
 *          --file-prefix=ch15-pipe --vdev=net_null0,size=64 -- --work 200
 * (lcore 0 = RX, the last lcore = TX, the ones in between = workers)
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
#include <rte_ring.h>
#include <rte_ring_elem.h>
#include <rte_mempool.h>
#include <rte_mbuf.h>
#include <rte_errno.h>
#include <rte_stdatomic.h>
#include <rte_ptr_compress.h>

#include "ch15_common.h"

#define BURST       32
#define MAX_WORKERS 6

struct __rte_cache_aligned stage_stats {
	const char *name;
	uint64_t pkts;          /* packets handled */
	uint64_t drops;         /* packets freed because the next ring was full */
	uint64_t full_events;   /* enqueue calls that did not take everything */
	uint64_t busy, total;   /* cycles with work / all cycles */
	uint64_t fill_sum, fill_samples;  /* input ring occupancy samples */
};

static struct stage_stats rx_st = { .name = "rx" }, tx_st = { .name = "tx" };
static struct stage_stats wk_st[MAX_WORKERS];
static struct rte_ring *wring[MAX_WORKERS], *txring;
static unsigned int nb_workers;
static RTE_ATOMIC(int) stop;
static uint64_t work_cycles = 200, slow_cycles;
static unsigned int seconds = 2, ring_size = 1024;
static int policy_wait, compress;

/* pointer compression parameters, filled in by check_compress() */
static void *cbase;
static uint8_t cshift;

/* ---- ring helpers: 8-byte pointers or 4-byte compressed offsets ---- */
static inline unsigned int
ring_put(struct rte_ring *r, struct rte_mbuf **m, unsigned int n)
{
	if (compress) {
		uint32_t c[BURST];
		rte_ptr_compress_32_shift(cbase, (void * const *)m, c, n, cshift);
		return rte_ring_enqueue_burst_elem(r, c, sizeof(uint32_t), n, NULL);
	}
	return rte_ring_enqueue_burst(r, (void * const *)m, n, NULL);
}

static inline unsigned int
ring_get(struct rte_ring *r, struct rte_mbuf **m, unsigned int n)
{
	if (compress) {
		uint32_t c[BURST];
		unsigned int got = rte_ring_dequeue_burst_elem(r, c, sizeof(uint32_t), n, NULL);
		if (got)
			rte_ptr_decompress_32_shift(cbase, c, (void **)m, got, cshift);
		return got;
	}
	return rte_ring_dequeue_burst(r, (void **)m, n, NULL);
}

static inline int
running(void)
{
	return !rte_atomic_load_explicit(&stop, rte_memory_order_relaxed);
}

/* ---- stage 1: RX, on the main lcore; it also owns the run deadline ---- */
static void
rx_stage(uint64_t deadline)
{
	struct rte_mbuf *pkts[BURST];
	unsigned int next = 0;
	uint64_t start = rte_rdtsc();

	while (running()) {
		uint64_t t0 = rte_rdtsc();
		uint16_t n;
		unsigned int done;

		if (t0 >= deadline) {	/* time is up: tell the other stages */
			rte_atomic_store_explicit(&stop, 1, rte_memory_order_relaxed);
			break;
		}
		n = rte_eth_rx_burst(0, 0, pkts, BURST);
		if (n == 0)
			continue;
		rx_st.pkts += n;
		done = ring_put(wring[next], pkts, n);
		if (done < n) {
			rx_st.full_events++;
			if (policy_wait) {
				/* back-pressure: wait for the worker. RX stops
				 * polling the NIC, so the NIC queue fills and the
				 * NIC drops instead (imissed on real hardware). */
				while (done < n && running())
					done += ring_put(wring[next], pkts + done, n - done);
			}
			if (done < n) {
				rx_st.drops += n - done;
				rte_pktmbuf_free_bulk(pkts + done, n - done);
			}
		}
		next = (next + 1) % nb_workers;	/* round-robin: flows get mixed! */
		rx_st.busy += rte_rdtsc() - t0;
	}
	rx_st.total = rte_rdtsc() - start;
}

/* ---- stage 2: workers ---- */
static int
worker_stage(void *arg)
{
	unsigned int id = (uintptr_t)arg;
	struct stage_stats *st = &wk_st[id];
	struct rte_mbuf *pkts[BURST];
	uint64_t start = rte_rdtsc();
	uint64_t cyc = work_cycles + (id == 0 ? slow_cycles : 0);

	while (running()) {
		uint64_t t0 = rte_rdtsc();
		unsigned int n = ring_get(wring[id], pkts, BURST), i, done;

		if (n == 0)
			continue;
		st->fill_sum += rte_ring_count(wring[id]);
		st->fill_samples++;
		for (i = 0; i < n; i++)
			ch15_work(pkts[i], cyc);
		st->pkts += n;
		done = ring_put(txring, pkts, n);
		if (done < n) {
			st->full_events++;
			st->drops += n - done;
			rte_pktmbuf_free_bulk(pkts + done, n - done);
		}
		st->busy += rte_rdtsc() - t0;
	}
	st->total = rte_rdtsc() - start;
	return 0;
}

/* ---- stage 3: TX ---- */
static int
tx_stage(void *arg)
{
	struct rte_mbuf *pkts[BURST];
	uint64_t start = rte_rdtsc();

	(void)arg;
	while (running()) {
		uint64_t t0 = rte_rdtsc();
		unsigned int n = ring_get(txring, pkts, BURST);
		uint16_t sent;

		if (n == 0)
			continue;
		tx_st.fill_sum += rte_ring_count(txring);
		tx_st.fill_samples++;
		sent = rte_eth_tx_burst(0, 0, pkts, n);
		tx_st.pkts += sent;
		if (sent < n) {
			tx_st.drops += n - sent;
			rte_pktmbuf_free_bulk(pkts + sent, n - sent);
		}
		tx_st.busy += rte_rdtsc() - t0;
	}
	tx_st.total = rte_rdtsc() - start;
	return 0;
}

/* ---- pointer compression precondition ---- */
struct range { uintptr_t lo, hi; };

static void
mem_cb(struct rte_mempool *mp, void *opaque, struct rte_mempool_memhdr *memhdr,
       unsigned int idx)
{
	struct range *r = opaque;
	uintptr_t a = (uintptr_t)memhdr->addr, b = a + memhdr->len;

	if (a < r->lo) r->lo = a;
	if (b > r->hi) r->hi = b;
}

static void
obj_cb(struct rte_mempool *mp, void *opaque, void *obj, unsigned int idx)
{
	uintptr_t *or_bits = opaque;
	*or_bits |= (uintptr_t)obj;	/* common alignment of every mbuf address */
}

static int
check_compress(struct rte_mempool *mp)
{
	struct range r = { UINTPTR_MAX, 0 };
	uintptr_t or_bits = 0;
	uint64_t len;
	unsigned int bits;

	rte_mempool_mem_iter(mp, mem_cb, &r);
	rte_mempool_obj_iter(mp, obj_cb, &or_bits);
	len = r.hi - r.lo;
	cbase = (void *)r.lo;
	/* every mbuf address is a multiple of 2^ctz(or of all addresses) */
	cshift = RTE_PTR_COMPRESS_BIT_SHIFT_FROM_ALIGNMENT(
			(uint64_t)(or_bits & -or_bits));
	bits = RTE_PTR_COMPRESS_BITS_NEEDED_FOR_POINTER_WITHIN_RANGE(len);
	/* the base itself must keep the alignment for offsets to shift cleanly */
	while (cshift && (r.lo & ((1ULL << cshift) - 1)))
		cshift--;
	printf("compress: pool memory %" PRIu64 " bytes -> %u offset bits, objects aligned"
	       " to %u bytes -> shift %u, fits in 32 bits: %s\n", len, bits,
	       1u << cshift, cshift,
	       RTE_PTR_COMPRESS_CAN_COMPRESS_32_SHIFT(len, 1ULL << cshift) ? "yes" : "NO");
	return RTE_PTR_COMPRESS_CAN_COMPRESS_32_SHIFT(len, 1ULL << cshift) ? 0 : -1;
}

static struct rte_ring *
make_ring(const char *name, unsigned int flags)
{
	/* esize 4 for compressed offsets, 8 (= a pointer) otherwise */
	return rte_ring_create_elem(name, compress ? 4 : sizeof(void *), ring_size,
				    rte_socket_id(), flags);
}

static void
print_stage(const struct stage_stats *s, const char *label)
{
	double util = s->total ? 100.0 * s->busy / s->total : 0;
	double cpp = s->pkts ? (double)s->busy / s->pkts : 0;
	double fill = s->fill_samples ? 100.0 * s->fill_sum / s->fill_samples / ring_size : 0;

	printf("  %-9s %10" PRIu64 " pkts %6.2f Mpps  busy %5.1f%%  %6.1f cyc/pkt"
	       "  in-ring fill %5.1f%%  full %8" PRIu64 "  drops %9" PRIu64 "\n",
	       label, s->pkts, s->pkts / (seconds * 1e6), util, cpp, fill,
	       s->full_events, s->drops);
}

int
main(int argc, char **argv)
{
	static const struct option lo[] = {
		{ "seconds", required_argument, NULL, 's' },
		{ "work", required_argument, NULL, 'w' },
		{ "slow-worker", required_argument, NULL, 'S' },
		{ "policy", required_argument, NULL, 'p' },
		{ "compress", no_argument, NULL, 'c' },
		{ "ring", required_argument, NULL, 'r' },
		{ NULL, 0, NULL, 0 },
	};
	struct rte_eth_conf conf;
	struct rte_mempool *mp;
	unsigned int lcore, i, tx_lcore = 0, bott = 0;
	double best = -1;
	int ret, c;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		switch (c) {
		case 's': seconds = atoi(optarg); break;
		case 'w': work_cycles = strtoull(optarg, NULL, 0); break;
		case 'S': slow_cycles = strtoull(optarg, NULL, 0); break;
		case 'p': policy_wait = !strcmp(optarg, "wait"); break;
		case 'c': compress = 1; break;
		case 'r': ring_size = atoi(optarg); break;
		default: rte_exit(EXIT_FAILURE, "bad option\n");
		}
	}
	if (rte_lcore_count() < 3)
		rte_exit(EXIT_FAILURE, "need >= 3 lcores: RX, worker(s), TX\n");
	nb_workers = rte_lcore_count() - 2;
	if (nb_workers > MAX_WORKERS)
		nb_workers = MAX_WORKERS;

	/* mbufs live in rings between stages: size the pool for all rings +
	 * the NIC queues + bursts in flight, or a stalled stage empties it. */
	mp = rte_pktmbuf_pool_create("ch15_pipe_pool", 16383, 256, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	if (compress && check_compress(mp) != 0)
		rte_exit(EXIT_FAILURE, "pool does not fit a 32-bit compressed window\n");

	memset(&conf, 0, sizeof(conf));
	if (rte_eth_dev_configure(0, 1, 1, &conf) != 0 ||
	    rte_eth_rx_queue_setup(0, 0, 1024, rte_socket_id(), NULL, mp) != 0 ||
	    rte_eth_tx_queue_setup(0, 0, 1024, rte_socket_id(), NULL) != 0 ||
	    rte_eth_dev_start(0) != 0)
		rte_exit(EXIT_FAILURE, "port 0 setup failed\n");

	/* Sync mode per hop: RX -> worker i has one producer and one consumer
	 * (SP/SC, cheapest); workers -> TX has many producers (MP), one consumer. */
	for (i = 0; i < nb_workers; i++) {
		char name[32];
		snprintf(name, sizeof(name), "ch15_w%u", i);
		wring[i] = make_ring(name, RING_F_SP_ENQ | RING_F_SC_DEQ);
		snprintf(name, sizeof(name), "worker%u", i);
		wk_st[i].name = strdup(name);
	}
	txring = make_ring("ch15_tx", RING_F_SC_DEQ);
	if (txring == NULL || wring[0] == NULL)
		rte_exit(EXIT_FAILURE, "ring: %s\n", rte_strerror(rte_errno));

	printf("pipeline: RX(lcore %u) -> %u workers -> TX, work %" PRIu64
	       " cyc/pkt, slow-worker +%" PRIu64 ", policy %s, ring %u x %s\n",
	       rte_lcore_id(), nb_workers, work_cycles, slow_cycles,
	       policy_wait ? "wait" : "drop", ring_size,
	       compress ? "4-byte compressed" : "8-byte pointer");

	i = 0;
	RTE_LCORE_FOREACH_WORKER(lcore) {
		if (i < nb_workers)
			rte_eal_remote_launch(worker_stage, (void *)(uintptr_t)i, lcore);
		else
			tx_lcore = lcore;
		i++;
	}
	rte_eal_remote_launch(tx_stage, NULL, tx_lcore);

	/* the main lcore runs the RX stage until the deadline */
	rx_stage(rte_rdtsc() + seconds * rte_get_tsc_hz());
	rte_eal_mp_wait_lcore();

	printf("stage     packets          rate      busy     cost         input ring       ring-full       drops\n");
	print_stage(&rx_st, "rx");
	for (i = 0; i < nb_workers; i++)
		print_stage(&wk_st[i], wk_st[i].name);
	print_stage(&tx_st, "tx");

	/* The bottleneck is the busiest stage after the source. RX is left
	 * out: net_null always has packets, so RX is ~100% busy by
	 * construction (it spends the spare time freeing what it drops). */
	for (i = 1; i < nb_workers + 2; i++) {
		const struct stage_stats *s = i <= nb_workers ? &wk_st[i - 1] : &tx_st;
		double u = s->total ? (double)s->busy / s->total : 0;
		if (u > best) { best = u; bott = i; }
	}
	printf("bottleneck (busiest stage after RX): %s (busy %.1f%%)\n",
	       bott <= nb_workers ? wk_st[bott - 1].name : "tx", 100 * best);
	printf("RESULT model=pipeline work=%" PRIu64 " compress=%d mpps=%.3f\n",
	       work_cycles, compress, tx_st.pkts / (seconds * 1e6));

	/* drain what is still in the rings back to the pool */
	{
		struct rte_mbuf *pk[BURST];
		unsigned int n;
		for (i = 0; i < nb_workers; i++)
			while ((n = ring_get(wring[i], pk, BURST)) > 0)
				rte_pktmbuf_free_bulk(pk, n);
		while ((n = ring_get(txring, pk, BURST)) > 0)
			rte_pktmbuf_free_bulk(pk, n);
	}
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_eal_cleanup();
	return 0;
}
