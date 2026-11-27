/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, example 2: payload_build.c
 *
 * Builds a "message" in an mbuf without any network protocol headers:
 *   - a small application header of our own (struct app_hdr, 8 bytes,
 *     packed, multi-byte fields in network byte order)
 *   - followed by a text payload
 * The header is written with rte_pktmbuf_prepend() AFTER the payload was
 * appended, which is how real stacks build packets: payload first, then
 * each layer prepends its header into the headroom.
 *
 * It also stores per-packet metadata that must NOT go on the wire in the
 * mbuf private area (rte_mbuf_to_priv), and inspects the result with
 * rte_pktmbuf_dump() and rte_hexdump().
 *
 * (The Ethernet/IPv4/UDP version of this, written to a pcap, is ch10.)
 *
 * Run: ./payload_build -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-pay
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_byteorder.h>
#include <rte_hexdump.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>

/* Our own 8-byte header. 26.11 syntax for packed structs:
 * __rte_packed_begin after "struct", __rte_packed_end after the brace. */
struct __rte_packed_begin app_hdr {
	uint8_t  magic;        /* 0xD7 */
	uint8_t  version;      /* 1 */
	rte_be16_t length;     /* payload length, network order */
	rte_be32_t seq;        /* sequence number, network order */
} __rte_packed_end;

/* Per-packet metadata in the mbuf private area: travels with the mbuf
 * inside this process, never appears in the packet bytes. */
struct app_priv {
	uint64_t created_tsc;  /* when we built it */
	uint32_t flow_id;      /* app-level classification */
	uint32_t pad;
};

int main(int argc, char **argv)
{
	static const char text[] = "Hello from the mbuf data room!";
	const uint16_t plen = sizeof(text) - 1;   /* no trailing NUL */

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	RTE_BUILD_BUG_ON(sizeof(struct app_hdr) != 8);
	/* priv_size must be a multiple of RTE_MBUF_PRIV_ALIGN (8) */
	RTE_BUILD_BUG_ON(sizeof(struct app_priv) % RTE_MBUF_PRIV_ALIGN != 0);

	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch07_pay", 255, 0,
			sizeof(struct app_priv), RTE_MBUF_DEFAULT_BUF_SIZE,
			rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
	if (m == NULL)
		rte_exit(EXIT_FAILURE, "alloc failed\n");

	/* 1. payload first: append() returns where to write */
	char *pay = rte_pktmbuf_append(m, plen);
	if (pay == NULL)
		rte_exit(EXIT_FAILURE, "no tailroom\n");
	memcpy(pay, text, plen);
	printf("after payload : data_off=%u data_len=%u\n", m->data_off, m->data_len);

	/* 2. header second: prepend() into the headroom */
	struct app_hdr *h = (struct app_hdr *)rte_pktmbuf_prepend(m, sizeof(*h));
	if (h == NULL)
		rte_exit(EXIT_FAILURE, "no headroom\n");
	h->magic   = 0xD7;
	h->version = 1;
	h->length  = rte_cpu_to_be_16(plen);
	h->seq     = rte_cpu_to_be_32(0x01020304);
	printf("after header  : data_off=%u data_len=%u\n", m->data_off, m->data_len);

	/* 3. private metadata (not part of the data) */
	struct app_priv *pv = rte_mbuf_to_priv(m);
	pv->created_tsc = rte_rdtsc();
	pv->flow_id = 42;
	printf("priv area at m+%td, flow_id=%u (not in the packet bytes)\n",
	       (char *)pv - (char *)m, pv->flow_id);

	/* 4. read it back the way a receiver would: mtod gives the first byte */
	const struct app_hdr *rh = rte_pktmbuf_mtod(m, const struct app_hdr *);
	printf("parsed header : magic=0x%02X version=%u length=%u seq=0x%08X\n",
	       rh->magic, rh->version, rte_be_to_cpu_16(rh->length),
	       rte_be_to_cpu_32(rh->seq));
	printf("parsed payload: \"%.*s\"\n", rte_be_to_cpu_16(rh->length),
	       rte_pktmbuf_mtod_offset(m, const char *, sizeof(*rh)));

	/* 5. inspect */
	printf("\nrte_pktmbuf_dump(stdout, m, 64):\n");
	rte_pktmbuf_dump(stdout, m, 64);

	printf("\nrte_hexdump of the first 16 bytes (header + start of text):\n");
	rte_hexdump(stdout, "app_hdr+text", rte_pktmbuf_mtod(m, void *), 16);

	rte_pktmbuf_free(m);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
