/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, exercise 2 (medium) solution: clone_corrupt.c
 *
 * A clone shares the data buffer with the original. Two ways that bites:
 *   test 1: writing payload bytes through the clone changes the original
 *   test 2: prepending a header on two clones writes into the SAME
 *           headroom bytes of the shared buffer: the second header
 *           overwrites the first
 * The fix: rte_pktmbuf_copy() makes a deep copy with its own buffer, or
 * (for headers) prepend a separate header mbuf as clone_extbuf.c does.
 *
 * Run: ./clone_corrupt -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-corrupt
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_mbuf.h>

static int same(const char *name, const struct rte_mbuf *m, const char *expect)
{
	int ok = memcmp(rte_pktmbuf_mtod(m, const char *), expect, strlen(expect)) == 0;
	printf("  %-9s \"%.*s\" %s\n", name, (int)m->data_len,
	       rte_pktmbuf_mtod(m, const char *), ok ? "(as expected)" : "<-- CHANGED");
	return ok;
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	struct rte_mempool *mp = rte_pktmbuf_pool_create("ch07_cc", 63, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	struct rte_mempool *cp = rte_pktmbuf_pool_create("ch07_ccl", 63, 0, 0, 0,
			rte_socket_id());
	if (mp == NULL || cp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	struct rte_mbuf *orig = rte_pktmbuf_alloc(mp);
	memcpy(rte_pktmbuf_append(orig, 12), "ORIGINAL....", 12);

	printf("test 1: write through a clone\n");
	struct rte_mbuf *cl = rte_pktmbuf_clone(orig, cp);
	memcpy(rte_pktmbuf_mtod(cl, char *), "CLONE-WROTE!", 12);
	int ok1 = same("original", orig, "ORIGINAL....");

	printf("fix 1: rte_pktmbuf_copy, then write the copy\n");
	memcpy(rte_pktmbuf_mtod(orig, char *), "ORIGINAL....", 12);   /* restore */
	struct rte_mbuf *cpy = rte_pktmbuf_copy(orig, mp, 0, UINT32_MAX);
	memcpy(rte_pktmbuf_mtod(cpy, char *), "COPY-WROTE!!", 12);
	int okf = same("original", orig, "ORIGINAL....");
	same("copy", cpy, "COPY-WROTE!!");
	printf("  copy buf_addr %s orig buf_addr, copy refcnt=%u, orig refcnt=%u\n",
	       cpy->buf_addr == orig->buf_addr ? "==" : "!=",
	       rte_mbuf_refcnt_read(cpy), rte_mbuf_refcnt_read(orig));

	printf("test 2: prepend a header on two clones\n");
	struct rte_mbuf *c2 = rte_pktmbuf_clone(orig, cp);
	memcpy(rte_pktmbuf_prepend(cl, 4), "AAA:", 4);   /* dest A */
	memcpy(rte_pktmbuf_prepend(c2, 4), "BBB:", 4);   /* dest B, same bytes! */
	int ok2 = same("clone A", cl, "AAA:");
	same("clone B", c2, "BBB:");

	printf("verdict: test1 %s, fix %s, test2 %s\n",
	       ok1 ? "no corruption" : "CORRUPTED the original",
	       okf ? "original intact" : "still corrupted",
	       ok2 ? "no corruption" : "header A was overwritten by B");

	rte_pktmbuf_free(cl);
	rte_pktmbuf_free(c2);
	rte_pktmbuf_free(cpy);
	rte_pktmbuf_free(orig);
	rte_mempool_free(cp);
	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
