/* SPDX-License-Identifier: BSD-3-Clause
 *
 * eal_tour.c - Chapter 3: a guided tour of the EAL from the application's view.
 *
 *   ./eal_tour -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch03-tour
 *   ./eal_tour -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch03-serve -- --serve 10
 *
 * Tour mode (default) shows, in order:
 *   1. what rte_eal_init() returned and the basic lcore facts
 *   2. the lcore table: lcore id -> CPU, NUMA socket, role, state
 *   3. rte_eal_remote_launch() + rte_eal_wait_lcore() collecting return values
 *   4. the WAIT/RUNNING state machine and the -EBUSY error
 *   5. rte_eal_mp_remote_launch(CALL_MAIN) and per-lcore TLS (RTE_DEFINE_PER_LCORE)
 *   6. a plain pthread before and after rte_thread_register()
 *   7. a control thread made with rte_thread_create_control()
 *   8. rte_lcore_dump() and rte_eal_cleanup()
 *
 * Serve mode (-- --serve N) keeps every worker busy-polling until SIGINT /
 * SIGTERM or N seconds pass, so run.sh can look at the threads in /proc.
 * It also shows the right way to stop: the signal handler only sets an
 * atomic flag, the lcores see it and return, then main cleans up.
 */
#define _GNU_SOURCE      /* sched_getaffinity, sched_getcpu, CPU_* */
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <rte_common.h>
#include <rte_cycles.h>
#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_launch.h>
#include <rte_lcore.h>
#include <rte_pause.h>
#include <rte_per_lcore.h>
#include <rte_stdatomic.h>
#include <rte_thread.h>

/* ---- shared state ------------------------------------------------------ */

/* Set by the signal handler, read by every lcore. A lock-free atomic int is
 * async-signal-safe to store to; DPDK calls are not. */
static RTE_ATOMIC(int) quit;

/* Used by the -EBUSY demo: the worker spins until main sets it. */
static RTE_ATOMIC(int) go;

/* Per-thread (TLS) counter: every thread has its own copy, no sharing. */
static RTE_DEFINE_PER_LCORE(uint64_t, calls);

static const char *
role_name(enum rte_lcore_role_t r)
{
	switch (r) {
	case RTE_LCORE_ROLE_RTE:     return "RTE";
	case RTE_LCORE_ROLE_OFF:     return "OFF";
	case RTE_LCORE_ROLE_SERVICE: return "SERVICE";
	case RTE_LCORE_ROLE_NON_EAL: return "NON_EAL";
	}
	return "?";
}

static const char *
state_name(enum rte_lcore_state_t s)
{
	return s == WAIT ? "WAIT" : s == RUNNING ? "RUNNING" : "?";
}

/* Print the CPUs the *calling thread* may run on, e.g. "1" or "0,3". */
static void
print_my_cpus(const char *who)
{
	cpu_set_t set;
	char buf[64] = "";
	int n = 0;

	CPU_ZERO(&set);
	sched_getaffinity(0, sizeof(set), &set);   /* 0 = this thread */
	for (int c = 0; c < CPU_SETSIZE && n < (int)sizeof(buf) - 4; c++)
		if (CPU_ISSET(c, &set))
			n += snprintf(buf + n, sizeof(buf) - n, "%s%d", n ? "," : "", c);
	printf("  %-28s lcore_id=%-3d allowed CPUs=%s\n", who,
	       (int)rte_lcore_id(), buf);
}

/* ---- work functions (lcore_function_t: int f(void *)) ------------------ */

/* 3. Returns a value main can collect with rte_eal_wait_lcore(). */
static int
work_square(void *arg)
{
	unsigned int id = rte_lcore_id();
	(void)arg;
	printf("  [lcore %u on CPU %d] running work_square\n", id, sched_getcpu());
	return 100 + (int)(id * id);
}

