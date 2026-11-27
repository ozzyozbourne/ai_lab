/* SPDX-License-Identifier: BSD-3-Clause
 * bonding_modes.c - the bonding PMD: one logical port over N member ports.
 *
 * Two members are net_tap ports (ch12tapb0/1) hot-plugged with
 * rte_dev_probe(). net_tap is used because the bond must be able to set the
 * members' MAC address (net_ring cannot: the bond then refuses to start)
 * and to see member link changes. Member opackets show exactly how the
 * bond spread the traffic. For each mode we create a bond
 * with rte_eth_bond_create(), add both members, start it, send 1000
 * packets of 16 UDP flows and print the per-member counts.
 * Active-backup then tries failover twice:
 *  - member link down: the bond does NOT notice. The bond polls a member's
 *    link only if the member lacks RTE_ETH_DEV_INTR_LSC; net_tap sets that
 *    flag but never raises the event, so the bond waits forever and keeps
 *    sending into a dead link (see drivers/net/bonding/rte_eth_bond_pmd.c);
 *  - member removal: immediate failover to the backup.
 * Last row: rte_eth_dev_count_aggr_ports(), the API for NICs that
 * aggregate ports in HARDWARE (0 on every software port here).
 *
 * Run: ./bonding_modes -l 0 --no-pci --no-huge -m 256 --file-prefix=ch12-bond
 */
#include <inttypes.h>
#include <rte_cycles.h>
#include <rte_eth_bond.h>
#include <rte_dev.h>
#include "ch12_common.h"

#define NPKT 1000
#define NFLOW 16

static struct rte_mempool *mp;
static uint16_t mem[2];

static int
on_lsc(uint16_t port, enum rte_eth_event_type ev, void *a, void *r)
{
	struct rte_eth_link l;

	(void)ev; (void)a; (void)r;
	if (rte_eth_link_get_nowait(port, &l) == 0)
		printf("    [event] LSC on bond port %u: link %s\n", port,
		       l.link_status ? "up" : "down");
	return 0;
}

/* Build NPKT Ethernet/IPv4/UDP frames, flow = i % NFLOW (src IP + port). */
static int
send_flows(uint16_t bond)
{
	struct rte_mbuf *m[32];
	int sent = 0, i = 0;

	while (i < NPKT) {
		int n = RTE_MIN(32, NPKT - i), j, k;

		if (rte_pktmbuf_alloc_bulk(mp, m, n) != 0)
			return -1;
		for (j = 0; j < n; j++, i++) {
			struct rte_ether_hdr *eh = (void *)rte_pktmbuf_append(m[j], 60);
			struct rte_ipv4_hdr *ip = (void *)(eh + 1);
			struct rte_udp_hdr *udp = (void *)(ip + 1);

			memset(eh, 0, 60);
			eh->dst_addr = (struct rte_ether_addr){{2, 0x12, 0, 0, 0, 2}};
			eh->src_addr = (struct rte_ether_addr){{2, 0x12, 0, 0, 0, 1}};
			eh->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);
			ip->version_ihl = RTE_IPV4_VHL_DEF;
			ip->total_length = rte_cpu_to_be_16(46);
			ip->time_to_live = 64;
			ip->next_proto_id = IPPROTO_UDP;
			ip->src_addr = rte_cpu_to_be_32(RTE_IPV4(10, 12, 1, i % NFLOW));
			ip->dst_addr = rte_cpu_to_be_32(RTE_IPV4(10, 12, 2, 1));
			udp->src_port = rte_cpu_to_be_16(1000 + i % NFLOW);
			udp->dst_port = rte_cpu_to_be_16(9);
		}
		k = rte_eth_tx_burst(bond, 0, m, n);
		sent += k;
		rte_pktmbuf_free_bulk(m + k, n - k);
	}
	return sent;
}

/* opackets per member since the last reset */
static void
count(const char *label, int sent)
{
	struct rte_eth_stats s[2];
	unsigned i;

	for (i = 0; i < 2; i++) {
		if (rte_eth_stats_get(mem[i], &s[i]) != 0)
			memset(&s[i], 0, sizeof(s[i]));
		rte_eth_stats_reset(mem[i]);
	}
	printf("  %-34s sent %4d  member0 %4" PRIu64 "  member1 %4" PRIu64 "\n",
	       label, sent, s[0].opackets, s[1].opackets);
}

static void
show_active(uint16_t bond)
{
	uint16_t act[4];
	int n = rte_eth_bond_active_members_get(bond, act, 4), i;

	printf("    active members:");
	for (i = 0; i < n; i++)
		printf(" %u", act[i]);
	printf("  (primary %d)\n", rte_eth_bond_primary_get(bond));
}

