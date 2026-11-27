/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 10, exercise 2 solution: incremental checksum update (RFC 1624)
 * for a changed destination IPv4 address, as a NAT would do it.
 *
 * The 32-bit address is two 16-bit words, so the update is applied twice.
 * The UDP checksum ALSO covers the destination address (pseudo-header), so
 * it must be updated too, with two extra rules:
 *   - a UDP checksum of 0 means "no checksum": leave it 0;
 *   - a computed UDP checksum of 0 must be sent as 0xffff.
 * Every result is compared with a full recomputation by lib/net.
 *
 *   ./incr_cksum -l 0 --no-pci --no-huge -m 64 --file-prefix=ch10-incr
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netinet/in.h>

#include <rte_eal.h>
#include <rte_ip4.h>
#include <rte_udp.h>
#include <rte_cksum.h>
#include <rte_byteorder.h>

/* Fold to 16 bits. */
static uint16_t
fold(uint32_t s)
{
	while (s >> 16)
		s = (s & 0xffff) + (s >> 16);
	return (uint16_t)s;
}

/*
 * RFC 1624 eqn. 3: HC' = ~(~HC + ~m + m'), for each changed 16-bit word.
 * All values are taken straight from packet memory (network order in, network
 * order out): one's-complement arithmetic does not care about byte order as
 * long as every operand uses the same one.
 */
static uint16_t
cksum_update32(uint16_t hc, uint32_t old32, uint32_t new32)
{
	uint32_t s = (uint16_t)~hc;

	s += (uint16_t)~(old32 >> 16) + (uint16_t)(new32 >> 16);
	s += (uint16_t)~(old32 & 0xffff) + (uint16_t)(new32 & 0xffff);
	return (uint16_t)~fold(s);
}

struct __rte_aligned(2) pkt {
	struct rte_ipv4_hdr ip;
	struct rte_udp_hdr udp;
	char data[12];
};

static void
build(struct pkt *p, int udp_cksum)
{
	memset(p, 0, sizeof(*p));
	p->ip.version_ihl = RTE_IPV4_VHL_DEF;
	p->ip.total_length = rte_cpu_to_be_16(sizeof(*p));
	p->ip.time_to_live = 64;
	p->ip.next_proto_id = IPPROTO_UDP;
	p->ip.src_addr = RTE_BE32(RTE_IPV4(10, 10, 0, 1));
	p->ip.dst_addr = RTE_BE32(RTE_IPV4(10, 10, 0, 2));
	p->ip.hdr_checksum = rte_ipv4_cksum(&p->ip);
	p->udp.src_port = RTE_BE16(1000);
	p->udp.dst_port = RTE_BE16(2000);
	p->udp.dgram_len = rte_cpu_to_be_16(sizeof(p->udp) + sizeof(p->data));
	memcpy(p->data, "rfc1624-test", sizeof(p->data));
	if (udp_cksum)
		p->udp.dgram_cksum = rte_ipv4_udptcp_cksum(&p->ip, &p->udp);
}

static int
rewrite_dst(struct pkt *p, uint32_t new_dst_host)
{
	uint32_t old = p->ip.dst_addr;                 /* network order */
	uint32_t new = rte_cpu_to_be_32(new_dst_host);
	uint16_t ip_inc, udp_inc = 0, ip_full, udp_full;
	struct pkt ref;
	int ok;

	p->ip.dst_addr = new;
	ip_inc = cksum_update32(p->ip.hdr_checksum, old, new);
	if (p->udp.dgram_cksum != 0) {                 /* 0 = no checksum */
		udp_inc = cksum_update32(p->udp.dgram_cksum, old, new);
		if (udp_inc == 0)
			udp_inc = 0xffff;
	}

	/* reference: full recomputation on a copy */
	ref = *p;
	ref.ip.hdr_checksum = 0;
	ip_full = rte_ipv4_cksum(&ref.ip);
	ref.ip.hdr_checksum = ip_full;
	ref.udp.dgram_cksum = 0;
	udp_full = p->udp.dgram_cksum ? rte_ipv4_udptcp_cksum(&ref.ip, &ref.udp) : 0;

	p->ip.hdr_checksum = ip_inc;
	p->udp.dgram_cksum = udp_inc;
	ok = ip_inc == ip_full && udp_inc == udp_full &&
	     rte_raw_cksum(&p->ip, sizeof(p->ip)) == 0xffff &&
	     (udp_inc == 0 || rte_ipv4_udptcp_cksum_verify(&p->ip, &p->udp) == 0);
	printf("  dst -> %u.%u.%u.%u  ip: incr=0x%04x full=0x%04x  udp: incr=0x%04x full=0x%04x  %s\n",
	       new_dst_host >> 24, (new_dst_host >> 16) & 0xff,
	       (new_dst_host >> 8) & 0xff, new_dst_host & 0xff,
	       rte_be_to_cpu_16(ip_inc), rte_be_to_cpu_16(ip_full),
	       rte_be_to_cpu_16(udp_inc), rte_be_to_cpu_16(udp_full),
	       ok ? "MATCH, verifies" : "MISMATCH");
	return ok;
}

int
main(int argc, char **argv)
{
	static const uint32_t targets[] = {
		RTE_IPV4(10, 20, 0, 9), RTE_IPV4(192, 168, 1, 1),
		RTE_IPV4(255, 255, 255, 255), RTE_IPV4(0, 0, 0, 0),
		RTE_IPV4(10, 10, 0, 2),
	};
	struct pkt p;
	unsigned int i, good = 0, total = 0;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	printf("UDP with checksum, rewriting dst 10.10.0.2 step by step:\n");
	build(&p, 1);
	for (i = 0; i < RTE_DIM(targets); i++, total++)
		good += rewrite_dst(&p, targets[i]);

	printf("UDP without checksum (dgram_cksum = 0 must stay 0):\n");
	build(&p, 0);
	for (i = 0; i < 2; i++, total++)
		good += rewrite_dst(&p, targets[i]);

	/* exhaustive-ish: 100000 random rewrites */
	build(&p, 1);
	{
		unsigned int n = 0, bad = 0;
		uint32_t x = 12345;

		for (n = 0; n < 100000; n++) {
			uint32_t old = p.ip.dst_addr, new;
			uint16_t inc;

			x = x * 1103515245u + 12345u;   /* tiny LCG */
			new = rte_cpu_to_be_32(x);
			p.ip.dst_addr = new;
			inc = cksum_update32(p.ip.hdr_checksum, old, new);
			p.ip.hdr_checksum = 0;
			if (inc != rte_ipv4_cksum(&p.ip))
				bad++;
			p.ip.hdr_checksum = inc;
		}
		printf("100000 random dst rewrites: %u mismatches against rte_ipv4_cksum()\n", bad);
	}
	printf("%u/%u checks passed\n", good, total);
	rte_eal_cleanup();
	return good == total ? 0 : 1;
}
