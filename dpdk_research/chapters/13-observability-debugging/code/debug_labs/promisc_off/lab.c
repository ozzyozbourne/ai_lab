/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13 debug lab 1: promisc_off - "the port is up but nothing arrives".
 *
 * Story: the app owns a "service" MAC address 02:13:00:00:00:fe (think of a
 * virtual router MAC). The upstream device sends every frame to that MAC.
 * Someone turned promiscuous mode off ("we do not want other people's
 * traffic") but nobody told the port about the service MAC. The port's
 * receive filter only accepts its own MAC, broadcast and (maybe) multicast,
 * so the service traffic is dropped before the application ever sees it.
 *
 * Build with -DFIXED for the fix: rte_eth_dev_mac_addr_add() the service MAC.
 *
 *   ./lab -l 0 --no-pci --no-huge -m 128 --file-prefix=ch13-dbg-promisc \
 *       --vdev=net_tap0,iface=ch13tap1
 */
#include "../../ch13_common.h"

#define TAPIF "ch13tap1"

int
main(int argc, char **argv)
{
	static const struct rte_ether_addr svc = {{0x02, 0x13, 0, 0, 0, 0xfe}};
	static const struct rte_ether_addr bcast = {{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}};
	struct rte_ether_addr me;
	struct rte_mempool *mp;
	struct rte_mbuf *pkts[32];
	unsigned int got = 0, round;
	char a[RTE_ETHER_ADDR_FMT_SIZE];

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("lab_pool", 1023, 32, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL || ch13_port_init(0, mp, NULL, 256) < 0)
		rte_exit(EXIT_FAILURE, "port init failed\n");

	rte_eth_promiscuous_disable(0);              /* the "harmless" change */
#ifdef FIXED
	/* tell the receive filter about every address we answer to */
	printf("mac_addr_add(service MAC) -> %d\n",
	       rte_eth_dev_mac_addr_add(0, (struct rte_ether_addr *)&svc, 0));
#endif
	rte_eth_macaddr_get(0, &me);
	rte_ether_format_addr(a, sizeof(a), &me);
	printf("port MAC %s, promiscuous=%d, service MAC 02:13:00:00:00:fe\n",
	       a, rte_eth_promiscuous_get(0));

	for (round = 0; round < 10; round++) {          /* ~2.5 s */
		uint64_t end = rte_rdtsc() + rte_get_tsc_hz() / 4;

		kernel_inject(TAPIF, &svc, 20, 60);     /* the real traffic */
		kernel_inject(TAPIF, &bcast, 1, 60);    /* e.g. an ARP broadcast */
		while (rte_rdtsc() < end) {
			uint16_t n = rte_eth_rx_burst(0, 0, pkts, 32);

			got += n;
			rte_pktmbuf_free_bulk(pkts, n);
		}
		if (round == 4) {
			printf("t=1.25s: app received %u frames so far (sent %u)\n",
			       got, 21 * (round + 1));
			fflush(stdout);
		}
	}
	printf("app received %u of %u frames (%u service + %u broadcast sent)\n",
	       got, 21 * 10, 200, 10);
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_eal_cleanup();
	return 0;
}
