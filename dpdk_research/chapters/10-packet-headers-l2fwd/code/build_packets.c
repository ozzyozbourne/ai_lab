/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 10: build_packets.c - craft frames byte by byte with lib/net.
 *
 * Builds eight frames in mbufs, fills every header with the lib/net structs,
 * computes every checksum with the lib/net helpers, and transmits them on
 * port 0 (net_pcap with tx_pcap=built.pcap), so verify.py can check them
 * independently:
 *   1 ARP request           5 VXLAN: outer IPv4/UDP:4789 + inner Eth/IPv4/UDP
 *   2 ICMP echo request     6 toy tunnel header (packed struct) over UDP:47000
 *   3 IPv4/UDP              7 IPv4/UDP + 802.1Q tag inserted by rte_vlan_insert
 *   4 IPv6/UDP (flow label) 8 QinQ: rte_vlan_insert + rte_vlan_insert_tpid
 * For each frame it also prints rte_net_get_ptype() and the Ethernet CRC32
 * from rte_net_crc_calc() (scalar and SIMD); the CRCs go to built.crc.
 *
 *   ./build_packets -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-build \
 *       --vdev=net_pcap0,rx_pcap=empty.pcap,tx_pcap=built.pcap
 *   python3 -I verify.py built.pcap built.crc
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdalign.h>
#include <stddef.h>
#include <netinet/in.h>

#include <rte_eal.h>
#include <rte_common.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>
#include <rte_arp.h>
#include <rte_ip4.h>
#include <rte_ip6.h>
#include <rte_udp.h>
#include <rte_icmp.h>
#include <rte_vxlan.h>
#include <rte_net.h>
#include <rte_net_crc.h>
#include <rte_byteorder.h>

#include "ch10_port.h"

/*
 * A custom 8-byte tunnel header that rides on UDP port 47000.
 * 'session' starts at byte 2, so without packing the compiler would insert
 * 2 bytes of padding before it (and 2 after seq) and the struct would be 12
 * bytes, not 8. DPDK 26.11 spells packing as __rte_packed_begin before the
 * tag and __rte_packed_end after the closing brace (the old trailing
 * __rte_packed was removed; see packed_old.c).
 */
struct __rte_packed_begin toy_tun_hdr {
	uint8_t    ver;      /* 1 */
	uint8_t    flags;    /* bit 0: "has seq" */
	rte_be32_t session;  /* offset 2: NOT 4-byte aligned */
	rte_be16_t seq;      /* offset 6 */
} __rte_packed_end;

struct toy_unpacked {        /* the same fields without packing */
	uint8_t    ver;
	uint8_t    flags;
	rte_be32_t session;
	rte_be16_t seq;
};

#define TOY_UDP_PORT 47000
#define NB_FRAMES 8

static const struct rte_ether_addr mac_a = {{0x02, 0, 0, 0, 0, 0x01}};
static const struct rte_ether_addr mac_b = {{0x02, 0, 0, 0, 0, 0x02}};
static const struct rte_ipv6_addr ip6_src = RTE_IPV6(0xfd00, 0x10, 0, 0, 0, 0, 0, 1);
static const struct rte_ipv6_addr ip6_dst = RTE_IPV6(0xfd00, 0x10, 0, 0, 0, 0, 0, 2);
static const char payload[] = "hello from ch10";   /* 15 bytes + NUL, we send 15 */
#define PLEN (sizeof(payload) - 1)

/* Allocate an mbuf with 'len' zeroed data bytes. */
static struct rte_mbuf *
new_frame(struct rte_mempool *pool, uint16_t len, uint8_t **data)
{
	struct rte_mbuf *m = rte_pktmbuf_alloc(pool);

	if (m == NULL)
		rte_exit(EXIT_FAILURE, "mbuf alloc failed\n");
	*data = (uint8_t *)rte_pktmbuf_append(m, len);
	if (*data == NULL)
		rte_exit(EXIT_FAILURE, "append %u failed\n", len);
	memset(*data, 0, len);
	return m;
}

