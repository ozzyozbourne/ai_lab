/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 10, exercise 1 solution: parse_vlan.c = parse_pcap.c + VLAN/QinQ.
 * Only parse_ether() differs: it walks up to two tags (0x88a8/0x9100 S-tag,
 * 0x8100 C-tag) and prints both VLAN ids.
 *
 * Original description:
 *
 * Reads every frame from port 0 (normally net_pcap with rx_pcap=mixed.pcap),
 * parses Ethernet / one 802.1Q tag / ARP / IPv4 / IPv6 (+ extension headers)
 * / UDP / TCP / ICMP / VXLAN by hand, checks every length against the packet
 * before touching it, verifies checksums, and prints one line per frame.
 * Then it asks the library parser rte_net_get_ptype() for its opinion on the
 * same frame and prints the packet type name and header lengths.
 *
 * Finally it builds a two-segment mbuf whose IPv4 header is split across the
 * two segments, to show why rte_pktmbuf_read() is the safe way to get a
 * header.
 *
 *   ./parse_pcap -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-parse \
 *       --vdev=net_pcap0,rx_pcap=mixed.pcap,tx_pcap=/dev/null
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <netinet/in.h>

#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mbuf_ptype.h>
#include <rte_ether.h>
#include <rte_arp.h>
#include <rte_ip4.h>
#include <rte_ip6.h>
#include <rte_udp.h>
#include <rte_tcp.h>
#include <rte_icmp.h>
#include <rte_vxlan.h>
#include <rte_net.h>
#include <rte_cksum.h>

#include "ch10_port.h"

/* ---- a tiny line builder so each frame prints on one line ---- */
static char line[512];
static size_t line_len;

static void
out(const char *fmt, ...)
{
	va_list ap;

	if (line_len >= sizeof(line))
		return;
	va_start(ap, fmt);
	line_len += vsnprintf(line + line_len, sizeof(line) - line_len, fmt, ap);
	va_end(ap);
	if (line_len > sizeof(line))
		line_len = sizeof(line);
}

/*
 * THE one rule of safe parsing: never dereference a header before you know
 * the packet really contains it.  rte_pktmbuf_read() does the check for us:
 *  - if [off, off+len) lies inside the first segment it returns a pointer
 *    straight into the mbuf data (no copy, the fast path);
 *  - if the bytes exist but span segments it copies them into 'buf' and
 *    returns buf;
 *  - if the packet is shorter than off+len it returns NULL.
 * Always pass a buffer at least 'len' bytes long.
 */
#define HDR(m, off, type, buf) \
	((const type *)rte_pktmbuf_read((m), (off), sizeof(type), (buf)))

/* A scratch area big enough for a whole L4 segment when it must be copied. */
static uint8_t l4_copy[2048];

static void
ip4_str(rte_be32_t a, char *s, size_t n)
{
	uint32_t h = rte_be_to_cpu_32(a);   /* network -> host order first */

	snprintf(s, n, "%u.%u.%u.%u", h >> 24, (h >> 16) & 0xff,
		 (h >> 8) & 0xff, h & 0xff);
}

static int parse_ether(const struct rte_mbuf *m, uint32_t off, int depth);

