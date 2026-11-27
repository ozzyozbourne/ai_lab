/* SPDX-License-Identifier: BSD-3-Clause
 *
 * memzones.c - Chapter 4, example 4.
 *
 * A memzone is a named, aligned block of DPDK memory whose descriptor lives
 * in shared memory, so any thread (or a secondary process, ch16) can find it
 * by name. This program:
 *   1. limits the memzone table to 4 entries (rte_memzone_max_set, before init)
 *   2. reserves zones with plain, aligned and bounded variants
 *   3. looks one up by name, walks and dumps the table
 *   4. triggers the two classic errors: EEXIST (same name) and ENOSPC (table full)
 *   5. frees a zone and shows the name can be reused
 *
 *   ./memzones -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-mz
 */
#include <stdio.h>
#include <string.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_memzone.h>

static void print_mz(const char *what, const struct rte_memzone *mz)
{
	if (mz == NULL) {
		printf("  %-34s -> NULL, rte_errno=%d %s (%s)\n", what, rte_errno,
		       rte_errno == EEXIST ? "EEXIST" : rte_errno == ENOSPC ? "ENOSPC" :
		       rte_errno == ENOMEM ? "ENOMEM" : rte_errno == EINVAL ? "EINVAL" :
		       rte_errno == ENAMETOOLONG ? "ENAMETOOLONG" : "",
		       rte_strerror(rte_errno));
		return;
	}
	printf("  %-34s -> \"%s\" va=%p len=%zu socket=%d\n",
	       what, mz->name, mz->addr, mz->len, mz->socket_id);
}

/* rte_memzone_walk() callback */
static void walk_cb(const struct rte_memzone *mz, void *arg)
{
	int *n = arg;
	printf("    [%d] %-10s %8zu bytes at %p\n", (*n)++, mz->name, mz->len, mz->addr);
}

int main(int argc, char **argv)
{
	/* The table size is fixed at init time (default 2560 entries). */
	if (rte_memzone_max_set(4) != 0)
		printf("rte_memzone_max_set failed\n");

	if (rte_eal_init(argc, argv) < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	printf("memzone table size: %zu\n\n", rte_memzone_max_get());

	printf("reserve:\n");
	const struct rte_memzone *cfg = rte_memzone_reserve("app_cfg", 4096, SOCKET_ID_ANY, 0);
	print_mz("reserve(app_cfg, 4096)", cfg);

	const struct rte_memzone *ring = rte_memzone_reserve_aligned("rx_ring", 16384,
			SOCKET_ID_ANY, RTE_MEMZONE_IOVA_CONTIG, 4096);
	print_mz("reserve_aligned(rx_ring, 16K, 4K)", ring);
	printf("    rx_ring va %% 4096 = %lu, iova=0x%" PRIx64 "\n",
	       (unsigned long)((uintptr_t)ring->addr % 4096), ring->iova);

	/* bounded: the zone must not cross a 1 MB boundary (think: a device
	 * that can only DMA within one 1 MB window). */
	const struct rte_memzone *bnd = rte_memzone_reserve_bounded("stats", 300000,
			SOCKET_ID_ANY, 0, 64, 1 << 20);
	print_mz("reserve_bounded(stats, 300000, 1M)", bnd);
	uintptr_t start = (uintptr_t)bnd->addr, end = start + bnd->len - 1;
	printf("    first byte in MB #%lu, last byte in MB #%lu -> %s\n",
	       (unsigned long)(start >> 20), (unsigned long)(end >> 20),
	       (start >> 20) == (end >> 20) ? "does not cross" : "CROSSES");

	printf("\nlookup by name:\n");
	const struct rte_memzone *found = rte_memzone_lookup("rx_ring");
	printf("  rte_memzone_lookup(\"rx_ring\") = %p (%s)\n", (const void *)found,
	       found == ring ? "same descriptor" : "different!");
	printf("  rte_memzone_lookup(\"nope\")    = %p\n",
	       (const void *)rte_memzone_lookup("nope"));

	printf("\nerrors:\n");
	print_mz("reserve(app_cfg) again", rte_memzone_reserve("app_cfg", 64, SOCKET_ID_ANY, 0));
	/* names are at most RTE_MEMZONE_NAMESIZE - 1 = 31 characters */
	print_mz("reserve(<32-character name>)",
		 rte_memzone_reserve("a_name_that_is_32_characters_xxx", 64, SOCKET_ID_ANY, 0));
	print_mz("reserve(extra1)  [4th entry]", rte_memzone_reserve("extra1", 64, SOCKET_ID_ANY, 0));
	print_mz("reserve(extra2)  [5th entry]", rte_memzone_reserve("extra2", 64, SOCKET_ID_ANY, 0));

	printf("\nrte_memzone_walk:\n");
	int n = 0;
	rte_memzone_walk(walk_cb, &n);

	printf("\nfree app_cfg and reuse the name:\n");
	printf("  rte_memzone_free(app_cfg) = %d\n", rte_memzone_free(cfg));
	print_mz("reserve(app_cfg, 128)", rte_memzone_reserve("app_cfg", 128, SOCKET_ID_ANY, 0));

	rte_memzone_free(bnd);   /* keeps the dump short: 300 KB = 74 small pages */
	printf("\nrte_memzone_dump(stdout) after freeing \"stats\":\n");
	rte_memzone_dump(stdout);

	rte_eal_cleanup();
	return 0;
}