static void
fill_eth(struct rte_ether_hdr *eth, const struct rte_ether_addr *dst,
	 const struct rte_ether_addr *src, uint16_t type)
{
	rte_ether_addr_copy(dst, &eth->dst_addr);
	rte_ether_addr_copy(src, &eth->src_addr);
	eth->ether_type = rte_cpu_to_be_16(type);     /* host -> network */
}

/* IPv4 header without options; l4_len = bytes after the IP header. */
static void
fill_ipv4(struct rte_ipv4_hdr *ip, uint32_t src, uint32_t dst, uint8_t proto,
	  uint16_t l4_len)
{
	ip->version_ihl = RTE_IPV4_VHL_DEF;          /* 0x45: v4, IHL 5 */
	ip->type_of_service = 0;
	ip->total_length = rte_cpu_to_be_16(sizeof(*ip) + l4_len);
	ip->packet_id = RTE_BE16(1);                  /* compile-time constant */
	ip->fragment_offset = RTE_BE16(RTE_IPV4_HDR_DF_FLAG);
	ip->time_to_live = 64;
	ip->next_proto_id = proto;
	ip->src_addr = rte_cpu_to_be_32(src);         /* RTE_IPV4() is host order */
	ip->dst_addr = rte_cpu_to_be_32(dst);
	ip->hdr_checksum = 0;                         /* MUST be 0 first */
	ip->hdr_checksum = rte_ipv4_cksum(ip);        /* stored as returned */
}

/* UDP header + payload; computes the checksum over the IPv4 pseudo-header. */
static void
fill_udp4(const struct rte_ipv4_hdr *ip, struct rte_udp_hdr *udp, uint16_t sport,
	  uint16_t dport, const void *data, uint16_t dlen, int with_cksum)
{
	udp->src_port = rte_cpu_to_be_16(sport);
	udp->dst_port = rte_cpu_to_be_16(dport);
	udp->dgram_len = rte_cpu_to_be_16(sizeof(*udp) + dlen);
	memcpy(udp + 1, data, dlen);
	udp->dgram_cksum = 0;
	if (with_cksum)
		udp->dgram_cksum = rte_ipv4_udptcp_cksum(ip, udp);
}

/* Frame 3 (and the base of 7 and 8): Ether / IPv4 / UDP / payload. */
static struct rte_mbuf *
build_udp4(struct rte_mempool *pool, uint16_t sport, uint16_t dport)
{
	uint8_t *p;
	uint16_t l4 = sizeof(struct rte_udp_hdr) + PLEN;
	struct rte_mbuf *m = new_frame(pool, sizeof(struct rte_ether_hdr) +
				       sizeof(struct rte_ipv4_hdr) + l4, &p);
	struct rte_ether_hdr *eth = (struct rte_ether_hdr *)p;
	struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
	struct rte_udp_hdr *udp = (struct rte_udp_hdr *)(ip + 1);

	fill_eth(eth, &mac_b, &mac_a, RTE_ETHER_TYPE_IPV4);
	fill_ipv4(ip, RTE_IPV4(10, 10, 0, 1), RTE_IPV4(10, 10, 0, 2), IPPROTO_UDP, l4);
	fill_udp4(ip, udp, sport, dport, payload, PLEN, 1);
	m->l2_len = sizeof(*eth);
	m->l3_len = sizeof(*ip);
	return m;
}

