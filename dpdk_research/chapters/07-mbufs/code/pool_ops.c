/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, example 6: pool_ops.c
 *
 * 1. Which mempool handler ("ops") does a pktmbuf pool use?
 *    rte_mbuf_best_mempool_ops() decides: the EAL option
 *    --mbuf-pool-ops-name wins, then a platform choice, then the build
 *    default RTE_MBUF_DEFAULT_MEMPOOL_OPS ("ring_mp_mc").
 * 2. rte_pktmbuf_pool_create_by_ops() forces a handler for one pool.
 * 3. rte_pktmbuf_pool_create_extbuf(): a pool whose mbufs carry PINNED
 *    external data buffers (data lives in memory we provide).
 * 4. rte_pktmbuf_prefree_seg(): the call a PMD makes on TX completion to
 *    decide which segments can go back to the pool in one bulk put.
 *
 * Run twice to see the EAL option at work:
 *   ./pool_ops -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-ops
 *   ./pool_ops -l 0 --no-pci --no-huge -m 64 --file-prefix=ch07-ops --mbuf-pool-ops-name=stack
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_debug.h>
#include <rte_lcore.h>
#include <rte_malloc.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>
#include <rte_mbuf_pool_ops.h>

static const char *ops_of(const struct rte_mempool *mp)
{
	return rte_mempool_get_ops(mp->ops_index)->name;
}

/* cost of one alloc+free pair in ns: one timed run of 20000 bursts */
static double alloc_free_ns(struct rte_mempool *mp)
{
	enum { BURST = 32, ROUNDS = 20000 };
	struct rte_mbuf *b[BURST];
	uint64_t t0 = rte_rdtsc();
	for (int r = 0; r < ROUNDS; r++) {
		if (rte_pktmbuf_alloc_bulk(mp, b, BURST) != 0)
			return -1;
		rte_pktmbuf_free_bulk(b, BURST);
	}
	return (double)(rte_rdtsc() - t0) * 1e9 / rte_get_tsc_hz() / (ROUNDS * BURST);
}

