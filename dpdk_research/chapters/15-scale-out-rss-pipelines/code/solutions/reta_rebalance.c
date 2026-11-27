/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Exercise 1 solution: give queue 1 three quarters of the RETA on net_null,
 * confirm with rte_eth_dev_rss_reta_query(), and observe that the
 * per-queue counters do not move with it (net_null is poll-driven).
 *
 *   ./reta_rebalance -l 0 --no-pci --no-huge -m 128 --file-prefix=ch15-ex1 \
 *       --vdev=net_null0
 */
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>

#define NQ 4

int
main(int argc, char **argv)
{
	struct rte_eth_rss_reta_entry64 reta[RTE_ETH_RSS_RETA_SIZE_512 / RTE_ETH_RETA_GROUP_SIZE];
	struct rte_eth_conf conf;
	struct rte_eth_dev_info info;
	struct rte_mempool *mp;
	struct rte_eth_stats st;
	unsigned int i, cnt[NQ] = {0}, q;

	if (rte_eal_init(argc, argv) < 0)
		return 1;
	mp = rte_pktmbuf_pool_create("ex1", 2047, 64, 0, RTE_MBUF_DEFAULT_BUF_SIZE, 0);
	if (mp == NULL || rte_eth_dev_info_get(0, &info) != 0)
		return 1;

	memset(&conf, 0, sizeof(conf));
	conf.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
	conf.rx_adv_conf.rss_conf.rss_hf = RTE_ETH_RSS_IP & info.flow_type_rss_offloads;
	if (rte_eth_dev_configure(0, NQ, NQ, &conf) != 0)
		return 1;
	for (q = 0; q < NQ; q++) {
		rte_eth_rx_queue_setup(0, q, 256, 0, NULL, mp);
		rte_eth_tx_queue_setup(0, q, 256, 0, NULL);
	}
	rte_eth_dev_start(0);

	/* entries 0,1,2 of every 4 -> queue 1; entry 3 -> queue (i/4) % 4,
	 * skipping 1: 3/4 of the table points at queue 1 */
	memset(reta, 0, sizeof(reta));
	for (i = 0; i < info.reta_size; i++) {
		static const uint16_t others[] = { 0, 2, 3 };
		struct rte_eth_rss_reta_entry64 *g = &reta[i / RTE_ETH_RETA_GROUP_SIZE];
		g->mask |= 1ULL << (i % RTE_ETH_RETA_GROUP_SIZE);
		g->reta[i % RTE_ETH_RETA_GROUP_SIZE] =
			(i % 4 != 3) ? 1 : others[(i / 4) % 3];
	}
	printf("reta_update -> %d\n", rte_eth_dev_rss_reta_update(0, reta, info.reta_size));

	memset(reta, 0, sizeof(reta));
	for (i = 0; i < info.reta_size / RTE_ETH_RETA_GROUP_SIZE; i++)
		reta[i].mask = UINT64_MAX;
	rte_eth_dev_rss_reta_query(0, reta, info.reta_size);
	for (i = 0; i < info.reta_size; i++)
		cnt[reta[i / RTE_ETH_RETA_GROUP_SIZE].reta[i % RTE_ETH_RETA_GROUP_SIZE]]++;
	printf("reta_query: q0 %u  q1 %u  q2 %u  q3 %u (of %u)\n",
	       cnt[0], cnt[1], cnt[2], cnt[3], info.reta_size);

	for (q = 0; q < NQ; q++) {
		struct rte_mbuf *p[32];
		uint16_t n = rte_eth_rx_burst(0, q, p, 32);
		rte_pktmbuf_free_bulk(p, n);
	}
	rte_eth_stats_get(0, &st);
	printf("one burst per queue: ipackets %" PRIu64 " (= 4 x 32, the RETA is not consulted)\n",
	       st.ipackets);
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_eal_cleanup();
	return 0;
}