/* Frame 1: ARP request, "who has 10.10.0.2? tell 10.10.0.1". */
static struct rte_mbuf *
build_arp(struct rte_mempool *pool)
{
	uint8_t *p;
	struct rte_mbuf *m = new_frame(pool, sizeof(struct rte_ether_hdr) +
				       sizeof(struct rte_arp_hdr), &p);
	struct rte_ether_hdr *eth = (struct rte_ether_hdr *)p;
	struct rte_arp_hdr *arp = (struct rte_arp_hdr *)(eth + 1);
	struct rte_ether_addr bcast;

	memset(&bcast, 0xff, sizeof(bcast));
	fill_eth(eth, &bcast, &mac_a, RTE_ETHER_TYPE_ARP);
	arp->arp_hardware = RTE_BE16(RTE_ARP_HRD_ETHER);
	arp->arp_protocol = RTE_BE16(RTE_ETHER_TYPE_IPV4);
	arp->arp_hlen = RTE_ETHER_ADDR_LEN;
	arp->arp_plen = 4;
	arp->arp_opcode = RTE_BE16(RTE_ARP_OP_REQUEST);
	rte_ether_addr_copy(&mac_a, &arp->arp_data.arp_sha);
	arp->arp_data.arp_sip = RTE_BE32(RTE_IPV4(10, 10, 0, 1));
	/* arp_tha stays 00:00:00:00:00:00: that is what we are asking for */
	arp->arp_data.arp_tip = RTE_BE32(RTE_IPV4(10, 10, 0, 2));
	return m;
}

/* Frame 2: ICMP echo request. ICMP has no pseudo-header. */
static struct rte_mbuf *
build_icmp(struct rte_mempool *pool)
{
	uint8_t *p;
	uint16_t l4 = sizeof(struct rte_icmp_hdr) + PLEN;
	struct rte_mbuf *m = new_frame(pool, sizeof(struct rte_ether_hdr) +
				       sizeof(struct rte_ipv4_hdr) + l4, &p);
	struct rte_ether_hdr *eth = (struct rte_ether_hdr *)p;
	struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
	struct rte_icmp_hdr *ic = (struct rte_icmp_hdr *)(ip + 1);

	fill_eth(eth, &mac_b, &mac_a, RTE_ETHER_TYPE_IPV4);
	fill_ipv4(ip, RTE_IPV4(10, 10, 0, 1), RTE_IPV4(10, 10, 0, 2), IPPROTO_ICMP, l4);
	ic->icmp_type = RTE_ICMP_TYPE_ECHO_REQUEST;   /* 26.11 name */
	ic->icmp_code = 0;
	ic->icmp_ident = RTE_BE16(0x1234);
	ic->icmp_seq_nb = RTE_BE16(1);
	memcpy(ic + 1, payload, PLEN);
	ic->icmp_cksum = 0;
	ic->icmp_cksum = (uint16_t)~rte_raw_cksum(ic, l4);
	return m;
}

/* Frame 4: IPv6/UDP with traffic class 0xb8 and flow label 0xbeef1. */
static struct rte_mbuf *
build_udp6(struct rte_mempool *pool)
{
	uint8_t *p;
	uint16_t l4 = sizeof(struct rte_udp_hdr) + PLEN;
	struct rte_mbuf *m = new_frame(pool, sizeof(struct rte_ether_hdr) +
				       sizeof(struct rte_ipv6_hdr) + l4, &p);
	struct rte_ether_hdr *eth = (struct rte_ether_hdr *)p;
	struct rte_ipv6_hdr *ip6 = (struct rte_ipv6_hdr *)(eth + 1);
	struct rte_udp_hdr *udp = (struct rte_udp_hdr *)(ip6 + 1);
	uint32_t tc = 0xb8, flow = 0xbeef1;

	fill_eth(eth, &mac_b, &mac_a, RTE_ETHER_TYPE_IPV6);
	/* 26.11: no bitfields. Build the host-order word, then swap once. */
	ip6->vtc_flow = rte_cpu_to_be_32((6u << 28) |
		((tc << RTE_IPV6_HDR_TC_SHIFT) & RTE_IPV6_HDR_TC_MASK) |
		(flow & RTE_IPV6_HDR_FL_MASK));
	ip6->payload_len = rte_cpu_to_be_16(l4);
	ip6->proto = IPPROTO_UDP;
	ip6->hop_limits = 64;
	ip6->src_addr = ip6_src;                      /* struct copy */
	ip6->dst_addr = ip6_dst;
	udp->src_port = RTE_BE16(5353);
	udp->dst_port = RTE_BE16(5353);
	udp->dgram_len = rte_cpu_to_be_16(l4);
	memcpy(udp + 1, payload, PLEN);
	udp->dgram_cksum = 0;
	udp->dgram_cksum = rte_ipv6_udptcp_cksum(ip6, udp); /* mandatory in v6 */
	return m;
}

