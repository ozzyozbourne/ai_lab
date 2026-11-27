/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, example 4: clone_extbuf.c
 *
 * Part A, the multicast pattern (as in examples/ipv4_multicast):
 *   one payload mbuf, three destinations. For each destination we
 *   allocate a small private header mbuf and chain it in front of a CLONE
 *   of the payload. A clone is an "indirect" mbuf: its buf_addr points at
 *   the payload's buffer, and the payload's refcnt goes up by one.
 *   We watch refcnt go 1 -> 4 -> 0 and the pool counters move.
 *
 * Part B, an external buffer: the data lives in memory we allocated with
 *   rte_malloc(), described by a struct rte_mbuf_ext_shared_info that holds
 *   its own refcnt and a free callback. Clones bump the shared-info refcnt,
 *   and our callback runs when the last reference is dropped.
 *
 * Run: ./clone_extbuf -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-clone
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_malloc.h>
#include <rte_mbuf.h>

#define NDEST 3

static struct rte_mempool *data_pool, *hdr_pool, *clone_pool;

static void pools(const char *when)
{
	printf("  %-34s in_use: data=%u hdr=%u clone=%u\n", when,
	       rte_mempool_in_use_count(data_pool),
	       rte_mempool_in_use_count(hdr_pool),
	       rte_mempool_in_use_count(clone_pool));
}

