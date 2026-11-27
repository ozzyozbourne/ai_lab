/* SPDX-License-Identifier: BSD-3-Clause
 *
 * hello_memory.c - Chapter 4, example 1.
 *
 * The first things you do with DPDK memory:
 *   - ask EAL which IOVA mode it picked and how much memory is mapped,
 *   - allocate with rte_malloc / rte_zmalloc / rte_calloc / rte_realloc,
 *   - check alignment and the usable size (rte_malloc_validate),
 *   - read heap statistics before and after,
 *   - print each buffer's virtual address (VA) and IO virtual address (IOVA),
 *   - ask for memory on a NUMA node that does not exist (with hugepages it
 *     fails: an explicit socket never falls back; with --no-huge EAL ignores
 *     the socket because 4 KB anonymous memory has no node).
 *
 * Run it twice and compare the va/iova columns:
 *   ./hello_memory -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-hm    (IOVA = VA)
 *   ./hello_memory -l 0 --no-pci -m 64 --file-prefix=ch04-hm2             (IOVA = PA as root)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_memory.h>
#include <rte_malloc.h>

static const char *iova_mode_str(enum rte_iova_mode m)
{
	switch (m) {
	case RTE_IOVA_PA: return "PA (device uses physical addresses)";
	case RTE_IOVA_VA: return "VA (device uses our virtual addresses)";
	default:          return "DC (don't care)";
	}
}

/* Print the heap statistics of NUMA node 0 in one line. */
static void heap_line(const char *when)
{
	struct rte_malloc_socket_stats st;

	if (rte_malloc_get_socket_stats(0, &st) < 0) {
		printf("  %-22s stats unavailable\n", when);
		return;
	}
	printf("  %-22s total=%9zu  alloc=%9zu  free=%9zu  allocs=%3u  free-elems=%u\n",
	       when, st.heap_totalsz_bytes, st.heap_allocsz_bytes,
	       st.heap_freesz_bytes, st.alloc_count, st.free_count);
}

/* One row of the buffer table: address, alignment, usable size, IOVA. */
static void show(const char *what, const void *p)
{
	size_t usable = 0;

	if (p == NULL) {
		printf("  %-28s NULL (%s)\n", what, rte_strerror(rte_errno));
		return;
	}
	rte_malloc_validate(p, &usable);         /* 0 = it is a live rte_malloc block */
	printf("  %-28s va=%p  iova=0x%010" PRIx64 "  %s  usable=%zu\n",
	       what, p, rte_mem_virt2iova(p),
	       ((uintptr_t)p % 4096 == 0) ? "4K-aligned " :
	       ((uintptr_t)p % 64 == 0)   ? "64B-aligned" : "unaligned  ",
	       usable);
}

int main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}

	/* 1. What did EAL set up? */
	printf("IOVA mode        : %s\n", iova_mode_str(rte_eal_iova_mode()));
	printf("hugepages        : %s\n", rte_eal_has_hugepages() ? "yes" : "no (--no-huge, 4 KB pages)");
	printf("physical addrs   : %s\n", rte_eal_using_phys_addrs() ? "readable" : "not used");
	printf("mapped memory    : %" PRIu64 " MB\n", rte_eal_get_physmem_size() >> 20);
	printf("NUMA nodes       : %u (this lcore is on node %u)\n", rte_socket_count(), rte_socket_id());

	/* 2. Allocate a few buffers and look at them. */
	printf("\nheap of node 0:\n");
	heap_line("before");

	char *a = rte_malloc("demo", 100, 0);      /* align 0 = cache line (64 B) */
	char *b = rte_malloc("demo", 100, 4096);   /* page aligned */
	char *z = rte_zmalloc("demo", 1500, 0);    /* zeroed, like calloc */
	int  *c = rte_calloc("demo", 256, sizeof(int), 0);
	heap_line("after 4 allocations");

	printf("\nbuffers:\n");
	show("rte_malloc(100, 0)", a);
	show("rte_malloc(100, 4096)", b);
	show("rte_zmalloc(1500, 0)", z);
	show("rte_calloc(256, 4, 0)", c);

	/* rte_zmalloc really zeroes: check every byte. */
	int nonzero = 0;
	for (int i = 0; i < 1500; i++)
		nonzero += (z[i] != 0);
	printf("  zmalloc'd bytes that are not zero: %d\n", nonzero);

	/* rte_realloc may move the block, exactly like realloc(). */
	strcpy(a, "kept across realloc");
	char *a2 = rte_realloc(a, 64 * 1024, 0);
	show("rte_realloc(a, 64K, 0)", a2);
	printf("  content after realloc: \"%s\" (%s)\n", a2, a2 == a ? "same address" : "moved");
	a = a2;

	/* 3. Ask for memory on NUMA node 1. This VM has one node, so there is no
	 * heap for node 1. An explicit socket never falls back to another one. */
	printf("\nNUMA:\n");
	rte_errno = 0;
	void *remote = rte_malloc_socket("demo", 4096, 0, 1);
	if (remote == NULL)
		/* rte_malloc*() report failure only through NULL: rte_errno
		 * is left untouched (we zeroed it above, it is still 0). */
		printf("  rte_malloc_socket(..., socket 1) = NULL  rte_errno=%d (not set by rte_malloc)\n",
		       rte_errno);
	else    /* with --no-huge EAL treats every socket as SOCKET_ID_ANY */
		printf("  rte_malloc_socket(..., socket 1) = %p  (accepted: no-huge memory has no node)\n",
		       remote);
	void *any = rte_malloc_socket("demo", 4096, 0, SOCKET_ID_ANY);
	printf("  rte_malloc_socket(..., SOCKET_ID_ANY) = %p (ok, node %d)\n",
	       any, rte_socket_id());

	/* 4. Free everything with rte_free (never with free()). */
	rte_free(any);
	rte_free(remote);                           /* NULL is fine */
	rte_free(a);
	rte_free(b);
	rte_free(z);
	rte_free(c);
	rte_free(NULL);                             /* allowed, like free(NULL) */
	heap_line("after rte_free");

	rte_eal_cleanup();
	return 0;
}
