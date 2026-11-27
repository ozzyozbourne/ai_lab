/* SPDX-License-Identifier: BSD-3-Clause
 *
 * solutions/overhead.c - Exercise 1: what does an rte_malloc block cost?
 *
 * Allocates N objects of 1 KB and compares heap statistics before and after.
 * The difference per object = requested size + malloc_elem header (64 B,
 * one cache line) + rounding of the size up to a cache-line multiple.
 *
 *   ./solutions/overhead -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-ex1 [-- N SIZE]
 */
#include <stdio.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_malloc.h>

int main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0) {
		fprintf(stderr, "rte_eal_init: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	argc -= ret;
	argv += ret;
	int n = argc > 1 ? atoi(argv[1]) : 100;
	size_t size = argc > 2 ? strtoul(argv[2], NULL, 0) : 1024;
	if (n < 1 || n > 100000)
		n = 100;

	void **obj = calloc(n, sizeof(*obj));
	struct rte_malloc_socket_stats a, b;

	rte_malloc_get_socket_stats(0, &a);
	for (int i = 0; i < n; i++)
		obj[i] = rte_malloc(NULL, size, 0);
	rte_malloc_get_socket_stats(0, &b);

	size_t used = b.heap_allocsz_bytes - a.heap_allocsz_bytes;
	size_t usable;
	rte_malloc_validate(obj[0], &usable);
	printf("%d x rte_malloc(%zu): heap_allocsz grew by %zu bytes\n", n, size, used);
	printf("  per object: %zu bytes = %zu usable + %zu overhead (%.1f%%)\n",
	       used / n, usable, used / n - usable, 100.0 * (used / n - size) / size);
	printf("  alloc_count %u -> %u, free elements %u -> %u\n",
	       a.alloc_count, b.alloc_count, a.free_count, b.free_count);
	printf("  neighbours are %td bytes apart\n", (char *)obj[0] - (char *)obj[1]);

	for (int i = 0; i < n; i++)
		rte_free(obj[i]);
	free(obj);
	rte_eal_cleanup();
	return 0;
}
