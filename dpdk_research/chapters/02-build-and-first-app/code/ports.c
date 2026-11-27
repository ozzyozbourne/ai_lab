/* SPDX-License-Identifier: BSD-3-Clause
 *
 * ports.c - Chapter 2: the --whole-archive pitfall.
 *
 * The program only counts Ethernet ports. It is linked twice by the Makefile:
 *   ports_ok      $(pkg-config --libs --static libdpdk)
 *                 -> drivers are wrapped in -Wl,--whole-archive, every PMD
 *                    constructor is kept, --vdev=net_null0 creates a port.
 *   ports_broken  the same archives, but WITHOUT --whole-archive
 *                 -> nothing in this file references a driver symbol, so the
 *                    linker drops every driver object file, the RTE_INIT
 *                    constructors never run, no driver registers, 0 ports.
 */
#include <stdio.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_common.h>
#include <rte_ethdev.h>

int
main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "Cannot init EAL\n");

	uint16_t n = rte_eth_dev_count_avail();
	printf("ports=%u\n", (unsigned int)n);

	uint16_t port;
	RTE_ETH_FOREACH_DEV(port) {
		struct rte_eth_dev_info info;
		if (rte_eth_dev_info_get(port, &info) == 0)
			printf("  port %u: driver %s\n", (unsigned int)port, info.driver_name);
	}

	rte_eal_cleanup();
	return n == 0 ? 1 : 0;   /* non-zero exit when no port was found */
}
