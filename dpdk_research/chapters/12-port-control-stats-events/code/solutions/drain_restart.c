/* SPDX-License-Identifier: BSD-3-Clause
 * Exercise 6 solution: take RX queue 1 of a running tap port out of
 * service and back, without stopping the port, without leaking mbufs and
 * without delivering stale frames.
 *
 * Order:
 *   1. stop POLLING q1 in the data path (here: one thread, so trivially)
 *   2. drain q1: rx_burst until it returns 0 several times in a row
 *   3. rte_eth_dev_rx_queue_stop(port, 1)
 *        ... queue is out of service; on tap the kernel keeps queueing ...
 *   4. rte_eth_dev_rx_queue_start(port, 1)
 *   5. discard the backlog that queued while stopped (stale), then
 *      resume polling
 * Leak check: rte_mempool_in_use_count() must return to its baseline
 * (tap keeps nb_desc mbufs per RX queue), and to 0 after close.
 *
 * Run: ./drain_restart -l 0 --no-pci --no-huge -m 128 --file-prefix=ch12-dr \
 *        --vdev=net_tap0,iface=ch12tap7
 */
#include <rte_cycles.h>
#include "ch12_common.h"

#define IF "ch12tap7"

/* receive until 'quiet' consecutive empty polls; free; return count */
static unsigned
drain_q(uint16_t port, uint16_t q, int quiet)
{
	struct rte_mbuf *b[32];
	unsigned total = 0;
	int empty = 0;

	while (empty < quiet) {
		uint16_t n = rte_eth_rx_burst(port, q, b, 32);

		if (n == 0) {
			empty++;
			rte_delay_us_block(200);
			continue;
		}
		empty = 0;
		total += n;
		rte_pktmbuf_free_bulk(b, n);
	}
	return total;
}

int
main(int argc, char **argv)
{
	struct rte_mempool *mp;
	struct rte_ether_addr me;
	unsigned base, n;
	int rc;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("dr", 4095, 0, 0, RTE_MBUF_DEFAULT_BUF_SIZE,
				     rte_socket_id());
	if_quiet(IF);
	if (!mp || ch12_port_init(0, 2, 2, mp, NULL, NULL, 1) < 0)
		rte_exit(EXIT_FAILURE, "port init\n");
	rte_eth_macaddr_get(0, &me);
	drain_q(0, 0, 5);
	drain_q(0, 1, 5);
	base = rte_mempool_in_use_count(mp);
	printf("baseline in_use (mbufs the tap PMD keeps per RX queue) = %u\n", base);

	kernel_inject(IF, &me, 300, 16);
	printf("traffic: q0 %u, q1 %u\n", drain_q(0, 0, 5), drain_q(0, 1, 5));

	kernel_inject(IF, &me, 300, 16);	/* q1 has work pending ... */
	/* 1. the data path stops polling q1 (nothing to do: single thread) */
	n = drain_q(0, 1, 5);			/* 2. drain */
	printf("1-2. stopped polling q1, drained %u in-flight frames\n", n);
	rc = rte_eth_dev_rx_queue_stop(0, 1);
	printf("3.   rx_queue_stop(q1) -> %s, rxq_state %s\n", rcname(rc), rxq_states(0));
	drain_q(0, 0, 5);

	kernel_inject(IF, &me, 300, 16);	/* arrives while q1 is stopped */
	printf("     while stopped: q0 got %u (q1 not polled)\n", drain_q(0, 0, 5));
	rc = rte_eth_dev_rx_queue_start(0, 1);
	printf("4.   rx_queue_start(q1) -> %s, rxq_state %s\n", rcname(rc), rxq_states(0));
	n = drain_q(0, 1, 5);
	printf("5.   discarded %u stale frames, resuming q1\n", n);

	kernel_inject(IF, &me, 300, 16);
	printf("traffic: q0 %u, q1 %u\n", drain_q(0, 0, 5), drain_q(0, 1, 5));
	n = rte_mempool_in_use_count(mp);
	printf("in_use = %u (baseline %u) -> %s\n", n, base, n == base ? "no leak" : "LEAK");
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	n = rte_mempool_in_use_count(mp);
	printf("after close in_use = %u -> %s\n", n, n == 0 ? "PASS" : "FAIL");
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
