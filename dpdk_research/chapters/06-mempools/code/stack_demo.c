/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 6, example 5b: stack_demo.c
 *
 * rte_stack: a bounded LIFO of pointers, in three flavours:
 *   flags 0                 standard: array + spinlock
 *   RTE_STACK_F_LF          lock-free linked list; head = {top, counter},
 *                           swung with a 128-bit compare-and-swap (ABA-safe)
 *   RTE_STACK_F_PILE (exp.) lock-free, LIFO per 32-pointer bulk (26.11)
 *
 * Part 1  pop order after pushing 1..64 in one call, and after pushing
 *         1,2,3 one at a time: who is LIFO per object, who is not.
 * Part 2  the pile is "not strictly bounded by its size": a pile created for
 *         64 objects accepts 64 single pushes AND a 64-object bulk.
 * Part 3  throughput: 1 lcore alone, then 2 lcores, pop+push bursts of 1 and
 *         of 32 on the same stack; median of 5 runs, min and max, cycles per object.
 *
 * Run:  ./stack_demo -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch06-stack
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_stack.h>
#include <rte_debug.h>

#define ITERS 100000
#define RUNS  5

struct kind { const char *name; uint32_t flags; };
static const struct kind kinds[] = {
	{ "std",  0 },
	{ "lf",   RTE_STACK_F_LF },
	{ "pile", RTE_STACK_F_PILE },
};

#define V(i) ((void *)(uintptr_t)(i))
#define I(p) ((unsigned int)(uintptr_t)(p))

static struct rte_stack *
make(const char *name, unsigned int count, uint32_t flags)
{
	struct rte_stack *s = rte_stack_create(name, count, rte_socket_id(), flags);
	if (s == NULL)
		rte_exit(EXIT_FAILURE, "rte_stack_create(%s): %s\n", name,
			 rte_strerror(rte_errno));
	return s;
}

static void
part1(void)
{
	unsigned int k, i;
	void *in[64], *out[64];

	for (i = 0; i < 64; i++)
		in[i] = V(i + 1);
	printf("[1] push 1..64 in ONE call, then pop 64; and push 1,2,3 one by one, pop 3\n");
	for (k = 0; k < RTE_DIM(kinds); k++) {
		struct rte_stack *s = make("ch06_s1", 1024, kinds[k].flags);
		unsigned int n = rte_stack_push(s, in, 64);
		unsigned int m = rte_stack_pop(s, out, 64);
		printf("  %-4s pushed %u popped %u: out[0..3]=%u %u %u %u  out[31..33]=%u %u %u",
		       kinds[k].name, n, m, I(out[0]), I(out[1]), I(out[2]), I(out[3]),
		       I(out[31]), I(out[32]), I(out[33]));
		for (i = 1; i <= 3; i++)
			rte_stack_push(s, &in[i - 1], 1);
		rte_stack_pop(s, out, 3);
		printf(" | singles -> %u %u %u\n", I(out[0]), I(out[1]), I(out[2]));
		rte_stack_free(s);
	}
}

static void
part2(void)
{
	unsigned int k, i, ok;
	void *in[64];

	for (i = 0; i < 64; i++)
		in[i] = V(i + 1);
	printf("[2] capacity 64: push 64 singles, then try one 64-object bulk\n");
	for (k = 0; k < RTE_DIM(kinds); k++) {
		struct rte_stack *s = make("ch06_s2", 64, kinds[k].flags);
		for (i = 0, ok = 0; i < 64; i++)
			ok += rte_stack_push(s, &in[i], 1);
		printf("  %-4s singles pushed=%u count=%u free_count=%u | bulk push(64) -> %u, count=%u\n",
		       kinds[k].name, ok, rte_stack_count(s), rte_stack_free_count(s),
		       rte_stack_push(s, in, 64), rte_stack_count(s));
		rte_stack_free(s);
	}
}

/* ---- Part 3 --------------------------------------------------------------- */
static struct rte_stack *bench_s;
static unsigned int bench_burst;
static volatile int go;

static int
bench(void *arg)
{
	uint64_t *cyc = arg, t0;
	void *objs[32];
	unsigned int i, got;

	while (!go)
		rte_pause();
	t0 = rte_rdtsc_precise();
	for (i = 0; i < ITERS; i++) {
		got = rte_stack_pop(bench_s, objs, bench_burst);
		if (got)
			rte_stack_push(bench_s, objs, got);
	}
	*cyc = rte_rdtsc_precise() - t0;
	return 0;
}

static int
cmp_dbl(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static void
part3(void)
{
	unsigned int bursts[] = { 1, 32 };
	unsigned int worker = rte_get_next_lcore(-1, 1, 0);
	unsigned int b, k, r, i, nt;
	void *fill[1024];

	if (worker >= RTE_MAX_LCORE) {
		printf("[3] skipped: needs -l 0-1\n");
		return;
	}
	for (i = 0; i < 1024; i++)
		fill[i] = V(i + 1);
	printf("[3] each lcore pops then pushes a burst, %d iterations, %d runs\n",
	       ITERS, RUNS);
	for (nt = 1; nt <= 2; nt++)
	for (b = 0; b < RTE_DIM(bursts); b++) {
		for (k = 0; k < RTE_DIM(kinds); k++) {
			double res[RUNS];
			for (r = 0; r < RUNS; r++) {
				uint64_t cm = 0, cw = 0;
				bench_s = make("ch06_s3", 1024, kinds[k].flags);
				rte_stack_push(bench_s, fill, 1024);
				bench_burst = bursts[b];
				go = 0;
				if (nt == 2)
					rte_eal_remote_launch(bench, &cw, worker);
				go = 1;
				bench(&cm);
				if (nt == 2)
					rte_eal_wait_lcore(worker);
				res[r] = (double)(cm + cw) / nt / ((double)ITERS * bursts[b]);
				if (rte_stack_count(bench_s) != 1024)
					printf("  !! %s lost objects: %u\n", kinds[k].name,
					       rte_stack_count(bench_s));
				rte_stack_free(bench_s);
			}
			qsort(res, RUNS, sizeof(res[0]), cmp_dbl);
			printf("  %u lcore%s burst %-2u %-4s median %7.2f cycles/obj (min %.2f, max %.2f)\n",
			       nt, nt == 2 ? "s" : " ", bursts[b], kinds[k].name, res[RUNS / 2], res[0], res[RUNS - 1]);
		}
	}
}

int
main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
#ifndef RTE_STACK_LF_SUPPORTED
	printf("lock-free stack not supported on this platform\n");
#endif
	part1();
	part2();
	part3();
	rte_eal_cleanup();
	return 0;
}
