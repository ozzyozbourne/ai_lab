/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 7, exercise 3 (medium) solution: dyn_order.c
 *
 * Dynfield offsets are decided at run time, first come first served.
 * Two runs of this program register the same field "ch07_b" but in a
 * different order relative to other fields, and get different offsets.
 * So never hard-code an offset, and never assume two programs agree:
 * look the field up by name in each process.
 *
 * Usage (application arguments after "--"):
 *   ./dyn_order <EAL args> -- b          registers ch07_b only
 *   ./dyn_order <EAL args> -- a b        registers ch07_a (4 B), then ch07_b
 *   ./dyn_order <EAL args> -- ts b       Rx timestamp first, then ch07_b
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <rte_eal.h>
#include <rte_debug.h>
#include <rte_errno.h>
#include <rte_mbuf_dyn.h>

int main(int argc, char **argv)
{
	int n = rte_eal_init(argc, argv);
	if (n < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= n;
	argv += n;

	printf("order:");
	for (int i = 1; i < argc; i++)
		printf(" %s", argv[i]);
	printf("\n");
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "ts") == 0) {
			int off; uint64_t fl;
			if (rte_mbuf_dyn_rx_timestamp_register(&off, &fl) == 0)
				printf("  rte_dynfield_timestamp (8 B) -> offset %d\n", off);
			continue;
		}
		struct rte_mbuf_dynfield d = { .size = 4, .align = 4 };
		if (strcmp(argv[i], "b") == 0)
			d.size = d.align = 8;
		snprintf(d.name, sizeof(d.name), "ch07_%s", argv[i]);
		int off = rte_mbuf_dynfield_register(&d);
		printf("  %-22s (%zu B) -> offset %d\n", d.name, d.size, off);
	}
	rte_eal_cleanup();
	return 0;
}