/* Frame 5: VXLAN. Outer Eth/IPv4/UDP(4789)/VXLAN, inner Eth/IPv4/UDP. */
static struct rte_mbuf *
build_vxlan(struct rte_mempool *pool, uint32_t vni)
{
	uint8_t *p;
	const uint16_t inner_l4 = sizeof(struct rte_udp_hdr) + PLEN;
	const uint16_t inner_len = sizeof(struct rte_ether_hdr) +
				   sizeof(struct rte_ipv4_hdr) + inner_l4;
	const uint16_t outer_l4 = sizeof(struct rte_udp_hdr) +
				  sizeof(struct rte_vxlan_hdr) + inner_len;
	struct rte_mbuf *m = new_frame(pool, sizeof(struct rte_ether_hdr) +
				       sizeof(struct rte_ipv4_hdr) + outer_l4, &p);
	struct rte_ether_hdr *oeth = (struct rte_ether_hdr *)p;
	struct rte_ipv4_hdr *oip = (struct rte_ipv4_hdr *)(oeth + 1);
	struct rte_udp_hdr *oudp = (struct rte_udp_hdr *)(oip + 1);
	struct rte_vxlan_hdr *vx = (struct rte_vxlan_hdr *)(oudp + 1);
	struct rte_ether_hdr *ieth = (struct rte_ether_hdr *)(vx + 1);
	struct rte_ipv4_hdr *iip = (struct rte_ipv4_hdr *)(ieth + 1);
	struct rte_udp_hdr *iudp = (struct rte_udp_hdr *)(iip + 1);
	static const struct rte_ether_addr vm_a = {{0x02, 0, 0, 0, 0, 0xaa}};
	static const struct rte_ether_addr vm_b = {{0x02, 0, 0, 0, 0, 0xbb}};

	/* inside out: the inner frame is what the "VM" sent */
	fill_eth(ieth, &vm_b, &vm_a, RTE_ETHER_TYPE_IPV4);
	fill_ipv4(iip, RTE_IPV4(192, 168, 50, 1), RTE_IPV4(192, 168, 50, 2),
		  IPPROTO_UDP, inner_l4);
	fill_udp4(iip, iudp, 1111, 2222, payload, PLEN, 1);

	/* VXLAN header: I flag (0x08 in the first byte) + 24-bit VNI */
	vx->vx_flags = RTE_BE32(0x08000000);
	vx->vx_vni = rte_cpu_to_be_32(vni << 8);

	/* outer: VTEP 10.10.0.1 -> 10.10.0.2. The source port is a hash of the
	 * inner flow so that RSS on the receiver spreads tunnels (ch15).
	 * RFC 7348: the outer UDP checksum SHOULD be 0 over IPv4. */
	fill_eth(oeth, &mac_b, &mac_a, RTE_ETHER_TYPE_IPV4);
	fill_ipv4(oip, RTE_IPV4(10, 10, 0, 1), RTE_IPV4(10, 10, 0, 2),
		  IPPROTO_UDP, outer_l4);
	oudp->src_port = rte_cpu_to_be_16(49152 + (1111 ^ 2222) % 16384);
	oudp->dst_port = RTE_BE16(RTE_VXLAN_DEFAULT_PORT);
	oudp->dgram_len = rte_cpu_to_be_16(outer_l4);
	oudp->dgram_cksum = 0;
	return m;
}

