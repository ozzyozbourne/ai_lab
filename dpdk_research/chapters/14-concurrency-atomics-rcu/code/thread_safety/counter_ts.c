/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14: thread_safety/counter_ts.c - static lock checking.
 * Compile only (no EAL run), with clang:
 *   clang -fsyntax-only -Wthread-safety -DRTE_ANNOTATE_LOCKS \
 *         $(pkg-config --cflags libdpdk) thread_safety/counter_ts.c
 * (make thread_safety does exactly this). gcc ignores the annotations.
 */
#include <stdint.h>
#include <rte_spinlock.h>
#include <rte_lock_annotations.h>

static rte_spinlock_t lk = RTE_SPINLOCK_INITIALIZER;
static uint64_t counter __rte_guarded_by(&lk);	/* only touch with lk held */

void count_wrong(void)
{
	counter++;		/* BUG: no lock -> clang warns here */
}

void count_right(void)
{
	rte_spinlock_lock(&lk);
	counter++;		/* fine: lk is held */
	rte_spinlock_unlock(&lk);
}

/* A helper that expects its caller to hold the lock: say so in the type. */
static void add_locked(uint64_t n) __rte_exclusive_locks_required(&lk);
static void add_locked(uint64_t n) { counter += n; }

void add_wrong(void)
{
	add_locked(2);		/* BUG: caller does not hold lk -> warning */
}

void unlock_missing(int fail)
{
	rte_spinlock_lock(&lk);
	if (fail)
		return;		/* BUG: returns with lk still held -> warning */
	rte_spinlock_unlock(&lk);
}
