/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14: litmus_mp.c - the message-passing writer and reader, compiled
 * (never run) so that we can read the machine code with objdump.
 *
 *   make objdump      x86-64 with gcc -O2, using the real DPDK headers
 *   make objdump-arm  AArch64 with clang --target=aarch64-linux-gnu -O2
 *                     (no DPDK headers: the macros below expand to exactly
 *                     what rte_stdatomic.h expands to in this build, i.e.
 *                     GCC __atomic builtins, because enable_stdatomic=false)
 *
 * What to look for:
 *   writer_plain    : the compiler is free to store 'ready' BEFORE 'msg'.
 *   writer_barrier  : rte_compiler_barrier() pins the order (x86: no instruction).
 *   writer_relaxed  : the C11 model allows reordering; GCC happens not to.
 *   writer_release  : order guaranteed. x86: a plain mov. Arm: stlr.
 *   reader_plain    : the load of 'ready' is hoisted out of the loop.
 *   reader_acquire  : reloads every time. x86: plain mov. Arm: ldar.
 */


#if defined(__x86_64__) && !defined(NO_DPDK)
#include <rte_atomic.h>
#include <rte_stdatomic.h>
#else
/* Same expansions as lib/eal/include/rte_stdatomic.h (!RTE_ENABLE_STDATOMIC). */
#define RTE_ATOMIC(type) type
#define rte_memory_order_relaxed __ATOMIC_RELAXED
#define rte_memory_order_acquire __ATOMIC_ACQUIRE
#define rte_memory_order_release __ATOMIC_RELEASE
#define rte_atomic_load_explicit(p, mo)     __atomic_load_n(p, mo)
#define rte_atomic_store_explicit(p, v, mo) __atomic_store_n(p, v, mo)
#define rte_compiler_barrier() do { asm volatile ("" : : : "memory"); } while (0)
#endif

int msg;			/* the payload: plain, non-atomic */
int plain_ready;		/* a plain flag: WRONG */
RTE_ATOMIC(int) ready;		/* an atomic flag */

/* 1. Plain stores: nothing stops the compiler from swapping them. */
void
writer_plain(int v)
{
	msg = v / 3;		/* takes a few instructions to compute ... */
	plain_ready = 1;	/* ... so the compiler stores the constant first */
}

/* 2. A compiler barrier: no instruction, but the compiler may not move
 *    memory accesses across it. Enough on x86 for MP, not on Arm. */
void
writer_barrier(int v)
{
	msg = v / 3;
	rte_compiler_barrier();
	plain_ready = 1;
}

/* 3. Relaxed atomic store: atomic, but no ordering promise at all. */
void
writer_relaxed(int v)
{
	msg = v / 3;
	rte_atomic_store_explicit(&ready, 1, rte_memory_order_relaxed);
}

/* 4. Release store: every earlier access is visible before 'ready' is. */
void
writer_release(int v)
{
	msg = v / 3;
	rte_atomic_store_explicit(&ready, 1, rte_memory_order_release);
}

/* 5. A plain spin loop: the compiler may load plain_ready once. */
int
reader_plain(void)
{
	while (plain_ready == 0)
		;
	return msg;
}

/* 6. Acquire load in the loop: reloaded every time, and the msg load
 *    cannot move above it. */
int
reader_acquire(void)
{
	while (rte_atomic_load_explicit(&ready, rte_memory_order_acquire) == 0)
		;
	return msg;
}