/* 4. Spins until main says "go", so main can observe RUNNING. */
static int
work_wait_for_go(void *arg)
{
	(void)arg;
	while (!rte_atomic_load_explicit(&go, rte_memory_order_acquire))
		rte_pause();
	return 7;
}

/* 5. Runs on every lcore including main (CALL_MAIN). */
static int
work_count(void *arg)
{
	int n = *(int *)arg;
	for (int i = 0; i < n; i++)
		RTE_PER_LCORE(calls)++;
	printf("  [lcore %u] my TLS counter = %" PRIu64 "\n",
	       rte_lcore_id(), RTE_PER_LCORE(calls));
	return 0;
}

/* Serve mode: a typical polling loop that checks the quit flag. */
static int
work_poll(void *arg)
{
	uint64_t loops = 0;
	(void)arg;
	while (!rte_atomic_load_explicit(&quit, rte_memory_order_relaxed)) {
		loops++;            /* a real app would rte_eth_rx_burst() here */
		rte_pause();
	}
	printf("  [lcore %u] saw quit after %" PRIu64 " loops\n",
	       rte_lcore_id(), loops);
	return 0;
}

/* ---- threads that are not EAL lcores ----------------------------------- */

/* 6. A plain pthread: no lcore id until it registers. */
static void *
plain_thread(void *arg)
{
	(void)arg;
	print_my_cpus("pthread before register:");
	if (rte_thread_register() != 0) {
		printf("  rte_thread_register failed: %s\n", rte_strerror(rte_errno));
		return NULL;
	}
	printf("  pthread after register:      lcore_id=%u role=%s\n",
	       rte_lcore_id(), role_name(rte_eal_lcore_role(rte_lcore_id())));
	rte_thread_unregister();
	printf("  pthread after unregister:    lcore_id=%d\n", (int)rte_lcore_id());
	return NULL;
}

/* 7. A control thread: rte_thread_func returns uint32_t. */
static uint32_t
control_thread(void *arg)
{
	int serve = *(int *)arg;
	print_my_cpus("control thread 'ch03-ctl':");
	/* In serve mode it stays alive so it shows up in /proc. */
	while (serve && !rte_atomic_load_explicit(&quit, rte_memory_order_relaxed))
		usleep(10 * 1000);
	return 42;
}

/* ---- signals ------------------------------------------------------------ */

static void
on_signal(int sig)
{
	/* Only async-signal-safe work here: store a flag. No printf, no rte_*. */
	(void)sig;
	rte_atomic_store_explicit(&quit, 1, rte_memory_order_relaxed);
}

/* ---- main --------------------------------------------------------------- */

