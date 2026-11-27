/* SPDX-License-Identifier: BSD-3-Clause
 *
 * solutions/no_cap.c - Exercise 2: -m is a floor, not a cap.
 *
 * Starts with -m 32 (32 MB pinned at init) and allocates 64 MB in one block.
 * In dynamic memory mode the heap simply maps more hugepages. With
 * --numa-limit 32 the same allocation fails, because a limit (a built-in
 * allocation validator) refuses to grow the heap past 32 MB.
 *
 *   ./solutions/no_cap -l 0 --no-pci -m 32 --huge-unlink --file-prefix=ch04-ex2
 *   ./solutions/no_cap -l 0 --no-pci -m 32 --numa-limit 32 --huge-unlink --file-prefix=ch04-ex2
 */
#include <stdio.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_malloc.h>
#include <rte_memory.h>

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) {
		fprintf(stderr, "rte_eal_init: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	printf("mapped at start: %" PRIu64 " MB\n", rte_eal_get_physmem_size() >> 20);
	void *big = rte_malloc(NULL, 64 << 20, 0);
	printf("rte_malloc(64 MB) = %s\n", big ? "OK" : "NULL");
	printf("mapped now:      %" PRIu64 " MB\n", rte_eal_get_physmem_size() >> 20);
	rte_free(big);
	printf("after rte_free:  %" PRIu64 " MB (pages above the -m floor are returned)\n",
	       rte_eal_get_physmem_size() >> 20);
	rte_eal_cleanup();
	return 0;
}
