/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, example 3: chain_demo.c
 *
 * A packet does not have to fit in one buffer. This program builds a
 * 3-segment chain (a 20-byte "header" mbuf + two 40-byte payload mbufs),
 * then:
 *   - shows that pkt_len / nb_segs live only in the FIRST segment
 *   - reads 16 bytes that straddle the boundary between segment 1 and 2
 *     with rte_pktmbuf_read(): the bytes are copied into a stack buffer
 *   - reads 8 bytes that are inside one segment: rte_pktmbuf_read()
 *     returns a pointer into the mbuf (no copy)
 *   - rte_pktmbuf_linearize() merges everything into segment 1
 *   - shows rte_pktmbuf_chain() refusing a chain that would be too long
 *
 * Run: ./chain_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-chain
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_mbuf.h>

static struct rte_mbuf *seg_with(struct rte_mempool *mp, char fill, uint16_t len)
{
	struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
	if (m == NULL)
		rte_exit(EXIT_FAILURE, "alloc\n");
	memset(rte_pktmbuf_append(m, len), fill, len);
	return m;
}

static void walk(const char *title, const struct rte_mbuf *head)
{
	printf("%s: pkt_len=%u nb_segs=%u contiguous=%d\n", title,
	       head->pkt_len, head->nb_segs, rte_pktmbuf_is_contiguous(head));
	int i = 0;
	for (const struct rte_mbuf *s = head; s != NULL; s = s->next, i++)
		printf("  seg %d: %p data_len=%3u pkt_len=%3u nb_segs=%u next=%p\n",
		       i, (const void *)s, s->data_len, s->pkt_len, s->nb_segs,
		       (const void *)s->next);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch07_chain", 255, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	struct rte_mbuf *hdr = seg_with(mp, 'H', 20);
	struct rte_mbuf *p1  = seg_with(mp, 'a', 40);
	struct rte_mbuf *p2  = seg_with(mp, 'b', 40);

	/* Put the segment index into the first byte of p1/p2 so the copy
	 * across the boundary is visible. */
	rte_pktmbuf_mtod(p1, char *)[0] = '1';
	rte_pktmbuf_mtod(p2, char *)[0] = '2';

	/* rte_pktmbuf_chain(head, tail): appends tail's segments to head,
	 * updates head->nb_segs and head->pkt_len. tail must not be used as
	 * a packet afterwards. Returns 0 or -EOVERFLOW. */
	if (rte_pktmbuf_chain(hdr, p1) != 0 || rte_pktmbuf_chain(hdr, p2) != 0)
		rte_exit(EXIT_FAILURE, "chain failed\n");
	walk("after chaining", hdr);
	printf("  (pkt_len/nb_segs in segments 1 and 2 are stale leftovers: only the head counts)\n");

	/* Reading across a segment boundary: bytes 56..71 are the last 4 of
	 * seg 1 (offsets 20..59) and the first 12 of seg 2 (60..99). */
	char tmp[16];
	const char *r = rte_pktmbuf_read(hdr, 56, sizeof(tmp), tmp);
	printf("\nrte_pktmbuf_read(off=56,len=16) -> %s : \"%.16s\"\n",
	       r == tmp ? "copied into tmp (crosses a boundary)" : "pointer into mbuf", r);

	/* Inside one segment: no copy, the returned pointer is into seg 1 */
	r = rte_pktmbuf_read(hdr, 24, 8, tmp);
	printf("rte_pktmbuf_read(off=24,len=8)  -> %s : \"%.8s\"\n",
	       r == tmp ? "copied into tmp" : "pointer into the mbuf data (no copy)", r);

	/* Out of range: NULL */
	r = rte_pktmbuf_read(hdr, 95, 10, tmp);
	printf("rte_pktmbuf_read(off=95,len=10) -> %s (pkt_len is 100)\n", r ? "ptr" : "NULL");

	/* Linearize: copies seg 1..n into seg 0's tailroom and frees them.
	 * Note: call it as its own statement. Putting it in the same printf
	 * as m->nb_segs reads nb_segs in unspecified order. */
	printf("\npool in_use before linearize: %u\n", rte_mempool_in_use_count(mp));
	int rc = rte_pktmbuf_linearize(hdr);
	printf("rte_pktmbuf_linearize() = %d\n", rc);
	walk("after linearize", hdr);
	printf("pool in_use after linearize : %u (the two payload segments went back)\n",
	       rte_mempool_in_use_count(mp));
	printf("bytes 16..27 now contiguous : \"%.12s\"\n",
	       rte_pktmbuf_mtod_offset(hdr, char *, 16));

	/* The chain length limit: RTE_MBUF_MAX_NB_SEGS (UINT16_MAX). We fake
	 * a long chain by setting nb_segs, just to see the refusal. */
	struct rte_mbuf *x = seg_with(mp, 'x', 1);
	uint16_t saved = hdr->nb_segs;
	hdr->nb_segs = RTE_MBUF_MAX_NB_SEGS;
	rc = rte_pktmbuf_chain(hdr, x);
	printf("\nchain onto a head with nb_segs=RTE_MBUF_MAX_NB_SEGS(%u) -> %d (%s)\n",
	       RTE_MBUF_MAX_NB_SEGS, rc, rc == -EOVERFLOW ? "-EOVERFLOW" : "?");
	hdr->nb_segs = saved;
	rte_pktmbuf_free(x);

	printf("\nrte_pktmbuf_dump(stdout, hdr, 0):\n");
	rte_pktmbuf_dump(stdout, hdr, 0);

	rte_pktmbuf_free(hdr);   /* frees every segment of the chain */
	printf("pool in_use at the end: %u\n", rte_mempool_in_use_count(mp));
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
