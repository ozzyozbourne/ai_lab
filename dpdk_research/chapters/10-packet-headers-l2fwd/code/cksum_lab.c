/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 10: cksum_lab.c - the Internet checksum by hand, then by lib/net.
 *
 *  1. Sum the ten 16-bit words of a real IPv4 header, showing every carry,
 *     fold the 32-bit sum to 16 bits, invert it.
 *  2. Compare with rte_raw_cksum(), rte_ipv4_cksum(), rte_ipv4_cksum_simple().
 *  3. Byte order: why the checksum is stored WITHOUT rte_cpu_to_be_16().
 *  4. Verification: a correct header sums to 0xffff.
 *  5. The classic bug: computing the checksum without zeroing the field.
 *  6. Incremental update for a TTL decrement (RFC 1624) vs full recompute.
 *  7. UDP: the pseudo-header, rte_ipv4_phdr_cksum() and
 *     rte_ipv4_udptcp_cksum(), with an odd-length payload.
 *
 *   ./cksum_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch10-ck
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

/* The header from the classic textbook example (checksum field zeroed):
 * 192.168.0.1 -> 192.168.0.199, UDP, TTL 64, total length 115, DF. */
static const uint8_t hdr_bytes[20] = {
	0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11,
	0x00, 0x00, 0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7,
};

/* Fold a 32-bit one's-complement accumulator to 16 bits. */
static uint16_t
fold(uint32_t sum)
{
	while (sum >> 16)
		sum = (sum & 0xffff) + (sum >> 16);
	return (uint16_t)sum;
}

/* Read the 16-bit word at byte offset i in NETWORK order, as a human would. */
static uint16_t
word_be(const uint8_t *p, int i)
{
	return (uint16_t)(p[i] << 8 | p[i + 1]);
}