/* L4 for both IP versions. 'ip4'/'ip6' says which pseudo-header to use. */
static void
parse_l4(const struct rte_mbuf *m, uint32_t off, uint32_t l4_len, uint8_t proto,
	 const struct rte_ipv4_hdr *ip4, const struct rte_ipv6_hdr *ip6,
	 int depth)
{
	const void *l4;

	switch (proto) {
	case IPPROTO_UDP: {
		struct rte_udp_hdr ubuf;
		const struct rte_udp_hdr *u = HDR(m, off, struct rte_udp_hdr, &ubuf);

		if (u == NULL || l4_len < sizeof(*u)) {
			out(" | DROP: truncated UDP header");
			return;
		}
		out(":%u -> :%u UDP", rte_be_to_cpu_16(u->src_port),
		    rte_be_to_cpu_16(u->dst_port));
		break;
	}
	case IPPROTO_TCP: {
		struct rte_tcp_hdr tbuf;
		const struct rte_tcp_hdr *t = HDR(m, off, struct rte_tcp_hdr, &tbuf);

		if (t == NULL || l4_len < sizeof(*t)) {
			out(" | DROP: truncated TCP header");
			return;
		}
		out(":%u -> :%u TCP[%s%s] hlen=%u", rte_be_to_cpu_16(t->src_port),
		    rte_be_to_cpu_16(t->dst_port),
		    (t->tcp_flags & RTE_TCP_SYN_FLAG) ? "S" : "",
		    (t->tcp_flags & RTE_TCP_ACK_FLAG) ? "A" : "",
		    (t->data_off >> 4) * 4);
		break;
	}
	case IPPROTO_ICMP: {
		struct rte_icmp_hdr ibuf;
		const struct rte_icmp_hdr *ic = HDR(m, off, struct rte_icmp_hdr, &ibuf);

		if (ic == NULL || l4_len < sizeof(*ic)) {
			out(" | DROP: truncated ICMP header");
			return;
		}
		/* 26.11: RTE_ICMP_TYPE_ECHO_REQUEST (RTE_IP_ICMP_ECHO_* are gone) */
		if (ic->icmp_type == RTE_ICMP_TYPE_ECHO_REQUEST)
			out("ICMP echo-request id=0x%04x seq=%u",
			    rte_be_to_cpu_16(ic->icmp_ident),
			    rte_be_to_cpu_16(ic->icmp_seq_nb));
		else
			out("ICMP type=%u code=%u", ic->icmp_type, ic->icmp_code);
		break;
	}
	default:
		out(" proto=%u (not parsed)", proto);
		return;
	}

	/* Checksum: we need the whole L4 segment in contiguous memory. */
	if (l4_len > sizeof(l4_copy)) {
		out(" l4csum=skipped(too long)");
		return;
	}
	l4 = rte_pktmbuf_read(m, off, l4_len, l4_copy);
	if (l4 == NULL) {
		out(" | DROP: L4 shorter than the IP header claims");
		return;
	}
	if (proto == IPPROTO_UDP && ((const struct rte_udp_hdr *)l4)->dgram_cksum == 0) {
		/* UDP over IPv4 may omit the checksum (0 means "none"). */
		out(" l4csum=none");
	} else if (proto == IPPROTO_ICMP) {
		/* ICMP has no pseudo-header: plain sum over the message. */
		out(" l4csum=%s", rte_raw_cksum(l4, l4_len) == 0xffff ? "ok" : "BAD");
	} else if (ip4 != NULL) {
		out(" l4csum=%s",
		    rte_ipv4_udptcp_cksum_verify(ip4, l4) == 0 ? "ok" : "BAD");
	} else {
		/*
		 * rte_ipv6_udptcp_cksum*() build the pseudo-header from
		 * ip6->payload_len and ip6->proto. With extension headers both
		 * are wrong for the pseudo-header (payload_len includes the
		 * extensions, proto names the first extension). Fix a COPY of
		 * the header so the library sees what RFC 8200 8.1 asks for.
		 */
		struct rte_ipv6_hdr fixed = *ip6;

		fixed.payload_len = rte_cpu_to_be_16((uint16_t)l4_len);
		fixed.proto = proto;
		if (fixed.proto != ip6->proto)
			out(" l4csum(naive)=%s",
			    rte_ipv6_udptcp_cksum_verify(ip6, l4) == 0 ? "ok" : "BAD");
		out(" l4csum=%s",
		    rte_ipv6_udptcp_cksum_verify(&fixed, l4) == 0 ? "ok" : "BAD");
	}

	/* VXLAN: UDP destination port 4789, 8-byte header, then a whole frame. */
	if (proto == IPPROTO_UDP && depth == 0) {
		const struct rte_udp_hdr *u = l4;
		struct rte_vxlan_hdr vbuf;
		const struct rte_vxlan_hdr *vx;

		if (u->dst_port != RTE_BE16(RTE_VXLAN_DEFAULT_PORT))
			return;
		vx = HDR(m, off + sizeof(*u), struct rte_vxlan_hdr, &vbuf);
		if (vx == NULL) {
			out(" | DROP: truncated VXLAN header");
			return;
		}
		/* vx_vni holds the 24-bit VNI in its top 3 bytes. */
		out(" VXLAN vni=%u {", rte_be_to_cpu_32(vx->vx_vni) >> 8);
		parse_ether(m, off + sizeof(*u) + sizeof(*vx), depth + 1);
		out(" }");
	}
}

