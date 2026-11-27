/* SPDX-License-Identifier: BSD-3-Clause
 * port_ctl.c - everything you do to a port besides RX and TX.
 *
 * Part 1: an "optional ops" matrix. Every control call is tried on every
 *         port (net_null, net_ring, net_tap) and the return code printed.
 *         -ENOTSUP is not a bug: it means "this PMD does not implement the
 *         eth_dev_ops entry", and your code must handle it.
 * Part 2: a walk through one net_tap port: MAC get/set/add, promiscuous
 *         mode with frames injected from the kernel side, MTU, link
 *         down/up, packet types, then basic stats and every xstat by name
 *         (per-queue counters only exist as xstats in 26.11).
 *
 * Run: ./port_ctl -l 0 --no-pci --no-huge -m 128 --file-prefix=ch12-ctl \
 *        --vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch12tap0
 */
#include <inttypes.h>
#include <rte_cycles.h>
#include "ch12_common.h"

#define TAPIF "ch12tap0"

static struct rte_mempool *mp;

/* Receive and free everything for ~ms milliseconds, return the count. */
static unsigned
drain(uint16_t port, unsigned ms)
{
	struct rte_mbuf *b[32];
	uint64_t end = rte_get_timer_cycles() + rte_get_timer_hz() * ms / 1000;
	unsigned n = 0;

	while (rte_get_timer_cycles() < end) {
		uint16_t k = rte_eth_rx_burst(port, 0, b, 32);
		n += k;
		rte_pktmbuf_free_bulk(b, k);
	}
	return n;
}

static void
matrix(void)
{
	static const char *cols[] = {
		"mac_set", "mac_add", "promisc_off", "allmulti_on", "set_mtu",
		"vlan_filt", "link_down", "ptypes", "set_ptypes", "rxq_info",
		"burst_mode", "xstats", "done_clean", "aggr_ports"
	};
	uint16_t port;
	unsigned i;

	printf("\n=== Part 1: optional ops matrix (started ports, 1 RX + 1 TX queue) ===\n");
	printf("%-12s", "port/pmd");
	for (i = 0; i < RTE_DIM(cols); i++)
		printf(" %-11s", cols[i]);
	printf("\n");

	RTE_ETH_FOREACH_DEV(port) {
		struct rte_eth_dev_info di;
		struct rte_ether_addr a = {{0x02, 0x12, 0, 0, 0, 0x10}};
		struct rte_ether_addr extra = {{0x02, 0x12, 0, 0, 0, 0x11}};
		struct rte_eth_rxq_info qi;
		struct rte_eth_burst_mode bm;
		uint32_t ptypes[64];
		int rc[RTE_DIM(cols)];

		struct rte_ether_addr orig;

		if (rte_eth_dev_info_get(port, &di) != 0)
			continue;
		rte_eth_macaddr_get(port, &orig);
		rc[0] = rte_eth_dev_default_mac_addr_set(port, &a);
		rc[1] = rte_eth_dev_mac_addr_add(port, &extra, 0);
		rc[2] = rte_eth_promiscuous_disable(port);
		rc[3] = rte_eth_allmulticast_enable(port);
		rc[4] = rte_eth_dev_set_mtu(port, 1400);
		rc[5] = rte_eth_dev_vlan_filter(port, 100, 1);
		rc[6] = rte_eth_dev_set_link_down(port);
		rte_eth_dev_set_link_up(port);
		rc[7] = rte_eth_dev_get_supported_ptypes(port, RTE_PTYPE_ALL_MASK,
							 ptypes, RTE_DIM(ptypes));
		rc[8] = rte_eth_dev_set_ptypes(port, RTE_PTYPE_L3_MASK, NULL, 0);
		rc[9] = rte_eth_rx_queue_info_get(port, 0, &qi);
		rc[10] = rte_eth_rx_burst_mode_get(port, 0, &bm);
		rc[11] = rte_eth_xstats_get(port, NULL, 0);	/* = count */
		rc[12] = rte_eth_tx_done_cleanup(port, 0, 0);
		rc[13] = rte_eth_dev_count_aggr_ports(port);

		/* restore what we changed so Part 2 starts clean */
		rte_eth_dev_default_mac_addr_set(port, &orig);
		rte_eth_dev_mac_addr_remove(port, &extra);
		rte_eth_promiscuous_enable(port);
		rte_eth_allmulticast_disable(port);
		rte_eth_dev_set_mtu(port, RTE_ETHER_MTU);

		printf("%u %-10s", port, di.driver_name + 4); /* skip "net_" */
		for (i = 0; i < RTE_DIM(cols); i++) {
			/* ptypes/xstats/aggr return a count, done_cleanup a number */
			if ((i == 7 || i == 11 || i == 13 || i == 12) && rc[i] >= 0)
				printf(" %-11d", rc[i]);
			else
				printf(" %-11s", rcname(rc[i]));
		}
		printf("\n");
	}
	printf("(numbers = counts: supported ptypes, xstats, freed mbufs, aggregated ports)\n");
}