int
main(int argc, char **argv)
{
	unsigned int id;
	int serve_secs = 0;
	int ret = rte_eal_init(argc, argv);

	if (ret < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	/* EAL consumed 'ret' arguments; what is left belongs to us. */
	argc -= ret;
	argv += ret;
	if (argc >= 3 && strcmp(argv[1], "--serve") == 0)
		serve_secs = atoi(argv[2]);

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	printf("\n== 1. rte_eal_init returned %d (arguments consumed)\n", ret);
	printf("  main lcore=%u  lcore count=%u  TSC hz=%" PRIu64 "\n",
	       rte_get_main_lcore(), rte_lcore_count(), rte_get_tsc_hz());

	printf("\n== 2. lcore table (RTE_LCORE_FOREACH)\n");
	printf("  lcore  cpu  socket  role     state\n");
	RTE_LCORE_FOREACH(id)
		printf("  %5u  %3d  %6u  %-7s  %s\n", id, rte_lcore_to_cpu_id(id),
		       rte_lcore_to_socket_id(id), role_name(rte_eal_lcore_role(id)),
		       id == rte_get_main_lcore() ? "(main)" :
		       state_name(rte_eal_get_lcore_state(id)));
	print_my_cpus("main thread:");

	if (serve_secs > 0) {
		int one = 1;
		rte_thread_t ctl;
		uint64_t end;

		printf("\n== serve mode: pid %d, polling for up to %d s (SIGINT stops)\n",
		       (int)getpid(), serve_secs);
		fflush(stdout);
		rte_thread_create_control(&ctl, "ch03-ctl", control_thread, &one);
		rte_eal_mp_remote_launch(work_poll, NULL, SKIP_MAIN);
		end = rte_get_tsc_cycles() + (uint64_t)serve_secs * rte_get_tsc_hz();
		while (!rte_atomic_load_explicit(&quit, rte_memory_order_relaxed) &&
		       rte_get_tsc_cycles() < end)
			usleep(10 * 1000);       /* main just supervises */
		rte_atomic_store_explicit(&quit, 1, rte_memory_order_relaxed);
		rte_eal_mp_wait_lcore();          /* every worker back in WAIT */
		rte_thread_join(ctl, NULL);
		printf("  all lcores stopped; cleanup=%d\n", rte_eal_cleanup());
		return 0;
	}

	printf("\n== 3. remote_launch + wait_lcore (return values)\n");
	RTE_LCORE_FOREACH_WORKER(id) {
		ret = rte_eal_remote_launch(work_square, NULL, id);
		if (ret != 0)
			printf("  launch on %u failed: %d\n", id, ret);
	}
	RTE_LCORE_FOREACH_WORKER(id)
		printf("  rte_eal_wait_lcore(%u) = %d\n", id, rte_eal_wait_lcore(id));

	printf("\n== 4. state machine and -EBUSY\n");
	id = rte_get_next_lcore(-1, 1, 0);          /* first worker */
	if (id < RTE_MAX_LCORE) {
		printf("  before launch: lcore %u is %s\n", id,
		       state_name(rte_eal_get_lcore_state(id)));
		rte_eal_remote_launch(work_wait_for_go, NULL, id);
		printf("  after launch:  lcore %u is %s\n", id,
		       state_name(rte_eal_get_lcore_state(id)));
		ret = rte_eal_remote_launch(work_square, NULL, id);
		printf("  second launch while RUNNING returns %d (-EBUSY is %d)\n",
		       ret, -EBUSY);
		rte_atomic_store_explicit(&go, 1, rte_memory_order_release);
		printf("  rte_eal_wait_lcore(%u) = %d\n", id, rte_eal_wait_lcore(id));
		printf("  after wait:    lcore %u is %s\n", id,
		       state_name(rte_eal_get_lcore_state(id)));
	}

	printf("\n== 5. mp_remote_launch(CALL_MAIN) + RTE_PER_LCORE\n");
	{
		int n = 3;
		/* main runs work_count itself, synchronously, after waking workers */
		rte_eal_mp_remote_launch(work_count, &n, CALL_MAIN);
		rte_eal_mp_wait_lcore();
		rte_eal_mp_remote_launch(work_count, &n, CALL_MAIN);
		rte_eal_mp_wait_lcore();
	}

	printf("\n== 6. a non-EAL pthread and rte_thread_register()\n");
	{
		pthread_t t;
		pthread_create(&t, NULL, plain_thread, NULL);
		pthread_join(t, NULL);
	}

	printf("\n== 7. rte_thread_create_control()\n");
	{
		rte_thread_t ctl;
		uint32_t rv = 0;
		int zero = 0;
		ret = rte_thread_create_control(&ctl, "ch03-ctl", control_thread, &zero);
		if (ret == 0) {
			rte_thread_join(ctl, &rv);
			printf("  control thread returned %u\n", rv);
		} else {
			printf("  rte_thread_create_control failed: %d\n", ret);
		}
	}

	printf("\n== 8. rte_lcore_dump() and rte_eal_cleanup()\n");
	rte_lcore_dump(stdout);
	ret = rte_eal_cleanup();
	printf("  rte_eal_cleanup() = %d\n", ret);
	return 0;
}
