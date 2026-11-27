/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: ch13_common.h - small helpers shared by the chapter programs.
 *
 *   ch13_port_init()   chapter 8's lifecycle: configure, 1 RX + 1 TX queue, start
 *   ch13_make_udp()    fill an mbuf with one IPv4/UDP frame of a given length
 *   ch13_inject()      send n frames on a port (on net_ring they come back on RX)
 *   kernel_inject()    send raw frames from the KERNEL side of a tap/veth
 *   ch13_quit          set by SIGINT/SIGTERM; every loop polls it
 *
 * Nothing here is new API: it is the boiler-plate from chapters 7, 8 and 10
 * so that the programs of this chapter can focus on observing and debugging.
 */
#ifndef CH13_COMMON_H
#define CH13_COMMON_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <signal.h>
#include <unistd.h>
#include <inttypes.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>

#include <rte_eal.h>
#include <rte_common.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>
#include <rte_ip4.h>
#include <rte_udp.h>
#include <rte_errno.h>
#include <rte_stdatomic.h>

static volatile bool ch13_quit;

static void __rte_unused
ch13_on_signal(int sig)
{
	(void)sig;
	ch13_quit = true;
}

static inline void __rte_unused
ch13_signals(void)
{
	signal(SIGINT, ch13_on_signal);
	signal(SIGTERM, ch13_on_signal);
}

/* configure + 1 RX/TX queue + start. conf may be NULL (all defaults). */
static inline int __rte_unused
ch13_port_init(uint16_t port, struct rte_mempool *pool,
	       const struct rte_eth_conf *conf, uint16_t nb_desc)
{
	struct rte_eth_conf def = {0};
	int ret;

	ret = rte_eth_dev_configure(port, 1, 1, conf ? conf : &def);
	if (ret < 0)
		return ret;
	ret = rte_eth_rx_queue_setup(port, 0, nb_desc,
			rte_eth_dev_socket_id(port), NULL, pool);
	if (ret < 0)
		return ret;
	ret = rte_eth_tx_queue_setup(port, 0, nb_desc,
			rte_eth_dev_socket_id(port), NULL);
	if (ret < 0)
		return ret;
	return rte_eth_dev_start(port);
}

/* Build one IPv4/UDP frame of 'len' bytes (>= 60) into m. */
static inline int __rte_unused
ch13_make_udp(struct rte_mbuf *m, uint16_t len, uint32_t seq)
{
	struct rte_ether_hdr *eth;
	struct rte_ipv4_hdr *ip;
	struct rte_udp_hdr *udp;
	uint16_t hl = sizeof(*eth) + sizeof(*ip) + sizeof(*udp);

	if (len < 60)
		len = 60;
	eth = (struct rte_ether_hdr *)rte_pktmbuf_append(m, len);
	if (eth == NULL)
		return -1;
	memset(eth, 0, hl);
	ip = (struct rte_ipv4_hdr *)(eth + 1);
	udp = (struct rte_udp_hdr *)(ip + 1);
	memcpy(eth->dst_addr.addr_bytes, "\x02\x13\x00\x00\x00\x02", 6);
	memcpy(eth->src_addr.addr_bytes, "\x02\x13\x00\x00\x00\x01", 6);
	eth->ether_type = RTE_BE16(RTE_ETHER_TYPE_IPV4);
	ip->version_ihl = RTE_IPV4_VHL_DEF;
	ip->total_length = rte_cpu_to_be_16(len - sizeof(*eth));
	ip->time_to_live = 64;
	ip->next_proto_id = IPPROTO_UDP;
	ip->src_addr = RTE_BE32(RTE_IPV4(10, 13, 1, 1));
	ip->dst_addr = RTE_BE32(RTE_IPV4(10, 13, 2, 1));
	ip->hdr_checksum = rte_ipv4_cksum(ip);
	udp->src_port = rte_cpu_to_be_16(1000 + (seq & 0xff));
	udp->dst_port = RTE_BE16(9);
	udp->dgram_len = rte_cpu_to_be_16(len - sizeof(*eth) - sizeof(*ip));
	return 0;
}

/* Send n frames of len bytes on (port, queue 0). Returns frames accepted. */
static inline unsigned int __rte_unused
ch13_inject(uint16_t port, struct rte_mempool *pool, unsigned int n, uint16_t len)
{
	unsigned int i, done = 0;

	for (i = 0; i < n; i++) {
		struct rte_mbuf *m = rte_pktmbuf_alloc(pool);

		if (m == NULL)
			break;
		if (ch13_make_udp(m, len, i) < 0 ||
		    rte_eth_tx_burst(port, 0, &m, 1) != 1) {
			rte_pktmbuf_free(m);
			continue;
		}
		done++;
	}
	return done;
}

/* Send n raw frames of len bytes to dst from the kernel side of ifname
 * (for net_tap that is "the wire"). Returns frames sent or -1. */
static inline int __rte_unused
kernel_inject(const char *ifname, const struct rte_ether_addr *dst,
	      int n, int len)
{
	struct sockaddr_ll sll = {0};
	static unsigned char fr[9216];
	int s, i, sent = 0;

	if (len < 60)
		len = 60;
	if (len > (int)sizeof(fr))
		len = sizeof(fr);
	s = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	if (s < 0)
		return -1;
	sll.sll_family = AF_PACKET;
	sll.sll_ifindex = if_nametoindex(ifname);
	sll.sll_halen = 6;
	memcpy(sll.sll_addr, dst->addr_bytes, 6);
	memset(fr, 0, sizeof(fr));
	for (i = 0; i < n; i++) {
		struct rte_ether_hdr *eh = (void *)fr;

		eh->dst_addr = *dst;
		memcpy(eh->src_addr.addr_bytes, "\x02\x13\xee\x00\x00\x01", 6);
		eh->ether_type = rte_cpu_to_be_16(0x88b5); /* local experimental */
		if (sendto(s, fr, len, 0, (void *)&sll, sizeof(sll)) == len)
			sent++;
	}
	close(s);
	return sent;
}

#endif /* CH13_COMMON_H */
