/* SPDX-License-Identifier: BSD-3-Clause
 *
 * heap_events.c - Chapter 4, example 5 (deep dive).
 *
 * Part A: dynamic memory. With hugepages and without --legacy-mem the heap
 *   grows by mapping new pages and shrinks by unmapping them. A memory event
 *   callback sees every map (ALLOC) and unmap (FREE). Pages pinned with -m
 *   are never returned, so small allocations there produce no events.
 * Part B: an allocation validator vetoes heap growth above a limit.
 * Part C: an external heap built from memory we mmap()ed ourselves.
 *
 *   ./heap_events -l 0 --no-pci --huge-unlink --file-prefix=ch04-ev        (events)
 *   ./heap_events -l 0 --no-pci -m 16 --huge-unlink --file-prefix=ch04-ev  (pinned floor)
 *   ./heap_events -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-ev      (ENOTSUP)
 *   ./heap_events -l 0 --no-pci --legacy-mem -m 16 --file-prefix=ch04-ev   (ENOTSUP)
 */
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include <sys/mman.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_memory.h>
#include <rte_malloc.h>

/* Called by EAL with the memory hotplug lock held: do not allocate,
 * free, or call rte_memseg_walk() in here (deadlock). Printing is fine. */
static void on_mem_event(enum rte_mem_event type, const void *addr, size_t len, void *arg)
{
	(void)arg;
	printf("    [mem event] %-5s addr=%p len=%zu KB\n",
	       type == RTE_MEM_EVENT_ALLOC ? "ALLOC" : "FREE", addr, len >> 10);
}

/* Called before the heap grows past the limit. -1 = deny. */
static int on_validate(int socket_id, size_t cur_limit, size_t new_len)
{
	printf("    [validator] socket %d: growing to %zu MB would pass the %zu MB limit -> deny\n",
	       socket_id, new_len >> 20, cur_limit >> 20);
	return -1;
}

static void heap_total(const char *when)
{
	struct rte_malloc_socket_stats st;
	rte_malloc_get_socket_stats(0, &st);
	printf("  heap 0 size %-28s %4zu MB\n", when, st.heap_totalsz_bytes >> 20);
}

int main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}

	/* ---------------- Part A ---------------- */
	printf("A. memory event callbacks\n");
	int r = rte_mem_event_callback_register("ch04", on_mem_event, NULL);
	printf("  rte_mem_event_callback_register = %d%s%s\n", r,
	       r ? ", rte_errno=" : "", r ? rte_strerror(rte_errno) : "");
	if (r != 0)
		printf("  -> this memory mode is not dynamic: pages are never mapped/unmapped at run time\n");

	heap_total("at start:");
	printf("  rte_zmalloc(5 MB):\n");
	void *p = rte_zmalloc("ev", 5 << 20, 0);
	heap_total("after 5 MB:");
	printf("  rte_free(5 MB):\n");
	rte_free(p);
	heap_total("after free:");

	/* ---------------- Part B ---------------- */
	printf("\nB. allocation validator, limit 16 MB on socket 0\n");
	r = rte_mem_alloc_validator_register("cap16", on_validate, 0, 16 << 20);
	printf("  rte_mem_alloc_validator_register = %d%s%s\n", r,
	       r ? ", rte_errno=" : "", r ? rte_strerror(rte_errno) : "");
	printf("  rte_malloc(24 MB):\n");
	p = rte_malloc("ev", 24 << 20, 0);
	printf("  -> %s\n", p ? "allocated" : "NULL (denied or no memory)");
	rte_free(p);
	if (r == 0)
		rte_mem_alloc_validator_unregister("cap16", 0);

	/* ---------------- Part C ---------------- */
	printf("\nC. external heap on 4 MB of mmap()ed memory\n");
	size_t len = 4 << 20;
	void *ext = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (ext == MAP_FAILED) {
		perror("mmap");
		goto out;
	}
	r = rte_malloc_heap_create("ch04_ext");
	printf("  rte_malloc_heap_create = %d\n", r);
	/* No IOVA table (NULL): fine for the CPU, unusable for DMA. */
	printf("  rte_malloc_heap_memory_add(4 MB, page 4K, no IOVAs):\n");
	r = rte_malloc_heap_memory_add("ch04_ext", ext, len, NULL, 0, 4096);
	printf("    = %d\n", r);
	int sock = rte_malloc_heap_get_socket("ch04_ext");
	printf("  heap socket id = %d, external = %d\n", sock, rte_malloc_heap_socket_is_external(sock));
	char *q = rte_malloc_socket("ev", 1000, 0, sock);
	printf("  rte_malloc_socket(1000, socket %d) = %p, inside our mmap: %s\n", sock, (void *)q,
	       (q >= (char *)ext && q < (char *)ext + len) ? "yes" : "no");
	printf("  rte_malloc_virt2iova = 0x%" PRIx64 "%s\n", rte_malloc_virt2iova(q),
	       rte_malloc_virt2iova(q) == RTE_BAD_IOVA ? " (RTE_BAD_IOVA: no IOVA given)" : "");
	rte_free(q);
	printf("  remove memory + destroy heap:\n");
	r = rte_malloc_heap_memory_remove("ch04_ext", ext, len);
	r |= rte_malloc_heap_destroy("ch04_ext");
	printf("    = %d\n", r);
	munmap(ext, len);
out:
	rte_mem_event_callback_unregister("ch04", NULL);
	rte_eal_cleanup();
	return 0;
}
