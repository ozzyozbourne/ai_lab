/* SPDX-License-Identifier: BSD-3-Clause
 *
 * vdev_runtime.c - Chapter 9: create and destroy virtual devices at run time.
 *
 * The program starts with NO --vdev on the command line, so after
 * rte_eal_init() there are zero ethdev ports. It then:
 *   1. creates net_null0 (size=64) and net_ring0 with rte_vdev_init(),
 *   2. creates net_null1 with the generic hotplug call rte_dev_probe(),
 *   3. tries two calls that fail (duplicate name, unknown driver),
 *   4. creates crypto_null0: the vdev bus is not only for Ethernet,
 *   5. prints every port it now has (name, driver, queue limits, MAC),
 *   6. receives one burst from net_null0 to prove the port really works and
 *      that the size=64 devarg reached the driver,
 *   7. removes ports again with rte_vdev_uninit() and rte_dev_remove().
 *
 * Run:
 *   ./vdev_runtime -l 0 --no-pci --no-huge -m 128 --file-prefix=ch09-rt
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_debug.h>
#include <rte_errno.h>
#include <rte_dev.h>
#include <rte_bus.h>
#include <rte_bus_vdev.h>        /* rte_vdev_init(), rte_vdev_uninit() */
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_cryptodev.h>

#define BURST 32

static void
show_ports(const char *when)
{
	uint16_t port;

	printf("\n-- ports %s: rte_eth_dev_count_avail() = %u\n", when,
	       rte_eth_dev_count_avail());
	RTE_ETH_FOREACH_DEV(port) {
		struct rte_eth_dev_info info;
		struct rte_ether_addr mac;
		char name[RTE_ETH_NAME_MAX_LEN];

		/* 26.11: the name call takes the buffer size */
		if (rte_eth_dev_get_name_by_port(port, name, sizeof(name)) != 0 ||
		    rte_eth_dev_info_get(port, &info) != 0)
			continue;
		rte_eth_macaddr_get(port, &mac);
		printf("   port %u  %-10s driver=%-9s bus=%s max_rxq=%u max_txq=%u "
		       "mac=" RTE_ETHER_ADDR_PRT_FMT "\n",
		       port, name, info.driver_name,
		       rte_bus_name(rte_dev_bus(info.device)),
		       info.max_rx_queues, info.max_tx_queues,
		       RTE_ETHER_ADDR_BYTES(&mac));
	}
}

/* Smallest possible port bring-up (ch8): 1 RX + 1 TX queue, then one burst. */
static void
one_burst(uint16_t port, struct rte_mempool *mp)
{
	struct rte_eth_conf conf;
	struct rte_mbuf *pkts[BURST];
	uint16_t n;

	memset(&conf, 0, sizeof(conf));
	if (rte_eth_dev_configure(port, 1, 1, &conf) != 0 ||
	    rte_eth_rx_queue_setup(port, 0, 128, rte_eth_dev_socket_id(port), NULL, mp) != 0 ||
	    rte_eth_tx_queue_setup(port, 0, 128, rte_eth_dev_socket_id(port), NULL) != 0 ||
	    rte_eth_dev_start(port) != 0) {
		printf("   port %u: bring-up failed\n", port);
		return;
	}
	n = rte_eth_rx_burst(port, 0, pkts, BURST);
	printf("\n-- rx_burst on port %u returned %u mbufs, first pkt_len=%u "
	       "(the size=64 devarg at work)\n", port, n, n ? pkts[0]->pkt_len : 0);
	rte_pktmbuf_free_bulk(pkts, n);
	rte_eth_dev_stop(port);
}

static void
try_vdev(const char *name, const char *args)
{
	int ret = rte_vdev_init(name, args);

	printf("rte_vdev_init(\"%s\", %s%s%s) = %d%s%s\n", name,
	       args ? "\"" : "", args ? args : "NULL", args ? "\"" : "", ret,
	       ret < 0 ? "  " : "", ret < 0 ? rte_strerror(-ret) : "");
}

int
main(int argc, char **argv)
{
	struct rte_mempool *mp;
	uint16_t port;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	show_ports("after rte_eal_init (no --vdev given)");
	printf("\n");

	/* 1. the vdev-bus call: driver name prefix + instance number */
	try_vdev("net_null0", "size=64");
	try_vdev("net_ring0", NULL);

	/* 2. the generic hotplug call takes one full devargs string */
	ret = rte_dev_probe("net_null1,copy=1");
	printf("rte_dev_probe(\"net_null1,copy=1\") = %d\n", ret);

	/* 3. failures */
	try_vdev("net_null0", NULL);           /* name already in use */
	try_vdev("net_bogus0", NULL);          /* no driver has this prefix */
	try_vdev("net_null9", "colour=red");   /* driver rejects an unknown key */

	/* 4. other device classes use the same bus */
	try_vdev("crypto_null0", NULL);
	printf("rte_cryptodev_count() = %u\n", rte_cryptodev_count());

	show_ports("after hot-adding");

	mp = rte_pktmbuf_pool_create("ch09_rt_pool", 1024, 0, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	if (rte_eth_dev_get_port_by_name("net_null0", &port) == 0)
		one_burst(port, mp);

	/* 7a. vdev-specific removal: close the port, then uninit the vdev */
	if (rte_eth_dev_get_port_by_name("net_ring0", &port) == 0) {
		rte_eth_dev_close(port);
		printf("\nrte_vdev_uninit(\"net_ring0\") = %d\n", rte_vdev_uninit("net_ring0"));
	}
	/* 7b. generic removal: rte_dev_remove() takes the struct rte_device */
	if (rte_eth_dev_get_port_by_name("net_null1", &port) == 0) {
		struct rte_eth_dev_info info;

		if (rte_eth_dev_info_get(port, &info) != 0)
			rte_exit(EXIT_FAILURE, "dev_info\n");
		rte_eth_dev_close(port);
		printf("rte_dev_remove(<net_null1>) = %d\n",
		       rte_dev_remove((struct rte_device *)(uintptr_t)info.device));
	}
	show_ports("after removing two of them");

	rte_eal_cleanup();   /* closes the remaining devices */
	return 0;
}
