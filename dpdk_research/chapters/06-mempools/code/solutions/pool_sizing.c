/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 6, exercise 1 solution: pool_sizing.c
 *
 * 2 ports x 2 queues x 1024 descriptors, 4 lcores with cache 256, bursts of
 * 32. Where can an mbuf be at the worst moment?
 *   - in an Rx descriptor ring, waiting for a packet  2*2*1024 = 4096
 *   - in a Tx descriptor ring, sent but not yet freed  2*2*1024 = 4096
 *   - in a per-lcore cache (each can be full)          4*256    = 1024
 *   - in the application's hands (one burst/lcore)     4*32     =  128
 *                                                      total   = 9344
 * The program checks the arithmetic by actually putting objects in all those
 * places at once: it holds the "ring" and "burst" objects directly
 * (cache=NULL), then fills each lcore's cache to its full 256 on that lcore.
 * With n = 9344 every cache fills and the backend ends at 0; with n - 1 the
 * last lcore cannot fill its cache: in a real app, that is where a get fails.
 *
 * Run:  ./pool_sizing -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch06-size
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_mempool.h>
#include <rte_debug.h>

#define PORTS 2
#define QUEUES 2
#define DESC 1024
#define CACHE 256
#define BURST 32

static struct rte_mempool *mp;

/* Leaves this lcore's cache completely full (256): two refills of 128 are
 * handed out, then both halves are put back. */
static int
fill_cache(void *arg)
{
	void *a[CACHE / 2], *b[CACHE / 2];
	(void)arg;
	if (rte_mempool_get_bulk(mp, a, CACHE / 2) == 0) {
		if (rte_mempool_get_bulk(mp, b, CACHE / 2) == 0)
			rte_mempool_put_bulk(mp, b, CACHE / 2);
		rte_mempool_put_bulk(mp, a, CACHE / 2);
	}
	return 0;
}

int
main(int argc, char **argv)
{
	unsigned int nl, rings, hands, need, lc, n, t;
	void **held;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	nl = rte_lcore_count();
	rings = 2 * PORTS * QUEUES * DESC;   /* Rx + Tx rings */
	hands = nl * BURST;
	need = rings + nl * CACHE + hands;
	printf("Rx+Tx rings %u + %u lcores x cache %d + %u lcores x burst %d = %u objects\n",
	       rings, nl, CACHE, nl, BURST, need);
	held = malloc(sizeof(void *) * (rings + hands));

	for (t = 0; t < 2; t++) {
		unsigned int full = 0;
		n = need - t;
		mp = rte_mempool_create("ch06_size", n, 64, CACHE, 0, NULL, NULL,
					NULL, NULL, rte_socket_id(), 0);
		if (mp == NULL)
			rte_exit(EXIT_FAILURE, "create: %s\n", rte_strerror(rte_errno));
		/* descriptors + bursts in hand: taken around the caches */
		if (rte_mempool_generic_get(mp, held, rings + hands, NULL) != 0)
			rte_exit(EXIT_FAILURE, "cannot even hold the rings\n");
		/* now every lcore fills its own cache, one after another */
		RTE_LCORE_FOREACH(lc) {
			if (lc == rte_lcore_id())
				fill_cache(NULL);
			else {
				rte_eal_remote_launch(fill_cache, NULL, lc);
				rte_eal_wait_lcore(lc);
			}
		}
		printf("n=%-5u caches:", n);
		RTE_LCORE_FOREACH(lc) {
			unsigned int len = rte_mempool_default_cache(mp, lc)->len;
			full += (len == CACHE);
			printf(" %u", len);
		}
		printf(" | full caches %u/%u -> %s\n", full, nl,
		       full == nl ? "worst case fits" : "TOO SMALL: some lcore would fail a get");
		/* hand the objects back; caches are flushed when the pool is freed */
		rte_mempool_generic_put(mp, held, rings + hands, NULL);
		rte_mempool_free(mp);
	}
	printf("round up to 2^q - 1 for a ring-backed pool: %u\n",
	       (unsigned int)rte_align32pow2(need + 1) - 1);
	free(held);
	rte_eal_cleanup();
	return 0;
}
