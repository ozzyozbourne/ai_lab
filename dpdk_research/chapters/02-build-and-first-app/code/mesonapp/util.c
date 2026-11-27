/* SPDX-License-Identifier: BSD-3-Clause
 *
 * mesonapp/util.c - uses one EXPERIMENTAL EAL API, rte_cpu_socket_id().
 * Experimental functions are marked __rte_experimental in the headers
 * (lib/eal/include/rte_compat.h). Unless ALLOW_EXPERIMENTAL_API is defined,
 * that macro adds __attribute__((deprecated)) and every call warns.
 * meson.build defines it with c_args: '-DALLOW_EXPERIMENTAL_API'.
 */
#include <stdio.h>

#include <rte_lcore.h>

#include "util.h"

void
print_lcore_numa(void)
{
	unsigned int lcore;

	RTE_LCORE_FOREACH(lcore) {
		/* rte_lcore_to_cpu_id(): stable API; rte_cpu_socket_id(): experimental */
		int cpu = rte_lcore_to_cpu_id(lcore);
		printf("  lcore %u -> cpu %d -> numa node %u\n", lcore, cpu,
		       rte_cpu_socket_id((unsigned int)cpu));
	}
}