static void
parse_ipv4(const struct rte_mbuf *m, uint32_t off, int depth)
{
	uint8_t hbuf[60];                 /* max IPv4 header: IHL 15 * 4 */
	const struct rte_ipv4_hdr *ip;
	uint16_t hlen, total, frag, frag_off;
	char s[16], d[16];

	ip = HDR(m, off, struct rte_ipv4_hdr, hbuf);
	if (ip == NULL) {
		out("IPv4 | DROP: truncated IPv4 header (need %zu bytes at offset %u, frame has %u)",
		    sizeof(*ip), off, rte_pktmbuf_pkt_len(m));
		return;
	}
	if ((ip->version_ihl >> 4) != 4) {
		out("IPv4 | DROP: version %u", ip->version_ihl >> 4);
		return;
	}
	hlen = rte_ipv4_hdr_len(ip);          /* (version_ihl & 0xf) * 4 */
	if (hlen < sizeof(*ip)) {
		out("IPv4 | DROP: IHL %u gives %u-byte header (< 20)",
		    ip->version_ihl & RTE_IPV4_HDR_IHL_MASK, hlen);
		return;
	}
	total = rte_be_to_cpu_16(ip->total_length);
	if (total < hlen || off + total > rte_pktmbuf_pkt_len(m)) {
		out("IPv4 | DROP: total_length %u does not fit", total);
		return;
	}
	if (hlen > sizeof(*ip)) {             /* re-read including options */
		ip = rte_pktmbuf_read(m, off, hlen, hbuf);
		if (ip == NULL)
			return;
		out("IPv4(+%u opt bytes) ", hlen - (unsigned int)sizeof(*ip));
	} else {
		out("IPv4 ");
	}
	ip4_str(ip->src_addr, s, sizeof(s));
	ip4_str(ip->dst_addr, d, sizeof(d));
	out("%s -> %s ttl=%u ipcsum=%s ", s, d, ip->time_to_live,
	    /* sum over a correct header INCLUDING its checksum is 0xffff */
	    rte_raw_cksum(ip, hlen) == 0xffff ? "ok" : "BAD");

	frag = rte_be_to_cpu_16(ip->fragment_offset);
	frag_off = (frag & RTE_IPV4_HDR_OFFSET_MASK) * RTE_IPV4_HDR_OFFSET_UNITS;
	if (frag & RTE_IPV4_HDR_MF_FLAG || frag_off) {
		out("frag(id=%u off=%u MF=%u) ", rte_be_to_cpu_16(ip->packet_id),
		    frag_off, !!(frag & RTE_IPV4_HDR_MF_FLAG));
		if (frag_off != 0) {
			/* only the first fragment carries the L4 header */
			out("proto=%u, no L4 header in this fragment", ip->next_proto_id);
			return;
		}
		if (ip->next_proto_id == IPPROTO_UDP) {
			/* L4 header is here, but the checksum covers all fragments */
			struct rte_udp_hdr ubuf;
			const struct rte_udp_hdr *u =
				HDR(m, off + hlen, struct rte_udp_hdr, &ubuf);
			if (u != NULL)
				out(":%u -> :%u UDP l4csum=needs-reassembly",
				    rte_be_to_cpu_16(u->src_port),
				    rte_be_to_cpu_16(u->dst_port));
			return;
		}
	}
	parse_l4(m, off + hlen, total - hlen, ip->next_proto_id, ip, NULL, depth);
}

