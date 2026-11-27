/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: asan_demo.c - AddressSanitizer on a DPDK application.
 *
 * Built twice by the Makefile:
 *   asan_demo        plain -O2: the overflow silently corrupts the heap
 *   asan_demo_asan   gcc -fsanitize=address: the first bad write is reported
 *                    with a stack trace of the write and of the allocation
 *
 * The bug: a "flow record" keeps a copy of the first bytes of a packet in a
 * 64-byte malloc() buffer, but copies rte_pktmbuf_pkt_len() bytes. Packets
 * from net_null are 64 bytes, so it works... until a 128-byte packet
 * arrives (here: we build one by hand).
 *
 * What ASan can see in a DPDK app: memory from malloc/new, the stack and
 * globals of code compiled with -fsanitize=address. What it cannot see
 * unless DPDK itself is built with -Db_sanitize=address: rte_malloc heap
 * and mempool objects (mbufs). doc/guides/prog_guide/asan.rst has the
 * details. The gcc ASan runtime is used because the clang one is missing
 * on the course VM.
 *
 *   ./asan_demo_asan -l 0 --no-pci --no-huge -m 64 --file-prefix=ch13-asan
 */
#include "ch13_common.h"

struct flow_rec {
	uint32_t pkts;
	unsigned char *head;           /* first 64 bytes of the first packet */
};

static void __rte_noinline
record_packet(struct flow_rec *fr, struct rte_mbuf *m)
{
	if (fr->head == NULL)
		fr->head = malloc(64);
	/* BUG: should be RTE_MIN(rte_pktmbuf_data_len(m), 64) */
	memcpy(fr->head, rte_pktmbuf_mtod(m, void *), rte_pktmbuf_data_len(m));
	fr->pkts++;
}

int
main(int argc, char **argv)
{
	struct flow_rec fr = {0};
	struct rte_mempool *mp;
	uint16_t len;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	mp = rte_pktmbuf_pool_create("ch13_asan_pool", 255, 0, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool failed\n");

	for (len = 64; len <= 128; len += 64) {
		struct rte_mbuf *m = rte_pktmbuf_alloc(mp);

		ch13_make_udp(m, len, 0);
		printf("recording a %u-byte packet into a 64-byte buffer\n", len);
		fflush(stdout);
		record_packet(&fr, m);
		rte_pktmbuf_free(m);
	}
	printf("recorded %u packets, no crash: the overflow went unnoticed\n",
	       fr.pkts);
	free(fr.head);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
