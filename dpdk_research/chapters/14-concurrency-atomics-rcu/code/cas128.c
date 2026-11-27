/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14: cas128.c - the ABA fix in four CAS calls (one lcore).
 *
 * Chapter 6's widget shows the ABA problem: thread T1 reads head = A, gets
 * preempted, others pop A, pop B, push A back; T1's compare-and-swap still
 * sees "A" and succeeds with a stale next pointer.
 *
 * Here we replay that history on a single lcore with the two kinds of CAS:
 *   - a 64-bit CAS on the pointer only           -> the stale CAS succeeds
 *   - a 128-bit CAS on {pointer, counter}       -> the stale CAS fails
 * using rte_atomic128_cmp_exchange (x86: lock cmpxchg16b), exactly as
 * lib/stack/rte_stack_lf_c11.h does for the lock-free stack head.
 *
 * Run: ./cas128 -l 0 --no-pci --no-huge -m 64 --file-prefix=ch14-cas
 */
#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_debug.h>
#include <rte_atomic.h>
#include <rte_stdatomic.h>

struct elem { struct elem *next; const char *name; };

/* the stack head as lib/stack defines it: pointer + modification counter,
 * 16-byte aligned so that cmpxchg16b can swap both at once */
struct __rte_aligned(16) head { struct elem *top; uint64_t cnt; };

int
main(int argc, char **argv)
{
	struct elem C = { NULL, "C" }, B = { &C, "B" }, A = { &B, "A" };

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	/* ---- 1. pointer-only CAS ---- */
	RTE_ATOMIC(struct elem *) top = &A;		/* stack: A -> B -> C */
	struct elem *seen = rte_atomic_load_explicit(&top, rte_memory_order_acquire);
	struct elem *seen_next = seen->next;		/* T1 reads A and A->next = B */
	/* ... T1 is preempted; T2 pops A and B, T3 pushes A back ... */
	rte_atomic_store_explicit(&top, &C, rte_memory_order_release);	/* pop A, pop B */
	A.next = &C;
	rte_atomic_store_explicit(&top, &A, rte_memory_order_release);	/* push A */
	/* T1 resumes: CAS(top, A -> B) */
	int ok = rte_atomic_compare_exchange_strong_explicit(&top, &seen, seen_next,
			rte_memory_order_acq_rel, rte_memory_order_acquire);
	printf("64-bit CAS {top}      : %s, top is now %s (B was popped by T2: %s)\n",
	       ok ? "SUCCEEDED" : "failed", top->name,
	       ok ? "stack corrupted" : "stack intact");

	/* ---- 2. {pointer, counter} CAS ---- */
	A.next = &B;
	struct head h = { &A, 0 };
	struct head old = h;			/* T1 reads {A, 0} */
	struct head nh  = { old.top->next, old.cnt + 1 };	/* wants {B, 1} */
	/* the same history; every push/pop bumps the counter */
	struct head t;
	t = h; h.top = &B; h.cnt++; (void)t;	/* pop A  -> {B, 1} */
	h.top = &C; h.cnt++;			/* pop B  -> {C, 2} */
	A.next = &C; h.top = &A; h.cnt++;	/* push A -> {A, 3} */
	ok = rte_atomic128_cmp_exchange((rte_int128_t *)&h, (rte_int128_t *)&old,
			(const rte_int128_t *)&nh, 0,
			rte_memory_order_acq_rel, rte_memory_order_acquire);
	printf("128-bit CAS {top,cnt} : %s, head is {%s, %" PRIu64 "}; T1 now sees {%s, %" PRIu64
	       "} and retries\n", ok ? "SUCCEEDED" : "failed", h.top->name, h.cnt,
	       old.top->name, old.cnt);
	printf("sizeof(struct head) = %zu, alignof = %zu\n", sizeof(struct head),
	       _Alignof(struct head));

	rte_eal_cleanup();
	return 0;
}
