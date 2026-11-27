/* SPDX-License-Identifier: BSD-3-Clause
 *
 * sleeper.c - Chapter 4, helper for see_the_files.sh.
 *
 * Initialises EAL with whatever memory options it is given, allocates 8 MB
 * with rte_malloc (so the heap really maps some pages), prints "READY pid=N"
 * and sleeps. While it sleeps, see_the_files.sh looks at /dev/hugepages,
 * /run/dpdk/<prefix> and /proc/<pid>/maps. On SIGINT/SIGTERM it frees the
 * memory and calls rte_eal_cleanup(), which removes its hugepage files.
 *
 * Usage: ./sleeper <EAL options> [-- <seconds>]
 */
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_malloc.h>
#include <rte_memory.h>

static volatile sig_atomic_t stop;
static void on_signal(int sig) { (void)sig; stop = 1; }

int main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0) {
		fprintf(stderr, "rte_eal_init failed: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	argc -= ret;
	argv += ret;
	int seconds = (argc > 1) ? atoi(argv[1]) : 8;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	void *buf = rte_zmalloc("sleeper", 8 << 20, 0);   /* 8 MB */
	printf("READY pid=%d buf=%p mapped=%" PRIu64 "MB\n", getpid(), buf,
	       rte_eal_get_physmem_size() >> 20);
	fflush(stdout);

	for (int i = 0; i < seconds * 10 && !stop; i++)
		usleep(100 * 1000);

	rte_free(buf);
	rte_eal_cleanup();                 /* unmaps pages, removes our files */
	printf("sleeper %d: clean exit\n", getpid());
	return 0;
}
