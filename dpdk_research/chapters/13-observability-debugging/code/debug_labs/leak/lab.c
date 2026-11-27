/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13 debug lab 3: leak - "it forwards for a moment, then stops".
 *
 * Story: a filter was added to the forwarder: only IPv4 is forwarded, the
 * rest is dropped. The drop branch does "continue" and forgets to free the
 * mbuf. net_null delivers zero-filled frames (ether_type 0), so EVERY frame
 * takes the drop branch: each RX burst permanently loses 32 mbufs, the pool
 * runs dry, the PMD can no longer refill (rx_nombuf climbs) and RX returns 0.
 *
 * Diagnosis: rte_mempool_in_use_count() creeps up to the pool size;
 * telemetry /mempool/info shows common_pool_count falling to 0 and
 * /ethdev/stats shows rx_nombuf rising.
 * Build with -DFIXED: free what you drop (rte_pktmbuf_free).
 *
 *   ./lab -l 0 --no-pci --no-huge -m 128 --file-prefix=ch13-dbg-leak \
 *       --vdev=net_null0 --vdev=net_null1
 */
#include "../../ch13_common.h"

int
main(int argc, char **argv)
{
	struct rte_mempool *mp;
	struct rte_mbuf *pkts[32];
	uint64_t fwd = 0, dropped = 0, hz;
	unsigned int sec;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("lab_pool", 8191, 64, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL || ch13_port_init(0, mp, NULL, 256) < 0 ||
	    ch13_port_init(1, mp, NULL, 256) < 0)
		rte_exit(EXIT_FAILURE, "port init failed\n");

	hz = rte_get_tsc_hz();
	for (sec = 1; sec <= 5; sec++) {        /* 5 x 0.5 s */
		uint64_t end = rte_rdtsc() + hz / 2;
		struct rte_eth_stats st;

		while (rte_rdtsc() < end) {
			uint16_t i, n = rte_eth_rx_burst(0, 0, pkts, 32), k = 0;

			for (i = 0; i < n; i++) {
				struct rte_ether_hdr *eh =
					rte_pktmbuf_mtod(pkts[i], struct rte_ether_hdr *);

				if (eh->ether_type != RTE_BE16(RTE_ETHER_TYPE_IPV4)) {
					dropped++;
#ifdef FIXED
					rte_pktmbuf_free(pkts[i]);
#endif
					continue;       /* BUG without FIXED: leaked */
				}
				pkts[k++] = pkts[i];
			}
			k = rte_eth_tx_burst(1, 0, pkts, k);
			fwd += k;
		}
		rte_eth_stats_get(0, &st);
		printf("t=%.1fs in_use=%u/%u avail=%u  rx=%" PRIu64 " rx_nombuf=%" PRIu64
		       " dropped=%" PRIu64 "\n", sec * 0.5,
		       rte_mempool_in_use_count(mp), mp->size,
		       rte_mempool_avail_count(mp), st.ipackets, st.rx_nombuf, dropped);
		fflush(stdout);
	}
	(void)fwd;
	rte_eth_dev_stop(0);
	rte_eth_dev_stop(1);
	rte_eal_cleanup();
	return 0;
}