static int cmp_dbl(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

/* median, min and max of 5 runs (course rule: never a single sample) */
static void measure(struct rte_mempool *mp, double *med, double *mn, double *mx)
{
	double v[5];
	alloc_free_ns(mp);                       /* warm-up, not counted */
	for (int i = 0; i < 5; i++)
		v[i] = alloc_free_ns(mp);
	qsort(v, 5, sizeof(v[0]), cmp_dbl);
	*med = v[2]; *mn = v[0]; *mx = v[4];
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	/* ---- 1. who decides ------------------------------------------- */
	const char *u = rte_mbuf_user_mempool_ops();
	const char *p = rte_mbuf_platform_mempool_ops();
	printf("== 1. ops selection ==\n");
	printf("user (--mbuf-pool-ops-name) : %s\n", u ? u : "(not set)");
	printf("platform                    : %s\n", p ? p : "(not set)");
	printf("build default               : %s\n", RTE_MBUF_DEFAULT_MEMPOOL_OPS);
	printf("rte_mbuf_best_mempool_ops() : %s\n", rte_mbuf_best_mempool_ops());

	struct rte_mempool *def = rte_pktmbuf_pool_create("ch07_def", 1023, 0, 0,
			RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (def == NULL)
		rte_exit(EXIT_FAILURE, "pool: %s\n", rte_strerror(rte_errno));
	printf("rte_pktmbuf_pool_create() pool uses ops \"%s\"\n", ops_of(def));

	/* ---- 2. per-pool choice ------------------------------------------ */
	/* cache_size 0 on purpose: every get/put reaches the handler, so the
	 * handler cost is visible (with a cache most calls never reach it). */
	printf("\n== 2. rte_pktmbuf_pool_create_by_ops (cache_size=0) ==\n");
	static const char *names[] = { "ring_mp_mc", "ring_sp_sc", "stack",
				       "lf_stack", "bucket", "no_such_ops" };
	for (unsigned i = 0; i < RTE_DIM(names); i++) {
		char pname[32];
		snprintf(pname, sizeof(pname), "ch07_%u", i);
		struct rte_mempool *mp = rte_pktmbuf_pool_create_by_ops(pname, 1023, 0,
				0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id(), names[i]);
		if (mp == NULL) {
			printf("  %-12s -> NULL, rte_errno=%d (%s)\n", names[i],
			       rte_errno, rte_strerror(rte_errno));
			continue;
		}
		double med, mn, mx;
		unsigned avail = rte_mempool_avail_count(mp);
		measure(mp, &med, &mn, &mx);
		printf("  %-12s -> pool ops \"%s\", avail=%u, alloc+free %5.1f ns/mbuf "
		       "(median of 5, min %.1f max %.1f)\n",
		       names[i], ops_of(mp), avail, med, mn, mx);
		rte_mempool_free(mp);
	}

	/* ---- 3. pinned external buffer pool ----------------------------- */
	printf("\n== 3. rte_pktmbuf_pool_create_extbuf ==\n");
	const uint16_t room = RTE_MBUF_DEFAULT_BUF_SIZE;   /* per-mbuf data room */
	const unsigned n_ext = 64;
	struct rte_pktmbuf_extmem ext = {
		.buf_len  = (size_t)room * (n_ext + 1),
		.elt_size = room,
	};
	ext.buf_ptr = rte_malloc("ch07_extmem", ext.buf_len, RTE_CACHE_LINE_SIZE);
	if (ext.buf_ptr == NULL)
		rte_exit(EXIT_FAILURE, "rte_malloc\n");
	ext.buf_iova = rte_malloc_virt2iova(ext.buf_ptr);

	struct rte_mempool *xp = rte_pktmbuf_pool_create_extbuf("ch07_xpool",
			n_ext, 0, 0, room, rte_socket_id(), &ext, 1);
	if (xp == NULL)
		rte_exit(EXIT_FAILURE, "extbuf pool: %s\n", rte_strerror(rte_errno));
	printf("pool elt_size=%u (mbuf struct only: data is outside), flags=0x%x "
	       "PINNED_EXT_BUF=%d\n", xp->elt_size, rte_pktmbuf_priv_flags(xp),
	       (rte_pktmbuf_priv_flags(xp) & RTE_PKTMBUF_POOL_F_PINNED_EXT_BUF) != 0);
	struct rte_mbuf *a = rte_pktmbuf_alloc(xp);
	struct rte_mbuf *b = rte_pktmbuf_alloc(xp);
	printf("mbuf a: EXTERNAL=%d buf_addr=ext+%td buf_len=%u data_off=%u\n",
	       RTE_MBUF_HAS_EXTBUF(a) ? 1 : 0,
	       (char *)a->buf_addr - (char *)ext.buf_ptr, a->buf_len, a->data_off);
	printf("mbuf b: EXTERNAL=%d buf_addr=ext+%td\n",
	       RTE_MBUF_HAS_EXTBUF(b) ? 1 : 0,
	       (char *)b->buf_addr - (char *)ext.buf_ptr);
	rte_pktmbuf_free(a);
	rte_pktmbuf_free(b);
	printf("after free: in_use=%u (the data buffers stay pinned to their mbufs)\n",
	       rte_mempool_in_use_count(xp));
	rte_mempool_free(xp);
	rte_free(ext.buf_ptr);   /* the pool never owned this memory */

	/* ---- 4. what a PMD does on TX completion ------------------------ */
	printf("\n== 4. rte_pktmbuf_prefree_seg: the TX-completion path ==\n");
	struct rte_mbuf *done[4];
	if (rte_pktmbuf_alloc_bulk(def, done, 4) != 0)
		rte_exit(EXIT_FAILURE, "alloc_bulk\n");
	rte_mbuf_refcnt_update(done[2], 1);     /* someone else still holds #2 */
	printf("4 transmitted segments, refcnt = %u %u %u %u, pool in_use=%u\n",
	       rte_mbuf_refcnt_read(done[0]), rte_mbuf_refcnt_read(done[1]),
	       rte_mbuf_refcnt_read(done[2]), rte_mbuf_refcnt_read(done[3]),
	       rte_mempool_in_use_count(def));

	/* prefree_seg returns the mbuf if it can be recycled now, NULL if
	 * other references remain. Collect the recyclable ones and put them
	 * back with ONE bulk call, like drivers/net/ice/... tx_free_bufs. */
	void *back[32];   /* roomy: rte_memcpy inside put_bulk copies in 32 B chunks */
	unsigned nb = 0;
	for (int i = 0; i < 4; i++) {
		struct rte_mbuf *m = rte_pktmbuf_prefree_seg(done[i]);
		printf("  prefree_seg(#%d) -> %s\n", i, m ? "recyclable" : "NULL (still referenced)");
		if (m != NULL)
			back[nb++] = m;
	}
	rte_mempool_put_bulk(def, back, nb);
	printf("put_bulk(%u) -> pool in_use=%u, #2 refcnt now %u\n", nb,
	       rte_mempool_in_use_count(def), rte_mbuf_refcnt_read(done[2]));
	rte_pktmbuf_free_seg(done[2]);          /* the other owner lets go */
	printf("free_seg(#2) -> pool in_use=%u\n", rte_mempool_in_use_count(def));

	rte_mempool_free(def);
	rte_eal_cleanup();
	return 0;
}
