/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11 side demo: EAL alarms (rte_alarm.h).
 *
 * An alarm is a one-shot callback "in N microseconds". Unlike rte_timer you
 * do not have to call anything from a poll loop: the EAL's interrupt thread
 * (named dpdk-intr) waits on a timerfd and runs the callback itself.
 *
 * The demo shows:
 *   1. where the callback runs (thread name, rte_lcore_id() == LCORE_ID_ANY)
 *   2. the re-arm pattern for periodic work (a callback that sets itself again)
 *   3. rte_eal_alarm_cancel(): return values, (void *)-1 wildcard, and the
 *      EINPROGRESS case when an alarm tries to cancel itself
 *   4. why a callback must never block: one slow alarm delays every other
 *      alarm AND every interrupt/event callback of the process
 *
 *   ./alarm_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch11-alarm
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_alarm.h>
#include <rte_errno.h>

static uint64_t hz, t0;
static volatile int ticks_left;
static volatile bool done_where, done_victim;

static double
ms_now(void)
{
	return (double)(rte_get_timer_cycles() - t0) * 1000.0 / hz;
}

static void
print_where(const char *who)
{
	char name[32] = "?";
	unsigned int lc = rte_lcore_id();

	pthread_getname_np(pthread_self(), name, sizeof(name));
	printf("%-9s runs in thread '%s', rte_lcore_id() = %s\n", who, name,
	       lc == LCORE_ID_ANY ? "LCORE_ID_ANY (not an lcore)" : "an lcore");
}

/* 1. where does an alarm run? */
static void
where_cb(void *arg)
{
	uint64_t due = (uintptr_t)arg;

	print_where("where_cb");
	printf("          asked for +100.0 ms, ran at +%.1f ms (late by %.2f ms)\n",
	       ms_now(), ms_now() - (double)due);
	done_where = true;
}

/* 2. periodic work: the callback re-arms itself */
static void
tick_cb(void *arg)
{
	static double last;
	double now = ms_now();

	(void)arg;
	printf("tick_cb   at +%6.1f ms (%.1f ms since the previous tick)\n",
	       now, last ? now - last : 0.0);
	last = now;
	if (--ticks_left > 0)
		rte_eal_alarm_set(50 * 1000, tick_cb, NULL);   /* re-arm */
}

/* 3c. an alarm that tries to cancel itself */
static void
self_cancel_cb(void *arg)
{
	int n;

	rte_errno = 0;
	n = rte_eal_alarm_cancel(self_cancel_cb, arg);
	printf("self_cancel_cb: cancel(itself) from its own callback -> %d, rte_errno=%s\n",
	       n, rte_errno == EINPROGRESS ? "EINPROGRESS" : rte_strerror(rte_errno));
}

static void
never_cb(void *arg)
{
	printf("never_cb ran (arg %p): it should have been cancelled!\n", arg);
}

/* 4. a blocking callback and its victim */
static void
slow_cb(void *arg)
{
	(void)arg;
	printf("slow_cb   at +%6.1f ms: sleeping 300 ms inside the interrupt thread (DON'T)\n",
	       ms_now());
	usleep(300 * 1000);
	printf("slow_cb   done at +%6.1f ms\n", ms_now());
}

static void
victim_cb(void *arg)
{
	double due = (double)(uintptr_t)arg;

	printf("victim_cb was due at +%6.1f ms, ran at +%6.1f ms: %.0f ms late\n",
	       due, ms_now(), ms_now() - due);
	done_victim = true;
}

int
main(int argc, char **argv)
{
	int n;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	hz = rte_get_timer_hz();
	t0 = rte_get_timer_cycles();
	print_where("main()");

	printf("\n--- 1. where an alarm runs ---\n");
	rte_eal_alarm_set(100 * 1000, where_cb, (void *)(uintptr_t)100);
	while (!done_where)
		rte_delay_us_sleep(1000);

	printf("\n--- 2. periodic work by re-arming (5 ticks, 50 ms) ---\n");
	t0 = rte_get_timer_cycles();
	ticks_left = 5;
	rte_eal_alarm_set(50 * 1000, tick_cb, NULL);
	while (ticks_left > 0)
		rte_delay_us_sleep(1000);

	printf("\n--- 3. cancelling ---\n");
	rte_eal_alarm_set(1000 * 1000, never_cb, (void *)1);
	rte_eal_alarm_set(1000 * 1000, never_cb, (void *)2);
	rte_eal_alarm_set(1000 * 1000, never_cb, (void *)3);
	n = rte_eal_alarm_cancel(never_cb, (void *)2);
	printf("cancel(never_cb, arg 2)            -> %d (one alarm matched cb AND arg)\n", n);
	n = rte_eal_alarm_cancel(never_cb, (void *)-1);
	printf("cancel(never_cb, (void *)-1)       -> %d (wildcard: every arg)\n", n);
	rte_errno = 0;
	n = rte_eal_alarm_cancel(never_cb, (void *)-1);
	printf("cancel again                       -> %d, rte_errno=%s\n", n,
	       rte_errno == ENOENT ? "ENOENT" : rte_strerror(rte_errno));
	rte_eal_alarm_set(10 * 1000, self_cancel_cb, NULL);
	rte_delay_us_sleep(50 * 1000);

	printf("\n--- 4. a blocking callback delays everyone ---\n");
	t0 = rte_get_timer_cycles();
	rte_eal_alarm_set(20 * 1000, slow_cb, NULL);
	rte_eal_alarm_set(70 * 1000, victim_cb, (void *)(uintptr_t)70);
	while (!done_victim)
		rte_delay_us_sleep(1000);

	rte_eal_cleanup();
	return 0;
}