/* Frame 6: our own tunnel header, defined as a packed struct. */
static struct rte_mbuf *
build_toy(struct rte_mempool *pool)
{
	uint8_t *p;
	const uint16_t dlen = sizeof(struct toy_tun_hdr) + PLEN;
	uint8_t inner[sizeof(struct toy_tun_hdr) + PLEN];
	struct toy_tun_hdr *t = (struct toy_tun_hdr *)inner;
	struct rte_mbuf *m = new_frame(pool, sizeof(struct rte_ether_hdr) +
				       sizeof(struct rte_ipv4_hdr) +
				       sizeof(struct rte_udp_hdr) + dlen, &p);
	struct rte_ether_hdr *eth = (struct rte_ether_hdr *)p;
	struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
	struct rte_udp_hdr *udp = (struct rte_udp_hdr *)(ip + 1);
	const struct toy_tun_hdr *wire;
	const unaligned_uint32_t *sess;

	t->ver = 1;
	t->flags = 0x01;
	t->session = rte_cpu_to_be_32(0xc0ffee01);   /* compiler emits a safe store */
	t->seq = rte_cpu_to_be_16(7);
	memcpy(inner + sizeof(*t), payload, PLEN);

	fill_eth(eth, &mac_b, &mac_a, RTE_ETHER_TYPE_IPV4);
	fill_ipv4(ip, RTE_IPV4(10, 10, 0, 1), RTE_IPV4(10, 10, 0, 2), IPPROTO_UDP,
		  sizeof(*udp) + dlen);
	fill_udp4(ip, udp, 40000, TOY_UDP_PORT, inner, dlen, 1);

	/* Read it back from the frame through an unaligned pointer type. */
	wire = (const struct toy_tun_hdr *)(udp + 1);
	sess = (const unaligned_uint32_t *)((const uint8_t *)wire +
					    offsetof(struct toy_tun_hdr, session));
	printf("toy header: sizeof packed=%zu unpacked=%zu, offsetof(session)=%zu\n",
	       sizeof(struct toy_tun_hdr), sizeof(struct toy_unpacked),
	       offsetof(struct toy_tun_hdr, session));
	printf("toy header: alignof(uint32_t)=%zu alignof(unaligned_uint32_t)=%zu, "
	       "session at frame offset %zu, read back 0x%08x\n",
	       alignof(uint32_t), alignof(unaligned_uint32_t),
	       (size_t)((const uint8_t *)sess - p), rte_be_to_cpu_32(*sess));
	return m;
}

static void
print_frame(int idx, const char *what, struct rte_mbuf *m,
	    const struct rte_net_crc *crc_scalar, const struct rte_net_crc *crc_simd,
	    FILE *crcf)
{
	struct rte_net_hdr_lens hl = {0};
	char name[256];
	const void *d = rte_pktmbuf_mtod(m, const void *);
	uint32_t ptype = rte_net_get_ptype(m, &hl, RTE_PTYPE_ALL_MASK);
	uint32_t c1 = rte_net_crc_calc(crc_scalar, d, rte_pktmbuf_data_len(m));
	uint32_t c2 = rte_net_crc_calc(crc_simd, d, rte_pktmbuf_data_len(m));

	rte_get_ptype_name(ptype, name, sizeof(name));
	printf("%d %-28s len=%-3u l2_len=%-2u crc32=0x%08x%s  %s\n", idx, what,
	       rte_pktmbuf_pkt_len(m), m->l2_len, c1,
	       c1 == c2 ? "" : " (SIMD MISMATCH!)", name);
	fprintf(crcf, "0x%08x\n", c1);
}

