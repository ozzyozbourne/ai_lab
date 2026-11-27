/* SPDX-License-Identifier: BSD-3-Clause
 * rxtx_latency.c - RX/TX burst callbacks: measure time spent inside the app.
 *
 * Inspired by examples/rxtx_callbacks. Two net_ring ports, each a loopback
 * (what you TX on net_ringN comes back on its own RX queue):
 *
 *   pool --tx--> ring0 --rx_burst--> [RX callbacks: A, B, C] --> "app work"
 *        --tx_burst--> [TX callback: measure] --> ring1 --rx--> free
 *
 * RX callback C stores rte_rdtsc() in a private mbuf dynamic field; the TX
 * callback on port 1 subtracts it. Callback A is added LAST but with
 * rte_eth_add_first_rx_callback(), so it runs FIRST.
 * The app work is a busy loop of W cycles per packet; we sweep W and report
 * the median of 5 trials (min..max). Numbers are for software ring ports
 * on a shared VM: compare them with each other, not with a real NIC.
 * At the end the callbacks are removed from the polling thread itself
 * (the only moment it is safe to rte_free() them immediately).
 *
 * Run: ./rxtx_latency -l 0 --no-pci --no-huge -m 128 --file-prefix=ch12-cb \
 *        --vdev=net_ring0 --vdev=net_ring1
 */
#include <inttypes.h>
#include <rte_cycles.h>
#include <rte_malloc.h>
#include <rte_mbuf_dyn.h>
#include "ch12_common.h"

#define BURST 32
#define TRIALS 5
#define ITERS 20000

static int stamp_off = -1;		/* dynfield offset */
static char order[16];			/* which callbacks ran, in order */
static uint64_t lat_cycles, lat_pkts;	/* filled by the TX callback */
static uint64_t cb_bursts;		/* counted by callback B */

static inline uint64_t *
stamp(struct rte_mbuf *m)
{
	return RTE_MBUF_DYNFIELD(m, stamp_off, uint64_t *);
}

static void
mark(char c)
{
	size_t n = strlen(order);

	if (n < sizeof(order) - 1) {
		order[n] = c;
		order[n + 1] = 0;
	}
}

/* A: added with add_first_rx_callback, runs before every other callback */
static uint16_t
cb_first(uint16_t port, uint16_t q, struct rte_mbuf **pkts, uint16_t n,
	 uint16_t max, void *arg)
{
	(void)port; (void)q; (void)pkts; (void)max; (void)arg;
	mark('A');
	return n;	/* the return value is the new burst size */
}

/* B: counts bursts */
static uint16_t
cb_count(uint16_t port, uint16_t q, struct rte_mbuf **pkts, uint16_t n,
	 uint16_t max, void *arg)
{
	(void)port; (void)q; (void)pkts; (void)max; (void)arg;
	mark('B');
	cb_bursts++;
	return n;
}

/* C: timestamps every packet at RX */
static uint16_t
cb_stamp(uint16_t port, uint16_t q, struct rte_mbuf **pkts, uint16_t n,
	 uint16_t max, void *arg)
{
	uint64_t now = rte_rdtsc();
	uint16_t i;

	(void)port; (void)q; (void)max; (void)arg;
	mark('C');
	for (i = 0; i < n; i++)
		*stamp(pkts[i]) = now;
	return n;
}

/* TX callback: runs inside rte_eth_tx_burst(), before the PMD */
static uint16_t
cb_latency(uint16_t port, uint16_t q, struct rte_mbuf **pkts, uint16_t n,
	   void *arg)
{
	uint64_t now = rte_rdtsc();
	uint16_t i;

	(void)port; (void)q; (void)arg;
	mark('T');
	for (i = 0; i < n; i++)
		lat_cycles += now - *stamp(pkts[i]);
	lat_pkts += n;
	return n;
}

/* One trial: ITERS bursts through ring0 -> app -> ring1. Returns the
 * average cycles per packet between RX callback and TX callback. */
static double
trial(struct rte_mempool *mp, uint64_t work)
{
	struct rte_mbuf *b[BURST];
	int it;

	lat_cycles = lat_pkts = 0;
	for (it = 0; it < ITERS; it++) {
		uint16_t n, k, i;

		if (rte_pktmbuf_alloc_bulk(mp, b, BURST) != 0)
			break;
		for (i = 0; i < BURST; i++)
			rte_pktmbuf_append(b[i], 60);
		k = rte_eth_tx_burst(0, 0, b, BURST);	/* into loopback ring0 */
		rte_pktmbuf_free_bulk(b + k, BURST - k);

		n = rte_eth_rx_burst(0, 0, b, BURST);	/* RX callbacks run here */
		for (i = 0; i < n; i++) {		/* "application work" */
			uint64_t end = rte_rdtsc() + work;

			while (rte_rdtsc() < end)
				rte_pause();
		}
		k = rte_eth_tx_burst(1, 0, b, n);	/* TX callback runs here */
		rte_pktmbuf_free_bulk(b + k, n - k);

		n = rte_eth_rx_burst(1, 0, b, BURST);	/* drain ring1 */
		rte_pktmbuf_free_bulk(b, n);
	}
	return lat_pkts ? (double)lat_cycles / lat_pkts : 0;
}

