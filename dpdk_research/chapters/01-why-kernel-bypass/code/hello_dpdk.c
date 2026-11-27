/* SPDX-License-Identifier: BSD-3-Clause
 * hello_dpdk.c - the smallest useful DPDK program (chapter 01).
 *
 * What it does:
 *   1. rte_eal_init()        : start the Environment Abstraction Layer (EAL).
 *                              It parses the EAL options (-l, --vdev, -m ...),
 *                              reserves memory, starts lcore threads and probes
 *                              devices. It returns how many argv entries it used.
 *   2. rte_version()         : which DPDK we linked against.
 *   3. rte_lcore_count()     : how many lcores (EAL worker threads) exist.
 *   4. rte_eth_dev_count_avail(): how many Ethernet ports were probed.
 *      With --vdev=net_null0 --vdev=net_ring0 we get two software ports.
 *   5. rte_rdtsc()/rte_get_tsc_hz(): the CPU time-stamp counter, the clock
 *      every DPDK benchmark in this course uses.
 *   6. rte_eal_cleanup()     : release everything the EAL took.
 *
 * Run: ./hello_dpdk -l 0 --no-pci --no-huge -m 64 --file-prefix=ch01-hello \
 *        --vdev=net_null0 --vdev=net_ring0
 */
#include <stdio.h>
#include <stdlib.h>

#include <rte_eal.h>      /* rte_eal_init, rte_eal_cleanup */
#include <rte_debug.h>    /* rte_exit */
#include <rte_version.h>  /* rte_version */
#include <rte_lcore.h>    /* rte_lcore_count, rte_get_main_lcore */
#include <rte_ethdev.h>   /* rte_eth_dev_count_avail, RTE_ETH_FOREACH_DEV */
#include <rte_cycles.h>   /* rte_rdtsc, rte_get_tsc_hz */

int
main(int argc, char **argv)
{
	/* Everything before "--" on the command line belongs to the EAL. */
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "rte_eal_init failed\n");
	argc -= ret;   /* skip what the EAL consumed; the rest is ours */
	argv += ret;

	printf("Hello from %s\n", rte_version());
	printf("lcores: %u (main lcore %u)\n", rte_lcore_count(),
	       rte_get_main_lcore());

	/* Each --vdev became one ethdev port, numbered from 0. */
	uint16_t nb_ports = rte_eth_dev_count_avail();
	printf("Ethernet ports available: %u\n", nb_ports);

	uint16_t port;
	RTE_ETH_FOREACH_DEV(port) {
		char name[RTE_ETH_NAME_MAX_LEN];
		struct rte_eth_dev_info info;

		rte_eth_dev_get_name_by_port(port, name, sizeof(name));
		if (rte_eth_dev_info_get(port, &info) == 0)
			printf("  port %u: %-10s driver=%s\n", port, name,
			       info.driver_name);
	}

	/* The TSC ticks at a fixed rate; that rate is our "cycles" unit. */
	uint64_t hz = rte_get_tsc_hz();
	uint64_t best = UINT64_MAX;
	for (int i = 0; i < 1000; i++) {       /* cheapest of 1000 tries */
		uint64_t t0 = rte_rdtsc();
		uint64_t t1 = rte_rdtsc();
		if (t1 - t0 < best)
			best = t1 - t0;
	}
	printf("TSC: %.2f GHz, so 1 ns = %.1f cycles\n", hz / 1e9, hz / 1e9);
	printf("Two back-to-back rte_rdtsc() calls: %lu cycles apart (best of 1000)\n",
	       (unsigned long)best);

	/* Give memory, hugepage files and threads back. */
	rte_eal_cleanup();
	return 0;
}
