/* SPDX-License-Identifier: BSD-3-Clause
 *
 * soring_demo.c - Chapter 5, example 5: the staged-ordered ring (SORING).
 *
 * A SORING is one ring with a producer, N processing stages and a
 * consumer. Objects stay in their slot while they move from stage to
 * stage; a stage "acquires" a batch, works on it, and "releases" it.
 * Batches of one stage may be released in ANY order (think: two worker
 * threads, one slower than the other), yet the next stage and the consumer
 * always see the objects in the original enqueue order.
 *
 * This program is single-threaded so that the order of events is exact:
 *   enqueue 1..8 -> stage 0 acquires batch A (1..4) and batch B (5..8)
 *   -> releases B first -> stage 1 can acquire nothing yet
 *   -> releases A -> stage 1 acquires all 8 in order -> consumer gets 1..8.
 *
 * The SORING API is experimental in 26.11: build with -DALLOW_EXPERIMENTAL_API.
 * Run:  ./soring_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch05-soring
 */
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_malloc.h>
#include <rte_soring.h>
#include <rte_debug.h>

static void
print_objs(const char *what, const uint32_t *v, uint32_t n)
{
	printf("  %-44s n=%u:", what, n);
	for (uint32_t i = 0; i < n; i++)
		printf(" %u", v[i]);
	printf("\n");
}

int
main(int argc, char **argv)
{
	uint32_t in[8], a[8], b[8], c[8], out[8];
	uint32_t tok_a, tok_b, tok_c, n, avail, i;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");

	/* There is no rte_soring_create(): ask for the size, allocate the
	 * memory yourself, then init it in place. */
	struct rte_soring_param prm = {
		.name = "so",
		.elems = 16,                    /* slots (rounded up internally) */
		.elem_size = sizeof(uint32_t),  /* objects are copied by value */
		.meta_size = 0,                 /* no per-object metadata */
		.stages = 2,
		.prod_synt = RTE_RING_SYNC_ST,
		.cons_synt = RTE_RING_SYNC_ST,
	};
	ssize_t sz = rte_soring_get_memsize(&prm);
	struct rte_soring *so = rte_zmalloc("soring", sz, RTE_CACHE_LINE_SIZE);
	if (sz < 0 || so == NULL || rte_soring_init(so, &prm) != 0)
		rte_exit(EXIT_FAILURE, "soring init failed\n");
	printf("soring: 16 elems x 4 bytes, 2 stages, memsize=%zd bytes\n", sz);

	for (i = 0; i < 8; i++)
		in[i] = i + 1;
	n = rte_soring_enqueue_bulk(so, in, 8, NULL);
	print_objs("producer enqueue_bulk", in, n);

	/* Stage 0, two batches (as if two threads each took 4). */
	n = rte_soring_acquire_bulk(so, a, 0, 4, &tok_a, &avail);
	print_objs("stage 0 acquire batch A", a, n);
	n = rte_soring_acquire_bulk(so, b, 0, 4, &tok_b, &avail);
	print_objs("stage 0 acquire batch B", b, n);

	/* B finishes first. Releasing it does NOT make it visible yet. */
	rte_soring_release(so, NULL, 0, 4, tok_b);
	printf("  stage 0 release batch B (out of order)\n");
	n = rte_soring_acquire_burst(so, c, 1, 8, &tok_c, &avail);
	printf("  %-44s n=%u  (B waits behind A)\n", "stage 1 acquire_burst(8)", n);

	/* Now A finishes: A and B both become available to stage 1. */
	for (i = 0; i < 4; i++)
		a[i] *= 10;                     /* stage 0 "processes" A */
	rte_soring_release(so, a, 0, 4, tok_a);  /* objs != NULL: write back */
	printf("  stage 0 release batch A (values x10 written back)\n");
	n = rte_soring_acquire_burst(so, c, 1, 8, &tok_c, &avail);
	print_objs("stage 1 acquire_burst(8)", c, n);
	rte_soring_release(so, NULL, 1, n, tok_c);

	printf("  count=%u free=%u before dequeue\n", rte_soring_count(so),
	       rte_soring_free_count(so));
	n = rte_soring_dequeue_burst(so, out, 8, &avail);
	print_objs("consumer dequeue_burst", out, n);
	printf("  count=%u after dequeue\n", rte_soring_count(so));

	rte_free(so);
	rte_eal_cleanup();
	return 0;
}
