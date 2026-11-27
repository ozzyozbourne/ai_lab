/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, example 7: debug_aids.c
 *
 * Tools for catching mbuf bugs, and one bug they exist for.
 *   1. rte_mbuf_check(): validates an mbuf and returns a reason string.
 *      We break a good mbuf in four typical ways and ask it what is wrong.
 *      (rte_mbuf_sanity_check() does the same checks but PANICS; the
 *      library calls it everywhere only when built with
 *      RTE_LIBRTE_MBUF_DEBUG.)
 *   2. A double free. Without debug checks nothing complains: the same
 *      pointer simply sits in the pool twice, and two later allocations
 *      return THE SAME mbuf to two different users.
 *   3. mbuf history (25.11+): rte_mbuf_history_dump_all() records the
 *      life of every mbuf, but only in a build with RTE_MBUF_HISTORY_DEBUG.
 *      Here we show what this (non-debug) build says.
 *
 * Run: ./debug_aids -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-dbg
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_mbuf.h>
#include <rte_mbuf_history.h>

static void check(const char *what, const struct rte_mbuf *m)
{
	const char *reason = NULL;
	int rc = rte_mbuf_check(m, 1, &reason);
	printf("  %-36s -> %s%s\n", what, rc == 0 ? "OK" : "INVALID: ",
	       rc == 0 ? "" : reason);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	/* cache_size = 0 so a free goes straight back to the shared store and
	 * the next alloc takes it back out (a LIFO handler makes it obvious) */
	struct rte_mempool *mp = rte_pktmbuf_pool_create_by_ops("ch07_dbg", 63, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id(), "stack");
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));

	printf("== 1. rte_mbuf_check ==\n");
	printf("RTE_LIBRTE_MBUF_DEBUG is %s in this build\n",
#ifdef RTE_LIBRTE_MBUF_DEBUG
	       "ON"
#else
	       "OFF (library-internal checks compiled out)"
#endif
	);
	struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
	rte_pktmbuf_append(m, 100);
	check("fresh mbuf with 100 bytes", m);

	m->data_len = 2100;                       /* bigger than buffer - headroom */
	m->pkt_len = 2100;
	check("data_len=2100 (overruns buf_len)", m);
	m->data_len = m->pkt_len = 100;

	m->pkt_len = 140;                         /* chain bookkeeping forgotten */
	check("pkt_len=140 but one 100 B segment", m);
	m->pkt_len = 100;

	m->nb_segs = 2;
	check("nb_segs=2 but next == NULL", m);
	m->nb_segs = 1;

	rte_mbuf_refcnt_set(m, 0);
	check("refcnt=0 (already freed?)", m);
	rte_mbuf_refcnt_set(m, 1);
	check("repaired", m);

	printf("\n== 2. a double free goes unnoticed ==\n");
	/* Other packets are in flight, as in any real app. (With a completely
	 * full pool the second put would not fit in the stack and would be
	 * dropped, hiding the bug.) */
	struct rte_mbuf *busy[4];
	if (rte_pktmbuf_alloc_bulk(mp, busy, 4) != 0)
		rte_exit(EXIT_FAILURE, "alloc_bulk\n");
	printf("m=%p, in_use=%u (m + 4 other packets)\n", (void *)m,
	       rte_mempool_in_use_count(mp));
	rte_pktmbuf_free(m);
	printf("free(m)         in_use=%u avail=%u\n",
	       rte_mempool_in_use_count(mp), rte_mempool_avail_count(mp));
	rte_pktmbuf_free(m);                      /* BUG: second free */
	printf("free(m) again   in_use=%u avail=%u   <- the counters say one mbuf too many is free\n",
	       rte_mempool_in_use_count(mp), rte_mempool_avail_count(mp));
	struct rte_mbuf *a = rte_pktmbuf_alloc(mp);
	struct rte_mbuf *b = rte_pktmbuf_alloc(mp);
	printf("alloc -> a=%p\nalloc -> b=%p   %s\n", (void *)a, (void *)b,
	       a == b ? "SAME mbuf handed out twice: two owners, silent corruption"
		      : "different");
	/* Repair the pool so we can exit cleanly: give the duplicate back once. */
	rte_pktmbuf_free(a);
	rte_pktmbuf_free_bulk(busy, 4);

	printf("\n== 3. mbuf history ==\n");
	rte_mbuf_history_dump_all(stdout);
	printf("(rebuild DPDK with -Dc_args=-DRTE_MBUF_HISTORY_DEBUG to record it;\n"
	       " usertools/dpdk-mbuf-history-parser.py decodes the dump)\n");

	rte_mempool_free(mp);
	rte_eal_cleanup();
	return 0;
}