int
main(int argc, char **argv)
{
	struct rte_mempool *pool;
	struct rte_mbuf *f[NB_FRAMES];
	struct rte_net_crc *crc_scalar, *crc_simd;
	const char *names[NB_FRAMES] = {
		"ARP request", "ICMP echo request", "IPv4/UDP", "IPv6/UDP flow=0xbeef1",
		"VXLAN vni=5000", "toy tunnel (UDP 47000)", "802.1Q vlan=100",
		"QinQ s-vlan=200 c-vlan=100" };
	FILE *crcf;
	uint16_t sent;
	int i, ret;

	/* Fails at COMPILE time if someone removes the packing. */
	RTE_BUILD_BUG_ON(sizeof(struct toy_tun_hdr) != 8);

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (rte_eth_dev_count_avail() < 1)
		rte_exit(EXIT_FAILURE, "need --vdev=net_pcap0,rx_pcap=empty.pcap,tx_pcap=built.pcap\n");
	pool = rte_pktmbuf_pool_create("ch10_build", 1023, 32, 0,
				       RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (pool == NULL)
		rte_exit(EXIT_FAILURE, "mbuf pool: %s\n", rte_strerror(rte_errno));
	if (ch10_port_init(0, pool) < 0)
		rte_exit(EXIT_FAILURE, "port 0 init failed\n");

	/* CRC contexts: the library falls back if the CPU lacks the SIMD path. */
	crc_scalar = rte_net_crc_set_alg(RTE_NET_CRC_SCALAR, RTE_NET_CRC32_ETH);
	crc_simd = rte_net_crc_set_alg(RTE_NET_CRC_AVX512, RTE_NET_CRC32_ETH);
	if (crc_scalar == NULL || crc_simd == NULL)
		rte_exit(EXIT_FAILURE, "rte_net_crc_set_alg failed\n");

	f[0] = build_arp(pool);
	f[1] = build_icmp(pool);
	f[2] = build_udp4(pool, 1000, 2000);
	f[3] = build_udp6(pool);
	f[4] = build_vxlan(pool, 5000);
	f[5] = build_toy(pool);

	/* 802.1Q: rte_vlan_insert() reads the TCI from m->vlan_tci, prepends
	 * 4 bytes in the headroom, moves the MACs and bumps m->l2_len. */
	f[6] = build_udp4(pool, 1001, 2001);
	f[6]->vlan_tci = (5 << 13) | 100;             /* PCP 5, VID 100 */
	if (rte_vlan_insert(&f[6]) != 0)
		rte_exit(EXIT_FAILURE, "rte_vlan_insert failed\n");

	/* QinQ: insert the inner C-tag first (0x8100), then the outer S-tag
	 * with TPID 0x88a8 via rte_vlan_insert_tpid() (experimental, 26.11). */
	f[7] = build_udp4(pool, 1002, 2002);
	f[7]->vlan_tci = 100;
	ret = rte_vlan_insert(&f[7]);
	f[7]->vlan_tci = 200;
	if (ret != 0 || rte_vlan_insert_tpid(&f[7], RTE_ETHER_TYPE_QINQ) != 0)
		rte_exit(EXIT_FAILURE, "QinQ insert failed\n");

	crcf = fopen("built.crc", "w");
	if (crcf == NULL)
		rte_exit(EXIT_FAILURE, "cannot write built.crc\n");
	for (i = 0; i < NB_FRAMES; i++)
		print_frame(i + 1, names[i], f[i], crc_scalar, crc_simd, crcf);
	fclose(crcf);

	/* rte_vlan_strip() is the inverse: pop the tag into m->vlan_tci. */
	{
		struct rte_mbuf *c = build_udp4(pool, 1, 2);
		uint16_t before;

		c->vlan_tci = 42;
		rte_vlan_insert(&c);
		before = rte_pktmbuf_data_len(c);
		ret = rte_vlan_strip(c);
		printf("rte_vlan_strip: ret=%d len %u -> %u vlan_tci=%u ol_flags has RX_VLAN_STRIPPED=%d\n",
		       ret, before, rte_pktmbuf_data_len(c), c->vlan_tci,
		       !!(c->ol_flags & RTE_MBUF_F_RX_VLAN_STRIPPED));
		rte_pktmbuf_free(c);
	}

	sent = rte_eth_tx_burst(0, 0, f, NB_FRAMES);
	printf("sent %u of %d frames to port 0\n", sent, NB_FRAMES);
	for (i = sent; i < NB_FRAMES; i++)
		rte_pktmbuf_free(f[i]);

	rte_net_crc_free(crc_scalar);
	rte_net_crc_free(crc_simd);
	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);     /* net_pcap flushes and closes built.pcap */
	rte_eal_cleanup();
	return 0;
}
