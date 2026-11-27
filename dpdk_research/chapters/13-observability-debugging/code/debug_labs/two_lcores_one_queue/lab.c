/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13 debug lab 5: two_lcores_one_queue - "counters do not add up".
 *
 * Story: to "use more cores", the same forwarding function was launched on
 * two lcores, and both poll port 0 queue 0 (and transmit on it). An ethdev
 * queue is single-threaded: the PMD keeps per-queue state without locks.
 * net_ring's queue is an rte_ring created single-producer/single-consumer
 * (RING_F_SP_ENQ | RING_F_SC_DEQ), so two consumers can dequeue the SAME
 * mbufs, and two producers can overwrite each other's slots. Packets get
 * duplicated or lost, and the PMD's plain (non-atomic) counters lose
 * updates.
 *
 * The check: 256 frames are injected into a loopback port; after the run,
 * drain the port and count what is left. Without the bug exactly 256
 * distinct mbufs come back and in_use is 256 before the drain, 0 after.
 * Build with -DFIXED: each lcore owns one port (queue) of its own.
 *
 *   ./lab -l 0-2 --no-pci --no-huge -m 128 --file-prefix=ch13-dbg-2lc \
 *       --vdev=net_ring0 --vdev=net_ring1
 */
#include "../../ch13_common.h"

#define NPKT 256

static RTE_ATOMIC(uint64_t) app_rx[RTE_MAX_LCORE];

static int
fwd(void *arg)
{
	uint16_t port = (uint16_t)(uintptr_t)arg;
	struct rte_mbuf *pkts[32];
	uint64_t n_rx = 0;

	while (!ch13_quit) {
		uint16_t n = rte_eth_rx_burst(port, 0, pkts, 32), s;

		n_rx += n;
		s = rte_eth_tx_burst(port, 0, pkts, n);  /* loop back */
		if (s < n)
			rte_pktmbuf_free_bulk(&pkts[s], n - s);
	}
	rte_atomic_store_explicit(&app_rx[rte_lcore_id()], n_rx,
				  rte_memory_order_relaxed);
	return 0;
}

static int
cmp_ptr(const void *a, const void *b)
{
	uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;

	return x < y ? -1 : x > y;
}

int
main(int argc, char **argv)
{
	static struct rte_mbuf *left[4096];
	struct rte_mempool *mp;
	unsigned int lc, nleft = 0, dups = 0, i, k = 0, injected;
	uint64_t sum = 0, pmd_rx = 0;
	uint16_t p;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (rte_lcore_count() < 3 || rte_eth_dev_count_avail() < 2)
		rte_exit(EXIT_FAILURE, "need -l 0-2 and two net_ring ports\n");
	mp = rte_pktmbuf_pool_create("lab_pool", 2047, 0, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	for (p = 0; p < 2; p++)
		if (mp == NULL || ch13_port_init(p, mp, NULL, 512) < 0)
			rte_exit(EXIT_FAILURE, "port init failed\n");

	injected = ch13_inject(0, mp, NPKT, 64);
	printf("injected %u frames on port 0", injected);
#ifdef FIXED
	injected += ch13_inject(1, mp, NPKT, 64);
	printf(" and %u on port 1\n", injected - NPKT);
#else
	printf("\n");
#endif
	RTE_LCORE_FOREACH_WORKER(lc) {
#ifdef FIXED
		rte_eal_remote_launch(fwd, (void *)(uintptr_t)(k++), lc);
#else
		rte_eal_remote_launch(fwd, (void *)(uintptr_t)0, lc);  /* BUG */
		k++;
#endif
	}
	printf("%u lcores forwarding, %s\n", k,
#ifdef FIXED
	       "one port each"
#else
	       "both on port 0 queue 0"
#endif
	       );
	fflush(stdout);
	rte_delay_ms(1500);
	ch13_quit = true;
	rte_eal_mp_wait_lcore();

	RTE_LCORE_FOREACH_WORKER(lc)
		sum += rte_atomic_load_explicit(&app_rx[lc], rte_memory_order_relaxed);
	for (p = 0; p < 2; p++) {
		struct rte_eth_stats st;

		rte_eth_stats_get(p, &st);
		pmd_rx += st.ipackets;
	}
	printf("app counted %" PRIu64 " RX, the PMD counted %" PRIu64 " (%s)\n",
	       sum, pmd_rx, sum == pmd_rx ? "equal" : "DIFFERENT");
	printf("in_use before drain: %u\n", rte_mempool_in_use_count(mp));

	for (p = 0; p < 2; p++) {
		uint16_t n;

		while ((n = rte_eth_rx_burst(p, 0, &left[nleft],
				RTE_MIN(32u, RTE_DIM(left) - nleft))) > 0)
			nleft += n;
	}
	qsort(left, nleft, sizeof(left[0]), cmp_ptr);
	for (i = 1; i < nleft; i++)
		if (left[i] == left[i - 1])
			dups++;
	printf("drained %u mbufs (expected %u), %u duplicates\n", nleft,
	       injected, dups);
	/* free each distinct mbuf once */
	for (i = 0; i < nleft; i++)
		if (i == 0 || left[i] != left[i - 1])
			rte_pktmbuf_free(left[i]);
	printf("in_use after drain: %u -> %s\n", rte_mempool_in_use_count(mp),
	       rte_mempool_in_use_count(mp) == 0 && dups == 0 &&
	       nleft == injected ?
	       "PASS" : "FAIL");
	rte_eal_cleanup();
	return 0;
}
