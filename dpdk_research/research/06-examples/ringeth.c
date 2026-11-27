/* Two ethdev ports wired back-to-back with rte_rings (net_ring PMD API),
 * plus a net_null port hot-plugged at runtime with rte_vdev_init(). */
#include <stdio.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_ring.h>
#include <rte_mbuf.h>
#include <rte_bus_vdev.h>
#include <rte_eth_ring.h>

static int port_init(uint16_t p, struct rte_mempool *mp) {
	struct rte_eth_conf conf = {0};
	if (rte_eth_dev_configure(p, 1, 1, &conf) < 0) return -1;
	if (rte_eth_rx_queue_setup(p, 0, 128, rte_socket_id(), NULL, mp) < 0) return -1;
	if (rte_eth_tx_queue_setup(p, 0, 128, rte_socket_id(), NULL) < 0) return -1;
	return rte_eth_dev_start(p);
}

int main(int argc, char **argv) {
	if (rte_eal_init(argc, argv) < 0) return 1;
	struct rte_mempool *mp = rte_pktmbuf_pool_create("mp", 4095, 256, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	struct rte_ring *r[2];
	r[0] = rte_ring_create("R0", 256, rte_socket_id(), RING_F_SP_ENQ | RING_F_SC_DEQ);
	r[1] = rte_ring_create("R1", 256, rte_socket_id(), RING_F_SP_ENQ | RING_F_SC_DEQ);
	/* port A transmits into R0 and receives from R1; port B is the mirror */
	int a = rte_eth_from_rings("ringA", &r[1], 1, &r[0], 1, rte_socket_id());
	int b = rte_eth_from_rings("ringB", &r[0], 1, &r[1], 1, rte_socket_id());
	if (rte_vdev_init("net_null0", "size=128") < 0) printf("vdev init failed\n");
	uint16_t pid;
	RTE_ETH_FOREACH_DEV(pid) {
		struct rte_eth_dev_info di; char name[RTE_ETH_NAME_MAX_LEN];
		if (rte_eth_dev_info_get(pid, &di) != 0) continue; rte_eth_dev_get_name_by_port(pid, name, sizeof(name));
		printf("port %u: name=%s driver=%s\n", pid, name, di.driver_name);
		port_init(pid, mp);
	}
	struct rte_mbuf *tx[8], *rx[8];
	rte_pktmbuf_alloc_bulk(mp, tx, 8);
	for (int i = 0; i < 8; i++) { char *d = rte_pktmbuf_append(tx[i], 64); d[0] = i; }
	uint16_t s = rte_eth_tx_burst(a, 0, tx, 8);
	printf("ring in R0 after tx on A: %u entries\n", rte_ring_count(r[0]));
	uint16_t n = rte_eth_rx_burst(b, 0, rx, 8);
	printf("sent %u on port %d, received %u on port %d, first byte of #5=%d\n", s, a, n, b,
		rte_pktmbuf_mtod(rx[5], char *)[0]);
	rte_pktmbuf_free_bulk(rx, n);
	uint16_t nn = rte_eth_rx_burst(2, 0, rx, 8);
	printf("net_null rx gave %u pkts of len %u (zeroed? %s)\n", nn, rx[0]->pkt_len, "yes");
	rte_pktmbuf_free_bulk(rx, nn);
	rte_eal_cleanup();
	return 0;
}
