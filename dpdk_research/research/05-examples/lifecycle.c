#include <stdio.h>
#include <inttypes.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_cycles.h>

static uint16_t rx_cb(uint16_t port, uint16_t q, struct rte_mbuf **pkts, uint16_t n, uint16_t max, void *arg)
{ (void)port;(void)q;(void)pkts;(void)max; *(uint64_t*)arg += n; return n; }

static int ev_cb(uint16_t port, enum rte_eth_event_type ev, void *a, void *r)
{ (void)a;(void)r; printf("EVENT port %u type %d\n", port, ev); return 0; }

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) return 1;
	printf("ports available: %u\n", rte_eth_dev_count_avail());
	struct rte_mempool *mp = rte_pktmbuf_pool_create("mp", 4095, 256, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	uint16_t pid;
	RTE_ETH_FOREACH_DEV(pid) {
		struct rte_eth_dev_info di; char name[64];
		rte_eth_dev_info_get(pid, &di);
		rte_eth_dev_get_name_by_port(pid, name, sizeof(name));
		printf("port %u %s drv=%s maxrxq=%u reta=%u rx_capa=0x%" PRIx64 " tx_capa=0x%" PRIx64 " flow_rss=0x%" PRIx64 "\n",
		       pid, name, di.driver_name, di.max_rx_queues, di.reta_size, di.rx_offload_capa, di.tx_offload_capa, di.flow_type_rss_offloads);
		/* try rx/tx before configure: fp_ops are dummies */
		struct rte_mbuf *b[32];
		printf(" rx before start = %u\n", rte_eth_rx_burst(pid, 0, b, 32));
		struct rte_eth_conf conf = {0};
		if (di.flow_type_rss_offloads) {
			conf.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
			conf.rx_adv_conf.rss_conf.rss_hf = RTE_ETH_RSS_IP & di.flow_type_rss_offloads;
		}
		int r = rte_eth_dev_configure(pid, 4, 4, &conf);
		printf(" configure -> %d\n", r);
		uint16_t nrx = 1024, ntx = 1024;
		rte_eth_dev_adjust_nb_rx_tx_desc(pid, &nrx, &ntx);
		for (int q = 0; q < 4; q++) {
			rte_eth_rx_queue_setup(pid, q, nrx, rte_eth_dev_socket_id(pid), NULL, mp);
			rte_eth_tx_queue_setup(pid, q, ntx, rte_eth_dev_socket_id(pid), NULL);
		}
		rte_eth_dev_callback_register(pid, RTE_ETH_EVENT_INTR_LSC, ev_cb, NULL);
		static uint64_t cnt;
		rte_eth_add_rx_callback(pid, 0, rx_cb, &cnt);
		printf(" start -> %d\n", rte_eth_dev_start(pid));
		printf(" configure while started -> %d (expect -EBUSY=%d)\n", rte_eth_dev_configure(pid, 1, 1, &conf), -EBUSY);
		struct rte_eth_link link; char ls[RTE_ETH_LINK_MAX_STR_LEN];
		rte_eth_link_get_nowait(pid, &link); rte_eth_link_to_str(ls, sizeof ls, &link); printf(" link: %s\n", ls);
		if (di.reta_size) {
			struct rte_eth_rss_reta_entry64 reta[RTE_ETH_RSS_RETA_SIZE_512 / RTE_ETH_RETA_GROUP_SIZE] = {0};
			for (unsigned i = 0; i < di.reta_size; i++) {
				reta[i / RTE_ETH_RETA_GROUP_SIZE].mask |= 1ULL << (i % RTE_ETH_RETA_GROUP_SIZE);
				reta[i / RTE_ETH_RETA_GROUP_SIZE].reta[i % RTE_ETH_RETA_GROUP_SIZE] = i % 4;
			}
			printf(" reta_update -> %d\n", rte_eth_dev_rss_reta_update(pid, reta, di.reta_size));
			memset(reta, 0, sizeof reta); for (unsigned g = 0; g < di.reta_size / 64; g++) reta[g].mask = ~0ULL;
			rte_eth_dev_rss_reta_query(pid, reta, di.reta_size);
			printf(" reta[0..7] = %u %u %u %u %u %u %u %u\n", reta[0].reta[0], reta[0].reta[1], reta[0].reta[2], reta[0].reta[3], reta[0].reta[4], reta[0].reta[5], reta[0].reta[6], reta[0].reta[7]);
		}
		printf(" mtu_set 9000 -> %d\n", rte_eth_dev_set_mtu(pid, 9000));
		printf(" promisc_disable -> %d, now=%d\n", rte_eth_promiscuous_disable(pid), rte_eth_promiscuous_get(pid));
		uint64_t t0 = rte_rdtsc(); uint64_t got = 0;
		for (int i = 0; i < 100; i++) {
			for (int q = 0; q < 4; q++) {
				uint16_t n = rte_eth_rx_burst(pid, q, b, 32);
				got += n;
				uint16_t s = rte_eth_tx_burst(pid, q, b, n);
				if (s < n) rte_pktmbuf_free_bulk(&b[s], n - s);
			}
		}
		printf(" rx total %" PRIu64 " (cb on q0 saw %" PRIu64 ") cycles %" PRIu64 "\n", got, cnt, rte_rdtsc() - t0);
		struct rte_eth_stats st; rte_eth_stats_get(pid, &st);
		printf(" stats ipackets=%" PRIu64 " opackets=%" PRIu64 " imissed=%" PRIu64 " rx_nombuf=%" PRIu64 "\n", st.ipackets, st.opackets, st.imissed, st.rx_nombuf);
		int nx = rte_eth_xstats_get_names(pid, NULL, 0); printf(" xstats count %d\n", nx);
		rte_eth_dev_stop(pid);
		printf(" rx after stop = %u\n", rte_eth_rx_burst(pid, 0, b, 32));
		rte_eth_dev_close(pid);
	}
	rte_eal_cleanup();
	return 0;
}