static int
make_bond(const char *name, uint8_t mode, int policy)
{
	int bond = rte_eth_bond_create(name, mode, rte_socket_id());
	unsigned i;

	if (bond < 0) {
		printf("bond_create(%s) -> %s\n", name, rcname(bond));
		return bond;
	}
	if (policy >= 0)
		rte_eth_bond_xmit_policy_set(bond, policy);
	for (i = 0; i < 2; i++)
		if (rte_eth_bond_member_add(bond, mem[i]) != 0)
			printf("member_add(%u) failed\n", mem[i]);
	rte_eth_dev_callback_register(bond, RTE_ETH_EVENT_INTR_LSC, on_lsc, NULL);
	if (ch12_port_init(bond, 1, 1, mp, &(struct rte_eth_conf){
			.intr_conf.lsc = 1 }, NULL, 1) < 0)
		printf("bond start failed\n");
	rte_delay_ms(50);	/* let link polling mark members up */
	for (i = 0; i < 2; i++)
		rte_eth_stats_reset(mem[i]);
	return bond;
}

static void
free_bond(const char *name, int bond)
{
	uint16_t m[4];
	int n, i;

	rte_eth_dev_stop(bond);
	rte_eth_dev_callback_unregister(bond, RTE_ETH_EVENT_INTR_LSC, on_lsc, NULL);
	/* bond_free refuses (-EBUSY) while the bond still has members */
	n = rte_eth_bond_members_get(bond, m, 4);
	for (i = 0; i < n; i++)
		rte_eth_bond_member_remove(bond, m[i]);
	if (rte_eth_bond_free(name) != 0)
		printf("bond_free(%s) failed\n", name);
}

int
main(int argc, char **argv)
{
	static const struct { uint8_t mode; int policy; const char *label; } modes[] = {
		{ BONDING_MODE_ROUND_ROBIN, -1, "mode 0 round-robin" },
		{ BONDING_MODE_BALANCE, BALANCE_XMIT_POLICY_LAYER2, "mode 2 balance, L2 hash" },
		{ BONDING_MODE_BALANCE, BALANCE_XMIT_POLICY_LAYER23, "mode 2 balance, L23 hash" },
		{ BONDING_MODE_BALANCE, BALANCE_XMIT_POLICY_LAYER34, "mode 2 balance, L34 hash" },
		{ BONDING_MODE_BROADCAST, -1, "mode 3 broadcast" },
		{ BONDING_MODE_TLB, -1, "mode 5 TLB (adaptive tx)" },
	};
	char name[32];
	unsigned i;
	int bond;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("bond_pool", 8191, 64, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (!mp)
		rte_exit(EXIT_FAILURE, "pool\n");
	for (i = 0; i < 2; i++) {
		char args[64], ifn[16];

		snprintf(ifn, sizeof(ifn), "ch12tapb%u", i);
		snprintf(args, sizeof(args), "net_tap1%u,iface=%s", i, ifn);
		snprintf(name, sizeof(name), "net_tap1%u", i);
		if (rte_dev_probe(args) != 0 ||
		    rte_eth_dev_get_port_by_name(name, &mem[i]) != 0)
			rte_exit(EXIT_FAILURE, "member %u\n", i);
		if_quiet(ifn);
	}
	printf("members: port %u (ch12tapb0) and port %u (ch12tapb1)\n",
	       mem[0], mem[1]);

	for (i = 0; i < RTE_DIM(modes); i++) {
		snprintf(name, sizeof(name), "net_bonding_m%u", i);
		bond = make_bond(name, modes[i].mode, modes[i].policy);
		if (bond < 0)
			continue;
		count(modes[i].label, send_flows(bond));
		free_bond(name, bond);
	}

	printf("\nmode 1 active-backup and failover:\n");
	bond = make_bond("net_bonding_ab", BONDING_MODE_ACTIVE_BACKUP, -1);
	show_active(bond);
	count("both members up", send_flows(bond));
	printf("    rte_eth_dev_set_link_down(member %u) (the primary's cable is pulled)\n",
	       mem[0]);
	rte_eth_dev_set_link_down(mem[0]);
	rte_delay_ms(200);
	{
		struct rte_eth_link l;

		if (rte_eth_link_get_nowait(mem[0], &l) == 0)
			printf("    member %u link is %s, but the bond still says:\n",
			       mem[0], l.link_status ? "up" : "down");
	}
	show_active(bond);
	count("primary link down (not noticed)", send_flows(bond));
	rte_eth_dev_set_link_up(mem[0]);
	rte_delay_ms(200);
	show_active(bond);
	printf("    rte_eth_bond_member_remove(member %u)\n", rte_eth_bond_primary_get(bond));
	rte_eth_bond_member_remove(bond, rte_eth_bond_primary_get(bond));
	show_active(bond);
	count("after removing the primary", send_flows(bond));

	printf("\nhardware aggregated ports (rte_eth_dev_count_aggr_ports):\n");
	printf("  member0 %d, member1 %d, bond %d  (0 = not a HW-aggregated port)\n",
	       rte_eth_dev_count_aggr_ports(mem[0]), rte_eth_dev_count_aggr_ports(mem[1]),
	       rte_eth_dev_count_aggr_ports(bond));
	printf("  rte_eth_dev_map_aggr_tx_affinity(bond, 0, 1) -> %s\n",
	       rcname(rte_eth_dev_map_aggr_tx_affinity(bond, 0, 1)));
	free_bond("net_bonding_ab", bond);

	for (i = 0; i < 2; i++) {
		rte_eth_dev_stop(mem[i]);
		rte_eth_dev_close(mem[i]);
	}
	printf("mbufs still in use: %u\n", rte_mempool_in_use_count(mp));
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