static void
parse_ipv6(const struct rte_mbuf *m, uint32_t off, int depth)
{
	struct rte_ipv6_hdr hbuf;
	const struct rte_ipv6_hdr *ip6 = HDR(m, off, struct rte_ipv6_hdr, &hbuf);
	uint32_t vtc, plen, cur;
	int proto, i;
	char s[INET6_ADDRSTRLEN], d[INET6_ADDRSTRLEN];

	if (ip6 == NULL) {
		out("IPv6 | DROP: truncated IPv6 header");
		return;
	}
	if (rte_ipv6_check_version(ip6) != 0) {
		out("IPv6 | DROP: bad version");
		return;
	}
	plen = rte_be_to_cpu_16(ip6->payload_len);
	if (off + sizeof(*ip6) + plen > rte_pktmbuf_pkt_len(m)) {
		out("IPv6 | DROP: payload_len %u does not fit", plen);
		return;
	}
	/* 26.11: no bitfields; mask/shift the host-order vtc_flow word. */
	vtc = rte_be_to_cpu_32(ip6->vtc_flow);
	snprintf(s, sizeof(s), RTE_IPV6_ADDR_FMT, RTE_IPV6_ADDR_SPLIT(&ip6->src_addr));
	snprintf(d, sizeof(d), RTE_IPV6_ADDR_FMT, RTE_IPV6_ADDR_SPLIT(&ip6->dst_addr));
	out("IPv6 %s -> %s tc=0x%02x flow=0x%05x hlim=%u ", s, d,
	    (vtc & RTE_IPV6_HDR_TC_MASK) >> RTE_IPV6_HDR_TC_SHIFT,
	    (vtc & RTE_IPV6_HDR_FL_MASK) >> RTE_IPV6_HDR_FL_SHIFT,
	    ip6->hop_limits);

	/* Walk extension headers: rte_ipv6_get_next_ext() needs 2 bytes. */
	proto = ip6->proto;
	cur = off + sizeof(*ip6);
	for (i = 0; i < 8; i++) {
		uint8_t eb[2];
		const uint8_t *p = rte_pktmbuf_read(m, cur, 2, eb);
		size_t ext_len;
		int next;

		if (p == NULL)
			break;
		next = rte_ipv6_get_next_ext(p, proto, &ext_len);
		if (next < 0)
			break;                  /* proto is not an extension */
		out("ext(%d,%zuB) ", proto, ext_len);
		cur += ext_len;
		proto = next;
		if (cur > off + sizeof(*ip6) + plen) {
			out("| DROP: extension headers overrun the payload");
			return;
		}
	}
	parse_l4(m, cur, off + sizeof(*ip6) + plen - cur, (uint8_t)proto,
		 NULL, ip6, depth);
}

static void
parse_arp(const struct rte_mbuf *m, uint32_t off)
{
	struct rte_arp_hdr abuf;
	const struct rte_arp_hdr *a = HDR(m, off, struct rte_arp_hdr, &abuf);
	char sip[16], tip[16], sha[RTE_ETHER_ADDR_FMT_SIZE];

	if (a == NULL) {
		out("ARP | DROP: truncated");
		return;
	}
	ip4_str(a->arp_data.arp_sip, sip, sizeof(sip));
	ip4_str(a->arp_data.arp_tip, tip, sizeof(tip));
	rte_ether_format_addr(sha, sizeof(sha), &a->arp_data.arp_sha);
	if (a->arp_opcode == RTE_BE16(RTE_ARP_OP_REQUEST))
		out("ARP request: who has %s? tell %s (%s)", tip, sip, sha);
	else
		out("ARP op=%u %s -> %s", rte_be_to_cpu_16(a->arp_opcode), sip, tip);
}