int
main(int argc, char **argv)
{
	union {
		struct rte_ipv4_hdr ip;
		uint8_t b[20];
	} h;
	uint32_t sum = 0;
	uint16_t by_hand, lib, raw, simple;
	int i;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	memcpy(h.b, hdr_bytes, sizeof(h.b));

	/* ---------------- 1. by hand ---------------- */
	printf("== 1. one's-complement sum of the 10 header words (network order)\n");
	for (i = 0; i < 20; i += 2) {
		uint16_t w = word_be(h.b, i);

		sum += w;
		printf("  word %d  bytes %02x %02x  = 0x%04x   running sum 0x%05x%s\n",
		       i / 2, h.b[i], h.b[i + 1], w, sum,
		       i == 10 ? "   (checksum field, 0 while computing)" : "");
	}
	printf("  32-bit sum            = 0x%08x\n", sum);
	printf("  fold: 0x%04x + 0x%x    = 0x%04x  (add the carries back in)\n",
	       sum & 0xffff, sum >> 16, fold(sum));
	by_hand = (uint16_t)~fold(sum);
	printf("  invert                = 0x%04x  <- the checksum, in network order\n",
	       by_hand);

	/* ---------------- 2. the library ---------------- */
	printf("\n== 2. the library (this CPU is little-endian)\n");
	raw = rte_raw_cksum(h.b, 20);
	lib = rte_ipv4_cksum(&h.ip);
	simple = rte_ipv4_cksum_simple(&h.ip);   /* experimental: skips the field */
	printf("  rte_raw_cksum(hdr, 20)   = 0x%04x  (folded, NOT inverted, host-loaded words)\n", raw);
	printf("  rte_ipv4_cksum(hdr)      = 0x%04x\n", lib);
	printf("  rte_ipv4_cksum_simple()  = 0x%04x\n", simple);
	printf("  rte_be_to_cpu_16(lib)    = 0x%04x  == by hand 0x%04x ? %s\n",
	       rte_be_to_cpu_16(lib), by_hand,
	       rte_be_to_cpu_16(lib) == by_hand ? "yes" : "NO");

	/* ---------------- 3. byte order ---------------- */
	printf("\n== 3. storing it: write the value exactly as returned\n");
	h.ip.hdr_checksum = lib;
	printf("  hdr_checksum = rte_ipv4_cksum()      -> bytes %02x %02x on the wire (correct)\n",
	       h.b[10], h.b[11]);
	h.ip.hdr_checksum = rte_cpu_to_be_16(lib);
	printf("  hdr_checksum = rte_cpu_to_be_16(...) -> bytes %02x %02x (WRONG: swapped twice)\n",
	       h.b[10], h.b[11]);
	printf("  why: one's-complement sums are byte-order independent; summing\n"
	       "  byte-swapped words gives the byte-swapped sum, so the result is\n"
	       "  already in 'memory order'. Swapping it again breaks it.\n");

	/* ---------------- 4. verify ---------------- */
	printf("\n== 4. verification: sum over a header that INCLUDES its checksum\n");
	h.ip.hdr_checksum = lib;
	printf("  correct header : rte_raw_cksum = 0x%04x (0xffff means valid)\n",
	       rte_raw_cksum(h.b, 20));
	h.ip.hdr_checksum = rte_cpu_to_be_16(lib);
	printf("  swapped cksum  : rte_raw_cksum = 0x%04x (invalid)\n",
	       rte_raw_cksum(h.b, 20));

	/* ---------------- 5. the classic bug ---------------- */
	printf("\n== 5. bug: recomputing without zeroing hdr_checksum first\n");
	h.ip.hdr_checksum = lib;                  /* still holds the old value */
	printf("  rte_ipv4_cksum() on the unzeroed header = 0x%04x (should be 0x%04x)\n",
	       rte_ipv4_cksum(&h.ip), lib);
	printf("  rte_ipv4_cksum_simple() ignores the field = 0x%04x\n",
	       rte_ipv4_cksum_simple(&h.ip));

	/* ---------------- 6. incremental update ---------------- */
	printf("\n== 6. router step: TTL 64 -> 63, incremental update (RFC 1624 eqn. 3)\n");
	{
		/* TTL shares a 16-bit word with the protocol byte. */
		uint16_t m_old = word_be(h.b, 8);     /* 0x4011 */
		uint16_t hc = rte_be_to_cpu_16(h.ip.hdr_checksum);
		uint16_t m_new, hc_new, full;
		uint32_t s;

		h.ip.time_to_live--;
		m_new = word_be(h.b, 8);              /* 0x3f11 */
		/* HC' = ~(~HC + ~m + m') */
		s = (uint16_t)~hc + (uint16_t)~m_old + m_new;
		hc_new = (uint16_t)~fold(s);
		printf("  HC=0x%04x  m=0x%04x  m'=0x%04x\n", hc, m_old, m_new);
		printf("  ~HC + ~m + m' = 0x%04x + 0x%04x + 0x%04x = 0x%05x -> fold 0x%04x -> ~ 0x%04x\n",
		       (uint16_t)~hc, (uint16_t)~m_old, m_new, s, fold(s), hc_new);
		h.ip.hdr_checksum = 0;
		full = rte_be_to_cpu_16(rte_ipv4_cksum(&h.ip));
		printf("  full recompute = 0x%04x   incremental = 0x%04x   %s\n",
		       full, hc_new, full == hc_new ? "MATCH" : "MISMATCH");
		printf("  (RFC 1141 shortcut for TTL-1: HC + 0x0100 = 0x%04x)\n",
		       fold((uint32_t)hc + 0x0100));
		h.ip.hdr_checksum = rte_cpu_to_be_16(hc_new);
	}

	/* ---------------- 7. UDP and the pseudo-header ---------------- */
	printf("\n== 7. UDP checksum = sum(pseudo-header) + sum(UDP header + data)\n");
	{
		static const char data[] = "odd";     /* 3 bytes: odd length */
		struct {
			struct rte_ipv4_hdr ip;
			struct rte_udp_hdr udp;
			char data[3];
		} __rte_aligned(2) pkt;
		uint16_t phdr, ck, l4len = sizeof(pkt.udp) + 3;

		memcpy(&pkt.ip, hdr_bytes, 20);
		pkt.ip.total_length = rte_cpu_to_be_16(20 + l4len);
		pkt.ip.hdr_checksum = 0;
		pkt.ip.hdr_checksum = rte_ipv4_cksum(&pkt.ip);
		pkt.udp.src_port = RTE_BE16(1234);
		pkt.udp.dst_port = RTE_BE16(53);
		pkt.udp.dgram_len = rte_cpu_to_be_16(l4len);
		pkt.udp.dgram_cksum = 0;
		memcpy(pkt.data, data, 3);

		phdr = rte_ipv4_phdr_cksum(&pkt.ip, 0);
		printf("  pseudo-header = src 192.168.0.1, dst 192.168.0.199, zero, proto 17, len %u\n",
		       l4len);
		printf("  rte_ipv4_phdr_cksum()   = 0x%04x (not inverted; also what TX offload\n"
		       "                            drivers want pre-filled, see ch19)\n", phdr);
		printf("  rte_raw_cksum(udp, %u)  = 0x%04x (odd length: last byte padded with 0)\n",
		       l4len, rte_raw_cksum(&pkt.udp, l4len));
		ck = rte_ipv4_udptcp_cksum(&pkt.ip, &pkt.udp);
		printf("  rte_ipv4_udptcp_cksum() = 0x%04x  = ~fold(0x%04x + 0x%04x)\n", ck, phdr,
		       rte_raw_cksum(&pkt.udp, l4len));
		pkt.udp.dgram_cksum = ck;
		printf("  rte_ipv4_udptcp_cksum_verify() = %d (0 = valid)\n",
		       rte_ipv4_udptcp_cksum_verify(&pkt.ip, &pkt.udp));
		pkt.data[0] ^= 1;                    /* flip one bit of payload */
		printf("  after flipping 1 payload bit: verify = %d\n",
		       rte_ipv4_udptcp_cksum_verify(&pkt.ip, &pkt.udp));
		pkt.data[0] ^= 1;
		pkt.ip.dst_addr = RTE_BE32(RTE_IPV4(192, 168, 0, 200));
		printf("  after changing only the IP dst (pseudo-header!): verify = %d\n",
		       rte_ipv4_udptcp_cksum_verify(&pkt.ip, &pkt.udp));
	}

	rte_eal_cleanup();
	return 0;
}