static int
cmpd(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return x < y ? -1 : x > y;
}

int
main(int argc, char **argv)
{
	static const struct rte_mbuf_dynfield desc = {
		.name = "ch12_rx_tsc",
		.size = sizeof(uint64_t),
		.align = sizeof(uint64_t),
	};
	static const uint64_t works[] = { 0, 100, 500, 2000 };
	const struct rte_eth_rxtx_callback *ca, *cbb, *cc, *ct;
	struct rte_mempool *mp;
	double hz, r[TRIALS];
	unsigned w, t;
	int rc;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (rte_eth_dev_count_avail() < 2)
		rte_exit(EXIT_FAILURE, "need --vdev=net_ring0 --vdev=net_ring1\n");
	stamp_off = rte_mbuf_dynfield_register(&desc);
	if (stamp_off < 0)
		rte_exit(EXIT_FAILURE, "dynfield: %s\n", rte_strerror(rte_errno));
	printf("dynfield \"%s\" registered at mbuf offset %d\n", desc.name, stamp_off);

	mp = rte_pktmbuf_pool_create("cb_pool", 2047, 64, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (!mp || ch12_port_init(0, 1, 1, mp, NULL, NULL, 1) < 0 ||
	    ch12_port_init(1, 1, 1, mp, NULL, NULL, 1) < 0)
		rte_exit(EXIT_FAILURE, "setup failed\n");

	/* Register: B then C with add_rx_callback (appended in order),
	 * then A with add_first_rx_callback (prepended). */
	cbb = rte_eth_add_rx_callback(0, 0, cb_count, NULL);
	cc = rte_eth_add_rx_callback(0, 0, cb_stamp, NULL);
	ca = rte_eth_add_first_rx_callback(0, 0, cb_first, NULL);
	ct = rte_eth_add_tx_callback(1, 0, cb_latency, NULL);
	if (!ca || !cbb || !cc || !ct)
		rte_exit(EXIT_FAILURE, "add callback: %s\n", rte_strerror(rte_errno));
	order[0] = 0;
	trial(mp, 0);
	order[4] = 0;
	printf("callback order in one burst (registered B, C, then first A; T = TX): %s\n",
	       order);
	order[0] = 0;

	hz = (double)rte_get_tsc_hz();
	printf("TSC %.0f MHz; %d bursts of %d per trial, %d trials\n",
	       hz / 1e6, ITERS, BURST, TRIALS);
	printf("%-16s %-28s %s\n", "work/pkt", "RX-cb -> TX-cb latency/pkt",
	       "(median, min..max)");
	for (w = 0; w < RTE_DIM(works); w++) {
		for (t = 0; t < TRIALS; t++) {
			order[0] = 0;
			r[t] = trial(mp, works[w]);
		}
		qsort(r, TRIALS, sizeof(r[0]), cmpd);
		printf("%5" PRIu64 " cycles     %9.0f cycles = %8.2f us   (%.0f..%.0f cycles)\n",
		       works[w], r[TRIALS / 2], r[TRIALS / 2] * 1e6 / hz, r[0],
		       r[TRIALS - 1]);
	}
	printf("note: the TX callback runs when the WHOLE burst is handed to\n"
	       "      tx_burst, so every packet waits for all %d packets of work:\n"
	       "      latency ~ work x %d + fixed overhead\n", BURST, BURST);

	/* Remove the callbacks. We are the only thread polling these queues,
	 * so no burst is in flight and the memory can be freed right away.
	 * With other polling lcores you must wait (delay, or RCU: ch14). */
	rc = rte_eth_remove_rx_callback(0, 0, ca);
	rc |= rte_eth_remove_rx_callback(0, 0, cbb);
	rc |= rte_eth_remove_rx_callback(0, 0, cc);
	rc |= rte_eth_remove_tx_callback(1, 0, ct);
	printf("remove callbacks -> %s\n", rcname(rc));
	cb_bursts = 0;
	trial(mp, 0);
	printf("after removal: callback B counted %" PRIu64 " bursts, TX callback saw %"
	       PRIu64 " packets\n", cb_bursts, lat_pkts);
	printf("remove again -> %s (already gone)\n",
	       rcname(rte_eth_remove_rx_callback(0, 0, cc)));
	/* ethdev does not free a removed callback: the app does, once no
	 * lcore can still be executing it. */
	rte_free((void *)(uintptr_t)ca);
	rte_free((void *)(uintptr_t)cbb);
	rte_free((void *)(uintptr_t)cc);
	rte_free((void *)(uintptr_t)ct);

	rte_eth_dev_stop(0);
	rte_eth_dev_stop(1);
	rte_eth_dev_close(0);
	rte_eth_dev_close(1);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
