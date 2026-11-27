/* SPDX-License-Identifier: BSD-3-Clause
 *
 * ch15_common.h - small helpers shared by the chapter 15 programs.
 */
#ifndef CH15_COMMON_H
#define CH15_COMMON_H

#include <stdint.h>
#include <string.h>
#include <arpa/inet.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_udp.h>

/* Synthetic per-packet work: read the first header cache line (as a real
 * app would) and then burn `cycles` TSC cycles. The same function is used by
 * every execution model so that compare.sh compares like with like. */
static inline uint32_t
ch15_work(struct rte_mbuf *m, uint64_t cycles)
{
	const uint8_t *p = rte_pktmbuf_mtod(m, const uint8_t *);
	uint32_t acc = p[0] ^ p[12] ^ p[23];
	uint64_t end;

	if (cycles == 0)
		return acc;
	end = rte_rdtsc() + cycles;
	while (rte_rdtsc() < end)
		acc = acc * 31 + 7;
	return acc;
}

/* Our test frames (flows.py) are Ethernet/IPv4/UDP with payload
 * "CH15" + flow id (be16) + sequence (be32). Returns 0 and fills
 * flow/seq for one of them, -1 for anything else (e.g. kernel noise). */
static inline int
ch15_parse(struct rte_mbuf *m, uint16_t *flow, uint32_t *seq)
{
	const struct rte_ether_hdr *eth;
	const struct rte_ipv4_hdr *ip;
	const uint8_t *pl;
	uint16_t f;
	uint32_t s;

	if (m->data_len < sizeof(*eth) + sizeof(*ip) + sizeof(struct rte_udp_hdr) + 10)
		return -1;
	eth = rte_pktmbuf_mtod(m, const struct rte_ether_hdr *);
	if (eth->ether_type != rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4))
		return -1;
	ip = (const struct rte_ipv4_hdr *)(eth + 1);
	if (ip->next_proto_id != IPPROTO_UDP)
		return -1;
	pl = (const uint8_t *)ip + rte_ipv4_hdr_len(ip) + sizeof(struct rte_udp_hdr);
	if (memcmp(pl, "CH15", 4) != 0)
		return -1;
	memcpy(&f, pl + 4, 2);
	memcpy(&s, pl + 6, 4);
	*flow = ntohs(f);
	*seq = ntohl(s);
	return 0;
}

#endif
