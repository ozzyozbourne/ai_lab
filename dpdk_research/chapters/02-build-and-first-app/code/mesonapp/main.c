/* SPDX-License-Identifier: BSD-3-Clause
 *
 * mesonapp/main.c - Chapter 2: a two-file DPDK application built with meson.
 * Run: ./build/app -l 0-1 --no-pci --no-huge -m 64 --file-prefix=ch02-meson --vdev=net_null0
 */
#include <stdio.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_common.h>
#include <rte_version.h>
#include <rte_ethdev.h>

#include "util.h"

int
main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "Cannot init EAL\n");

	printf("mesonapp: %s, ports=%u\n", rte_version(),
	       (unsigned int)rte_eth_dev_count_avail());
	print_lcore_numa();        /* defined in util.c */

	rte_eal_cleanup();
	return 0;
}
