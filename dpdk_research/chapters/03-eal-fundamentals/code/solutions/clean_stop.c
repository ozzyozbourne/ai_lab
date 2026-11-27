/* SPDX-License-Identifier: BSD-3-Clause
 *
 * clean_stop.c - Chapter 3, exercise 4 (stretch): a SIGINT handler that stops
 * a polling loop on every worker, then shuts the EAL down cleanly.
 *
 *   ./clean_stop -l 0-2 --no-pci -m 64 --file-prefix=ch03-stop   (hugepages)
 *   then press Ctrl-C (run.sh sends SIGINT after 2 s)
 *
 * Rules shown here:
 *   - the handler only stores to a lock-free atomic flag (async-signal-safe);
 *   - every lcore loop reads the flag and returns;
 *   - main waits for all lcores, then calls rte_eal_cleanup() exactly once.
 */
#include <signal.h>
#include <stdio.h>
#include <inttypes.h>
#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_launch.h>
#include <rte_lcore.h>
#include <rte_malloc.h>
#include <rte_pause.h>
#include <rte_stdatomic.h>

static RTE_ATOMIC(bool) force_quit;

static void
on_signal(int sig)
{
	(void)sig;
	rte_atomic_store_explicit(&force_quit, true, rte_memory_order_relaxed);
}

static int
poll_loop(void *arg)
{
	uint64_t n = 0;
	(void)arg;
	while (!rte_atomic_load_explicit(&force_quit, rte_memory_order_relaxed)) {
		n++;
		rte_pause();
	}
	printf("lcore %u: stopping after %" PRIu64 " iterations\n", rte_lcore_id(), n);
	return 0;
}

int
main(int argc, char **argv)
{
	void *buf;

	if (rte_eal_init(argc, argv) < 0) {
		fprintf(stderr, "rte_eal_init: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	/* Touch some hugepage memory so a hugepage file really exists. */
	buf = rte_malloc("ch03-buf", 4 << 20, 0);
	printf("main: allocated 4 MB at %p; polling until SIGINT\n", buf);

	/* Workers poll; the main lcore polls too (CALL_MAIN). */
	rte_eal_mp_remote_launch(poll_loop, NULL, CALL_MAIN);
	rte_eal_mp_wait_lcore();

	rte_free(buf);
	printf("main: all lcores returned; rte_eal_cleanup() = %d\n", rte_eal_cleanup());
	return 0;
}
