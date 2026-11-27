/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13 debug lab 4: double_free - "random packets carry the wrong data".
 *
 * Story: an error path frees a bad packet and then jumps to the common
 * cleanup label, which frees it again. A freed mbuf keeps refcnt 1 and
 * looks perfectly valid, so rte_mbuf_sanity_check() and rte_mbuf_check()
 * say nothing, and a release build of DPDK has no mempool cookies. The
 * second free puts the SAME pointer into the pool twice: later two
 * rte_pktmbuf_alloc() calls return the same buffer, and two "different"
 * packets overwrite each other.
 *
 * 200 mbufs are "posted to the NIC RX ring" (held) while the loop runs,
 * so the pool is never full and the duplicate pointers fit into it.
 * When those 200 come back at the end, the pool's ring (capacity = size)
 * has no room for all of them: a release build silently ignores the failed
 * bulk enqueue, and a whole bulk of real mbufs is lost. So a double free is
 * also a leak, and in_use_count lies in both directions.
 *
 * How to see it anyway:
 *   - an audit: take all 'size' objects out of the pool and sort the
 *     pointers: duplicates show up next to each other.
 *   - telemetry /mempool/info,lab_pool: compare common_pool_count with the
 *     number of objects you believe are free.
 *   - a DPDK build with RTE_LIBRTE_MEMPOOL_DEBUG checks object cookies on
 *     every put and panics on the second one (not available in this build).
 * Build with -DFIXED: free in exactly one place (the cleanup label).
 *
 *   ./lab -l 0 --no-pci --no-huge -m 128 --file-prefix=ch13-dbg-dfree
 */
#include "../../ch13_common.h"

#define POOL 511

static int
cmp_ptr(const void *a, const void *b)
{
	uintptr_t x = *(const uintptr_t *)a, y = *(const uintptr_t *)b;

	return x < y ? -1 : x > y;
}

/* returns 0 = consumed, -1 = bad packet */
static int
handle(struct rte_mbuf *m, unsigned int i)
{
	(void)m;
	if (i % 100 == 7) {             /* every 100th packet is "malformed" */
#ifndef FIXED
		rte_pktmbuf_free(m);    /* BUG: the error path frees ...    */
#endif
		return -1;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	static void *objs[POOL];
	static struct rte_mbuf *posted[200];
	struct rte_mempool *mp;
	unsigned int i, bad = 0, dups = 0;
	const char *reason __rte_unused = NULL;
	unsigned int avail;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	/* no per-lcore cache: keeps the counts easy to read */
	mp = rte_pktmbuf_pool_create("lab_pool", POOL, 0, 0,
				     RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
	if (mp == NULL)
		rte_exit(EXIT_FAILURE, "pool failed\n");

	/* 200 buffers waiting in the (pretend) NIC RX ring */
	if (rte_pktmbuf_alloc_bulk(mp, posted, RTE_DIM(posted)) != 0)
		rte_exit(EXIT_FAILURE, "alloc failed\n");

	for (i = 0; i < 1000; i++) {
		struct rte_mbuf *m = rte_pktmbuf_alloc(mp);

		if (m == NULL)
			break;
		ch13_make_udp(m, 64, i);
		if (handle(m, i) < 0) {
			bad++;
#ifndef FIXED
			/* is the already-freed mbuf detectably "bad"? */
			if (bad == 1)
				printf("after the first free: rte_mbuf_check() = %d, refcnt=%u\n",
				       rte_mbuf_check(m, 1, &reason),
				       rte_mbuf_refcnt_read(m));
#endif
			goto cleanup;   /* ... and so does the cleanup label */
		}
cleanup:
		rte_pktmbuf_free(m);
	}
	printf("processed %u packets, %u malformed\n", i, bad);
	printf("with 200 posted: size=%u avail=%u in_use=%u (should be avail=311 in_use=200)\n",
	       mp->size, rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp));
	printf("READY\n");
	fflush(stdout);
	sleep(1);                       /* time for a telemetry query */
	rte_pktmbuf_free_bulk(posted, RTE_DIM(posted));   /* port stopped */
	printf("after returning the 200: avail=%u in_use=%u\n",
	       rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp));

	/* the audit: everything is idle now, so take out every free object */
	avail = rte_mempool_avail_count(mp);
	if (rte_mempool_get_bulk(mp, objs, avail) == 0) {
		qsort(objs, avail, sizeof(void *), cmp_ptr);
		for (i = 1; i < avail; i++)
			if (objs[i] == objs[i - 1])
				dups++;
		printf("audit: took the %u free objects out of the pool: %u duplicate "
		       "pointers; %u mbufs missing from a pool of %u\n",
		       avail, dups, mp->size - avail + dups, mp->size);
		rte_mempool_put_bulk(mp, objs, avail);
	}
	printf("%s\n", dups || avail != mp->size ?
	       "FAIL: duplicates in the pool and mbufs lost" :
	       "PASS: every object is unique and back in the pool");
	rte_eal_cleanup();
	return 0;
}