/* ---- Part B: called by the mbuf library when the last user is gone ---- */
static void ext_free_cb(void *addr, void *opaque)
{
	printf("  >>> ext_free_cb(addr=%p, opaque=\"%s\"): freeing external buffer\n",
	       addr, (const char *)opaque);
	rte_free(addr);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	/* Three pools, like ipv4_multicast:
	 *  data_pool : full-size mbufs that carry the payload
	 *  hdr_pool  : small mbufs (headroom + 64 B) for per-destination headers
	 *  clone_pool: data_room_size = 0, the mbuf struct only (128 B),
	 *              because a clone never uses its own buffer */
	data_pool  = rte_pktmbuf_pool_create("ch07_data", 63, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	hdr_pool   = rte_pktmbuf_pool_create("ch07_hdr", 63, 0, 0,
			RTE_PKTMBUF_HEADROOM + 64, rte_socket_id());
	clone_pool = rte_pktmbuf_pool_create("ch07_clone", 63, 0, 0, 0,
			rte_socket_id());
	if (!data_pool || !hdr_pool || !clone_pool)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	printf("elt_size: data=%u hdr=%u clone=%u\n", data_pool->elt_size,
	       hdr_pool->elt_size, clone_pool->elt_size);

	/* ================= Part A: clones ================================ */
	printf("\n== Part A: one payload, %d destinations ==\n", NDEST);
	struct rte_mbuf *payload = rte_pktmbuf_alloc(data_pool);
	memcpy(rte_pktmbuf_append(payload, 32), "shared payload, written once....", 32);
	printf("payload refcnt=%u\n", rte_mbuf_refcnt_read(payload));
	pools("after payload alloc");

	struct rte_mbuf *pkt[NDEST];
	for (int d = 0; d < NDEST; d++) {
		struct rte_mbuf *h = rte_pktmbuf_alloc(hdr_pool);
		char hb[16];
		snprintf(hb, sizeof(hb), "DEST-%d: ", d);   /* 8 header bytes */
		memcpy(rte_pktmbuf_append(h, 8), hb, 8);

		/* clone = allocate from clone_pool + rte_pktmbuf_attach() */
		struct rte_mbuf *c = rte_pktmbuf_clone(payload, clone_pool);
		if (c == NULL)
			rte_exit(EXIT_FAILURE, "clone failed\n");
		if (rte_pktmbuf_chain(h, c) != 0)
			rte_exit(EXIT_FAILURE, "chain failed\n");
		pkt[d] = h;
		printf("dest %d: clone %p INDIRECT=%d buf_addr %s payload's, "
		       "from_indirect==payload: %d -> payload refcnt=%u\n",
		       d, (void *)c, RTE_MBUF_CLONED(c) ? 1 : 0,
		       c->buf_addr == payload->buf_addr ? "==" : "!=",
		       rte_mbuf_from_indirect(c) == payload,
		       rte_mbuf_refcnt_read(payload));
	}
	pools("after 3 header+clone chains");

	/* each packet: 8 header bytes from its own buffer + the shared 32 */
	for (int d = 0; d < NDEST; d++) {
		char flat[40];
		const char *v = rte_pktmbuf_read(pkt[d], 0, 40, flat);
		printf("pkt %d: nb_segs=%u pkt_len=%u \"%.40s\"\n",
		       d, pkt[d]->nb_segs, pkt[d]->pkt_len, v);
	}

	/* The sender no longer needs its own reference: drop it. The data
	 * stays alive because the clones still point at it. */
	rte_pktmbuf_free(payload);
	printf("free(payload)      -> payload refcnt=%u (buffer still alive)\n",
	       rte_mbuf_refcnt_read(payload));    /* we may peek: refcnt > 0 */
	pools("after free(payload)");

	/* "Transmit" = the driver frees each packet after sending it. */
	for (int d = 0; d < NDEST; d++) {
		uint16_t before = rte_mbuf_refcnt_read(payload);
		rte_pktmbuf_free(pkt[d]);
		if (before > 1)
			printf("free(pkt %d)        -> payload refcnt=%u\n", d,
			       rte_mbuf_refcnt_read(payload));
		else
			printf("free(pkt %d)        -> last reference: payload "
			       "returned to data_pool\n", d);
		pools("");
	}

	/* ================= Part B: external buffer ======================= */
	printf("\n== Part B: external buffer with a free callback ==\n");
	uint16_t buf_len = 1024;
	void *ext = rte_malloc("ch07_ext", buf_len, RTE_CACHE_LINE_SIZE);
	if (ext == NULL)
		rte_exit(EXIT_FAILURE, "rte_malloc\n");

	/* Puts the shared info at the END of the buffer and shrinks buf_len */
	struct rte_mbuf_ext_shared_info *shinfo =
		rte_pktmbuf_ext_shinfo_init_helper(ext, &buf_len, ext_free_cb,
						   (void *)"my 1 KiB buffer");
	printf("shinfo at ext+%td, usable buf_len=%u, shinfo refcnt=%u\n",
	       (char *)shinfo - (char *)ext, buf_len,
	       rte_mbuf_ext_refcnt_read(shinfo));

	/* Any mbuf can carry an external buffer; the clone pool's 128 B
	 * mbufs are perfect because their own buffer is empty anyway. */
	struct rte_mbuf *em = rte_pktmbuf_alloc(clone_pool);
	rte_pktmbuf_attach_extbuf(em, ext, rte_malloc_virt2iova(ext), buf_len, shinfo);
	rte_pktmbuf_reset_headroom(em);  /* data_off = min(headroom, buf_len) */
	memcpy(rte_pktmbuf_append(em, 16), "external data!!!", 16);
	printf("em: EXTERNAL=%d buf_addr==ext %d data_off=%u data_len=%u mbuf refcnt=%u\n",
	       RTE_MBUF_HAS_EXTBUF(em) ? 1 : 0, em->buf_addr == ext,
	       em->data_off, em->data_len, rte_mbuf_refcnt_read(em));

	struct rte_mbuf *c1 = rte_pktmbuf_clone(em, clone_pool);
	struct rte_mbuf *c2 = rte_pktmbuf_clone(em, clone_pool);
	printf("2 clones: shinfo refcnt=%u, em mbuf refcnt=%u (clones of an extbuf "
	       "count in shinfo, not in em)\n",
	       rte_mbuf_ext_refcnt_read(shinfo), rte_mbuf_refcnt_read(em));

	printf("free(em)\n");
	rte_pktmbuf_free(em);
	printf("  shinfo refcnt=%u\n", rte_mbuf_ext_refcnt_read(shinfo));
	printf("free(c1)\n");
	rte_pktmbuf_free(c1);
	printf("  shinfo refcnt=%u\n", rte_mbuf_ext_refcnt_read(shinfo));
	printf("free(c2)  (last reference)\n");
	rte_pktmbuf_free(c2);
	pools("end");

	rte_mempool_free(data_pool);
	rte_mempool_free(hdr_pool);
	rte_mempool_free(clone_pool);
	rte_eal_cleanup();
	return 0;
}