static void
print_mac(const char *what, uint16_t port)
{
	struct rte_ether_addr m;
	char s[RTE_ETHER_ADDR_FMT_SIZE];

	rte_eth_macaddr_get(port, &m);
	rte_ether_format_addr(s, sizeof(s), &m);
	printf("  %-34s DPDK side %s | kernel %s address %s\n", what, s,
	       TAPIF, if_sysfs(TAPIF, "address"));
}

static void
tap_walk(uint16_t port)
{
	struct rte_ether_addr me, other = {{0x02, 0x12, 0xde, 0xad, 0xbe, 0xef}};
	struct rte_ether_addr bcast = {{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}};
	struct rte_ether_addr newmac = {{0x02, 0x12, 0x00, 0x00, 0x00, 0x01}};
	struct rte_eth_link link;
	char ls[RTE_ETH_LINK_MAX_STR_LEN];
	struct rte_eth_dev_info di;
	struct rte_eth_stats st;
	uint16_t mtu;
	uint32_t pt[64];
	int i, n, rc, on;

	printf("\n=== Part 2: net_tap walk-through (port %u, kernel side %s) ===\n",
	       port, TAPIF);

	/* --- MAC addresses --- */
	print_mac("initial MAC (random per run):", port);
	rc = rte_eth_dev_default_mac_addr_set(port, &newmac);
	print_mac(rc ? rcname(rc) : "after default_mac_addr_set:", port);

	/* --- promiscuous mode: the receive filter --- */
	rte_eth_macaddr_get(port, &me);
	printf("\n  promiscuous filter test (10 frames each, sent from the kernel side):\n");
	printf("  %-8s %-22s %-22s %-22s\n", "promisc", "dst = port MAC",
	       "dst = 02:12:de:ad:be:ef", "dst = broadcast");
	for (on = 1; on >= 0; on--) {
		unsigned got[3];

		if (on)
			rte_eth_promiscuous_enable(port);
		else
			rte_eth_promiscuous_disable(port);
		drain(port, 20);
		kernel_inject(TAPIF, &me, 10, 1);
		got[0] = drain(port, 50);
		kernel_inject(TAPIF, &other, 10, 1);
		got[1] = drain(port, 50);
		kernel_inject(TAPIF, &bcast, 10, 1);
		got[2] = drain(port, 50);
		printf("  %-8s %-22u %-22u %-22u   (kernel IFF_PROMISC=%s)\n",
		       on ? "on" : "off", got[0], got[1], got[2],
		       (strtoul(if_sysfs(TAPIF, "flags"), NULL, 16) & 0x100) ?
		       "1" : "0");
	}
	rte_eth_promiscuous_enable(port);

	/* --- MTU --- */
	if (rte_eth_dev_info_get(port, &di) != 0)
		return;
	rte_eth_dev_get_mtu(port, &mtu);
	printf("\n  MTU now %u (min_mtu %u, max_mtu %u, max_rx_pktlen %u)\n",
	       mtu, di.min_mtu, di.max_mtu, di.max_rx_pktlen);
	rc = rte_eth_dev_set_mtu(port, 9000);
	rte_eth_dev_get_mtu(port, &mtu);
	printf("  set_mtu(9000)  -> %-8s get_mtu=%u, kernel mtu=%s\n", rcname(rc),
	       mtu, if_sysfs(TAPIF, "mtu"));
	rc = rte_eth_dev_set_mtu(port, 40);
	printf("  set_mtu(40)    -> %-8s (below min_mtu)\n", rcname(rc));
	rc = rte_eth_dev_set_mtu(port, RTE_ETHER_MTU);
	printf("  set_mtu(1500)  -> %s\n", rcname(rc));
	printf("  mbuf data room in this pool: %u bytes -> a 9000-byte frame would need scatter RX\n",
	       rte_pktmbuf_data_room_size(mp) - RTE_PKTMBUF_HEADROOM);

	/* --- link control --- */
	rc = rte_eth_dev_set_link_down(port);
	if (rte_eth_link_get_nowait(port, &link) != 0)
		memset(&link, 0, sizeof(link));
	rte_eth_link_to_str(ls, sizeof(ls), &link);
	printf("\n  set_link_down -> %-6s link: %-28s kernel operstate=%s\n",
	       rcname(rc), ls, if_sysfs(TAPIF, "operstate"));
	rc = rte_eth_dev_set_link_up(port);
	if (rte_eth_link_get_nowait(port, &link) != 0)
		memset(&link, 0, sizeof(link));
	rte_eth_link_to_str(ls, sizeof(ls), &link);
	printf("  set_link_up   -> %-6s link: %-28s kernel operstate=%s\n",
	       rcname(rc), ls, if_sysfs(TAPIF, "operstate"));

	/* --- packet types the PMD can recognise --- */
	n = rte_eth_dev_get_supported_ptypes(port, RTE_PTYPE_ALL_MASK, pt, 64);
	printf("\n  supported ptypes (%d):", n);
	for (i = 0; i < n && i < 64; i++) {
		char name[64];

		rte_get_ptype_name(pt[i], name, sizeof(name));
		name[strcspn(name, " ")] = 0;	/* names end with a space */
		printf("%s%s", i % 6 ? ", " : "\n    ", name);
	}
	printf("\n");

	/* --- statistics: totals in rte_eth_stats, per-queue in xstats --- */
	rte_eth_stats_reset(port);
	kernel_inject(TAPIF, &me, 25, 1);
	drain(port, 50);
	rte_eth_stats_get(port, &st);
	printf("\n  rte_eth_stats after 25 injected frames:\n"
	       "    ipackets=%" PRIu64 " ibytes=%" PRIu64 " imissed=%" PRIu64
	       " ierrors=%" PRIu64 " rx_nombuf=%" PRIu64 "\n"
	       "    opackets=%" PRIu64 " obytes=%" PRIu64 " oerrors=%" PRIu64 "\n",
	       st.ipackets, st.ibytes, st.imissed, st.ierrors, st.rx_nombuf,
	       st.opackets, st.obytes, st.oerrors);

	n = rte_eth_xstats_get_names(port, NULL, 0);
	if (n > 0) {
		struct rte_eth_xstat_name *names = calloc(n, sizeof(*names));
		struct rte_eth_xstat *vals = calloc(n, sizeof(*vals));

		rte_eth_xstats_get_names(port, names, n);
		rte_eth_xstats_get(port, vals, n);
		printf("  all %d xstats (name = value):\n", n);
		for (i = 0; i < n; i++)
			printf("    [%2" PRIu64 "] %-20s = %" PRIu64 "\n", vals[i].id,
			       names[vals[i].id].name, vals[i].value);
		free(names);
		free(vals);
	}
	{
		uint64_t id, v;

		rc = rte_eth_xstats_get_id_by_name(port, "rx_q0_packets", &id);
		rte_eth_xstats_get_by_id(port, &id, &v, 1);
		printf("  by id: get_id_by_name(\"rx_q0_packets\") -> %s id=%" PRIu64
		       ", get_by_id -> %" PRIu64 "\n", rcname(rc), id, v);
		rc = rte_eth_xstats_get_id_by_name(port, "rx_q0_errors", &id);
		printf("  by id: get_id_by_name(\"rx_q0_errors\")  -> %s (removed in 26.11)\n",
		       rcname(rc));
	}
}

int
main(int argc, char **argv)
{
	uint16_t port, tap = RTE_MAX_ETHPORTS;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("ctl_pool", 4095, 64, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	if_quiet(TAPIF);
	RTE_ETH_FOREACH_DEV(port) {
		struct rte_eth_dev_info di;
		int rc;

		if (rte_eth_dev_info_get(port, &di) != 0)
			continue;
		if (strcmp(di.driver_name, "net_tap") == 0)
			tap = port;
		rc = ch12_port_init(port, 1, 1, mp, NULL, NULL, 1);
		if (rc < 0)
			rte_exit(EXIT_FAILURE, "port %u init: %s\n", port, rcname(rc));
	}
	matrix();
	if (tap != RTE_MAX_ETHPORTS)
		tap_walk(tap);

	RTE_ETH_FOREACH_DEV(port) {
		rte_eth_dev_stop(port);
		rte_eth_dev_close(port);
	}
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
