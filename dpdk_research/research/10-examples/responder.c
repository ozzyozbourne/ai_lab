/* Minimal user-space UDP/IP responder: ARP + ICMP echo + UDP echo. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <arpa/inet.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>
#include <rte_arp.h>
#include <rte_ip.h>
#include <rte_icmp.h>
#include <rte_udp.h>

#define BURST 32
static volatile int quit;
static struct rte_ether_addr my_mac;
static rte_be32_t my_ip;
static uint64_t n_arp, n_icmp, n_udp, n_drop;

static void sig(int s) { (void)s; quit = 1; }

/* returns 1 if mbuf was turned into a reply (to be transmitted) */
static int
handle_arp(struct rte_mbuf *m, struct rte_ether_hdr *eth)
{
	struct rte_arp_hdr *arp = (struct rte_arp_hdr *)(eth + 1);
	if (rte_pktmbuf_data_len(m) < sizeof(*eth) + sizeof(*arp)) return 0;
	if (arp->arp_opcode != rte_cpu_to_be_16(RTE_ARP_OP_REQUEST) ||
	    arp->arp_data.arp_tip != my_ip)
		return 0;
	arp->arp_opcode = rte_cpu_to_be_16(RTE_ARP_OP_REPLY);
	arp->arp_data.arp_tha = arp->arp_data.arp_sha;
	arp->arp_data.arp_tip = arp->arp_data.arp_sip;
	arp->arp_data.arp_sha = my_mac;
	arp->arp_data.arp_sip = my_ip;
	eth->dst_addr = eth->src_addr;
	eth->src_addr = my_mac;
	n_arp++;
	return 1;
}

static int
handle_ipv4(struct rte_mbuf *m, struct rte_ether_hdr *eth)
{
	struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
	uint32_t ihl = rte_ipv4_hdr_len(ip);
	rte_be32_t tmp;

	if (ip->dst_addr != my_ip) return 0;
	if (ip->fragment_offset & rte_cpu_to_be_16(RTE_IPV4_HDR_MF_FLAG | RTE_IPV4_HDR_OFFSET_MASK)) return 0;

	if (ip->next_proto_id == IPPROTO_ICMP) {
		struct rte_icmp_hdr *icmp = (struct rte_icmp_hdr *)((char *)ip + ihl);
		if (icmp->icmp_type != RTE_ICMP_TYPE_ECHO_REQUEST) return 0;
		icmp->icmp_type = RTE_ICMP_TYPE_ECHO_REPLY;
		icmp->icmp_cksum = 0;
		icmp->icmp_cksum = ~rte_raw_cksum(icmp,
			rte_be_to_cpu_16(ip->total_length) - ihl);
		n_icmp++;
	} else if (ip->next_proto_id == IPPROTO_UDP) {
		struct rte_udp_hdr *udp = (struct rte_udp_hdr *)((char *)ip + ihl);
		rte_be16_t p = udp->src_port;
		udp->src_port = udp->dst_port;
		udp->dst_port = p;
		n_udp++;
	} else
		return 0;

	tmp = ip->src_addr; ip->src_addr = ip->dst_addr; ip->dst_addr = tmp;
	ip->time_to_live = 64;
	ip->hdr_checksum = 0;
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	if (ip->next_proto_id == IPPROTO_UDP) {
		struct rte_udp_hdr *udp = (struct rte_udp_hdr *)((char *)ip + ihl);
		udp->dgram_cksum = 0;
		udp->dgram_cksum = rte_ipv4_udptcp_cksum(ip, udp);
	}
	eth->dst_addr = eth->src_addr;
	eth->src_addr = my_mac;
	return 1;
}

int main(int argc, char **argv)
{
	struct rte_eth_conf conf = {0};
	struct rte_mempool *mp;
	uint16_t port = 0;
	int ret = rte_eal_init(argc, argv);
	if (ret < 0) rte_exit(EXIT_FAILURE, "EAL init\n");
	argc -= ret; argv += ret;
	if (inet_pton(AF_INET, argc > 1 ? argv[1] : "10.10.0.2", &my_ip) != 1)
		rte_exit(EXIT_FAILURE, "bad IP\n");
	if (rte_eth_dev_count_avail() < 1) rte_exit(EXIT_FAILURE, "no port\n");

	mp = rte_pktmbuf_pool_create("pool", 4095, 256, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (!mp) rte_exit(EXIT_FAILURE, "pool\n");
	if (rte_eth_dev_configure(port, 1, 1, &conf) < 0 ||
	    rte_eth_rx_queue_setup(port, 0, 512, rte_eth_dev_socket_id(port), NULL, mp) < 0 ||
	    rte_eth_tx_queue_setup(port, 0, 512, rte_eth_dev_socket_id(port), NULL) < 0 ||
	    rte_eth_dev_start(port) < 0)
		rte_exit(EXIT_FAILURE, "port setup\n");
	rte_eth_macaddr_get(port, &my_mac);
	char macs[RTE_ETHER_ADDR_FMT_SIZE];
	rte_ether_format_addr(macs, sizeof(macs), &my_mac);
	printf("responder: port %u mac %s ip %s\n", port, macs, argc > 1 ? argv[1] : "10.10.0.2");
	fflush(stdout);
	signal(SIGINT, sig); signal(SIGTERM, sig);

	while (!quit) {
		struct rte_mbuf *rx[BURST], *tx[BURST];
		uint16_t nrx = rte_eth_rx_burst(port, 0, rx, BURST), ntx = 0, i;
		for (i = 0; i < nrx; i++) {
			struct rte_mbuf *m = rx[i];
			struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
			uint16_t et = rte_be_to_cpu_16(eth->ether_type);
			int reply = 0;
			if (et == RTE_ETHER_TYPE_ARP) reply = handle_arp(m, eth);
			else if (et == RTE_ETHER_TYPE_IPV4) reply = handle_ipv4(m, eth);
			if (reply) tx[ntx++] = m;
			else { rte_pktmbuf_free(m); n_drop++; }
		}
		if (ntx) {
			uint16_t sent = rte_eth_tx_burst(port, 0, tx, ntx);
			while (sent < ntx) rte_pktmbuf_free(tx[sent++]);
		}
	}
	printf("arp=%lu icmp=%lu udp=%lu ignored=%lu\n", n_arp, n_icmp, n_udp, n_drop);
	rte_eth_dev_stop(port);
	rte_eth_dev_close(port);
	rte_eal_cleanup();
	return 0;
}