/* Returns 0 if an L3 header was found, -1 otherwise. */
static int
parse_ether(const struct rte_mbuf *m, uint32_t off, int depth)
{
	struct rte_ether_hdr ebuf;
	const struct rte_ether_hdr *eth = HDR(m, off, struct rte_ether_hdr, &ebuf);
	uint16_t type;

	if (eth == NULL) {
		out("| DROP: shorter than an Ethernet header");
		return -1;
	}
	if (depth > 0) {
		char dst[RTE_ETHER_ADDR_FMT_SIZE];

		rte_ether_format_addr(dst, sizeof(dst), &eth->dst_addr);
		out("inner-eth dst=%s ", dst);
	}
	type = rte_be_to_cpu_16(eth->ether_type);
	off += sizeof(*eth);

	/* EXERCISE 1: any stack of up to two tags. 802.1ad S-tag (0x88a8, or
	 * the pre-standard 0x9100) outside, 802.1Q C-tag (0x8100) inside. */
	{
		int ntags = 0;

		while (type == RTE_ETHER_TYPE_VLAN || type == RTE_ETHER_TYPE_QINQ ||
		       type == RTE_ETHER_TYPE_QINQ1) {
			struct rte_vlan_hdr vbuf;
			const struct rte_vlan_hdr *vh =
				HDR(m, off, struct rte_vlan_hdr, &vbuf);
			uint16_t tci;

			if (vh == NULL) {
				out("| DROP: truncated VLAN tag");
				return -1;
			}
			if (++ntags > 2) {
				out("| DROP: more than 2 VLAN tags");
				return -1;
			}
			tci = rte_be_to_cpu_16(vh->vlan_tci);
			out("%s=%u pcp=%u ", type == RTE_ETHER_TYPE_VLAN ? "c-vlan" : "s-vlan",
			    tci & 0xfff, tci >> 13);
			type = rte_be_to_cpu_16(vh->eth_proto);
			off += sizeof(*vh);
		}
	}

	switch (type) {
	case RTE_ETHER_TYPE_IPV4:
		parse_ipv4(m, off, depth);
		return 0;
	case RTE_ETHER_TYPE_IPV6:
		parse_ipv6(m, off, depth);
		return 0;
	case RTE_ETHER_TYPE_ARP:
		parse_arp(m, off);
		return 0;
	default:
		out("ethertype 0x%04x not handled", type);
		return -1;
	}
}

/* Print what the library parser thinks of the same frame. */
static void
print_ptype(struct rte_mbuf *m)
{
	struct rte_net_hdr_lens hl = {0};
	char name[256];
	uint32_t ptype = rte_net_get_ptype(m, &hl, RTE_PTYPE_ALL_MASK);

	rte_get_ptype_name(ptype, name, sizeof(name));
	printf("      ptype=0x%08x %s\n", ptype, name);
	printf("      hdr_lens l2=%u l3=%u l4=%u", hl.l2_len, hl.l3_len, hl.l4_len);
	if (ptype & RTE_PTYPE_TUNNEL_MASK)
		printf(" tunnel=%u inner_l2=%u inner_l3=%u inner_l4=%u",
		       hl.tunnel_len, hl.inner_l2_len, hl.inner_l3_len,
		       hl.inner_l4_len);
	printf("\n");

	/*
	 * Sanity check: INNER_* bits without a TUNNEL_* bit make no sense.
	 * In 26.11 this happens for IPv4/ICMP: L4 "unknown" sends the parser
	 * into its inner-header code with proto = 1 (ICMP), which equals
	 * RTE_VXLAN_GPE_TYPE_IPV4, so the ICMP message is decoded as an inner
	 * IPv4 header. Asking only for the outer layers avoids that path.
	 */
	if ((ptype & (RTE_PTYPE_INNER_L2_MASK | RTE_PTYPE_INNER_L3_MASK |
		      RTE_PTYPE_INNER_L4_MASK)) != 0 &&
	    (ptype & RTE_PTYPE_TUNNEL_MASK) == 0) {
		ptype = rte_net_get_ptype(m, &hl, RTE_PTYPE_L2_MASK |
					  RTE_PTYPE_L3_MASK | RTE_PTYPE_L4_MASK);
		rte_get_ptype_name(ptype, name, sizeof(name));
		printf("      !! inner bits without a tunnel; outer layers only: ptype=0x%08x %s\n",
		       ptype, name);
	}
}

