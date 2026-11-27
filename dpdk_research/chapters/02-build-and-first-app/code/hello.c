/* SPDX-License-Identifier: BSD-3-Clause
 *
 * hello.c - Chapter 2: the smallest useful DPDK program, written from scratch.
 *
 * What it shows:
 *   1. rte_eal_init() is the first DPDK call; it eats the EAL options.
 *   2. Work is launched on every lcore (details of launching: ch3).
 *   3. rte_version() and rte_eth_dev_count_avail() prove that the library
 *      and the drivers (PMDs) really are inside this binary.
 *   4. rte_eal_cleanup() releases what rte_eal_init() took.
 *
 * Build:  make hello
 * Run:    ./hello -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch02-hello
 */
#include <stdio.h>
#include <stdlib.h>

#include <rte_eal.h>      /* rte_eal_init(), rte_eal_cleanup() */
#include <rte_lcore.h>    /* rte_lcore_id(), RTE_LCORE_FOREACH_WORKER */
#include <rte_launch.h>   /* rte_eal_remote_launch(), rte_eal_mp_wait_lcore() */
#include <rte_version.h>  /* rte_version(), RTE_VERSION, RTE_VERSION_NUM() */
#include <rte_ethdev.h>   /* rte_eth_dev_count_avail() */
#include <rte_common.h>   /* rte_exit() (lives in rte_common.h in 26.11) */

/* The function every lcore runs. It must have the lcore_function_t shape:
 * int fn(void *arg). */
static int
lcore_hello(void *arg)
{
	(void)arg;
	printf("hello from lcore %u\n", rte_lcore_id());
	return 0;
}

int
main(int argc, char **argv)
{
	unsigned int lcore_id;

	/* Step 1: initialise the EAL. It parses (and consumes) the EAL options,
	 * creates one thread per extra lcore, sets up memory and probes devices. */
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "Cannot init EAL\n");

	/* Compile-time version (from the headers) vs run-time version (from the
	 * library that is actually linked in). */
#if RTE_VERSION >= RTE_VERSION_NUM(26, 11, 0, 0)
	printf("compiled against DPDK >= 26.11, running %s\n", rte_version());
#else
	printf("compiled against an older DPDK, running %s\n", rte_version());
#endif

	/* Step 2: run lcore_hello() on every worker lcore ... (launch: ch3) */
	RTE_LCORE_FOREACH_WORKER(lcore_id)
		rte_eal_remote_launch(lcore_hello, NULL, lcore_id);

	/* ... and on the main lcore too, then wait for the workers. */
	lcore_hello(NULL);
	rte_eal_mp_wait_lcore();

	/* Step 3: how many Ethernet ports did the EAL probe? Each --vdev=net_*
	 * adds one, but only if its driver was linked into this binary. */
	printf("lcores=%u ports=%u\n", rte_lcore_count(),
	       (unsigned int)rte_eth_dev_count_avail());

	/* Step 4: give back hugepages/memory, threads, and runtime files. */
	rte_eal_cleanup();
	return 0;
}