/* Build a 2-segment copy of 'src' split at byte 'split' and parse it. */
static void
segment_demo(struct rte_mempool *pool, const uint8_t *frame, uint16_t len,
	     uint16_t split)
{
	struct rte_mbuf *a = rte_pktmbuf_alloc(pool), *b = rte_pktmbuf_alloc(pool);
	struct rte_ipv4_hdr copy;
	const struct rte_ipv4_hdr *ip;

	if (a == NULL || b == NULL) {
		rte_pktmbuf_free(a);
		rte_pktmbuf_free(b);
		return;
	}
	memcpy(rte_pktmbuf_append(a, split), frame, split);
	memcpy(rte_pktmbuf_append(b, len - split), frame + split, len - split);
	rte_pktmbuf_chain(a, b);              /* a now owns b */

	printf("\n== a 2-segment packet: seg0 %u bytes + seg1 %u bytes (pkt_len %u)\n",
	       rte_pktmbuf_data_len(a), rte_pktmbuf_data_len(b),
	       rte_pktmbuf_pkt_len(a));
	printf("   IPv4 header needs bytes [14,34) but seg0 ends at %u:\n", split);
	printf("   rte_pktmbuf_mtod_offset(m, ip*, 14) would read %u bytes past seg0 (garbage)\n",
	       14 + 20 - split);
	ip = rte_pktmbuf_read(a, 14, sizeof(copy), &copy);
	printf("   rte_pktmbuf_read() returned %s, ttl=%u total_length=%u\n",
	       (const void *)ip == (void *)&copy ? "our stack copy" : "a pointer into the mbuf",
	       ip->time_to_live, rte_be_to_cpu_16(ip->total_length));
	line_len = 0;
	parse_ether(a, 0, 0);
	printf("   parse: %s\n", line);
	print_ptype(a);
	rte_pktmbuf_free(a);
}

int
main(int argc, char **argv)
{
	struct rte_mempool *pool;
	struct rte_mbuf *pkts[32];
	uint8_t first[256];
	uint16_t first_len = 0;
	unsigned int n = 0, idle = 0, i;
	int ret;

	ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (rte_eth_dev_count_avail() < 1)
		rte_exit(EXIT_FAILURE, "need one port, e.g. --vdev=net_pcap0,rx_pcap=mixed.pcap,tx_pcap=/dev/null\n");

	pool = rte_pktmbuf_pool_create("ch10_pvlan", 1023, 32, 0,
				       RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (pool == NULL)
		rte_exit(EXIT_FAILURE, "mbuf pool: %s\n", rte_strerror(rte_errno));
	if (ch10_port_init(0, pool) < 0)
		rte_exit(EXIT_FAILURE, "port 0 init failed\n");

	/* net_pcap delivers the file once, then returns 0 forever. */
	while (idle < 100) {
		uint16_t nb = rte_eth_rx_burst(0, 0, pkts, 32);

		if (nb == 0) {
			idle++;
			continue;
		}
		idle = 0;
		for (i = 0; i < nb; i++) {
			struct rte_mbuf *m = pkts[i];

			n++;
			/* keep a copy of the first IPv4 frame for segment_demo() */
			if (first_len == 0 && rte_pktmbuf_data_len(m) <= sizeof(first) &&
			    rte_pktmbuf_mtod(m, struct rte_ether_hdr *)->ether_type ==
			    RTE_BE16(RTE_ETHER_TYPE_IPV4)) {
				first_len = rte_pktmbuf_data_len(m);
				memcpy(first, rte_pktmbuf_mtod(m, void *), first_len);
			}
			line_len = 0;
			parse_ether(m, 0, 0);
			printf("#%-2u len=%-3u %s\n", n, rte_pktmbuf_pkt_len(m), line);
			print_ptype(m);
			rte_pktmbuf_free(m);
		}
	}
	printf("parsed %u frames\n", n);

	if (first_len > 34)
		segment_demo(pool, first, first_len, 20);

	rte_eth_dev_stop(0);
	rte_eth_dev_close(0);
	rte_eal_cleanup();
	return 0;
}
