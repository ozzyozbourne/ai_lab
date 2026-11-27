/* SPDX-License-Identifier: BSD-3-Clause
 *
 * solutions/verbose.c - Exercise 1: add an application option --verbose
 * (parsed after the "--" separator) that prints every EAL lcore.
 *
 * Run: ./verbose -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch02-verbose -- --verbose
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <getopt.h>

#include <rte_eal.h>
#include <rte_common.h>
#include <rte_lcore.h>

int
main(int argc, char **argv)
{
	static const struct option longopts[] = {
		{ "verbose", no_argument, NULL, 'v' },
		{ NULL, 0, NULL, 0 }
	};
	bool verbose = false;
	int opt;

	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "Invalid EAL arguments\n");
	argc -= ret;
	argv += ret;

	optind = 1;   /* restart getopt for the application's argv */
	while ((opt = getopt_long(argc, argv, "v", longopts, NULL)) != -1) {
		if (opt == 'v')
			verbose = true;
		else
			rte_exit(EXIT_FAILURE, "usage: %s [EAL] -- [--verbose]\n", argv[0]);
	}

	printf("%u lcore(s) enabled\n", rte_lcore_count());
	if (verbose) {
		unsigned int lcore;
		/* RTE_LCORE_FOREACH visits every enabled lcore, main included */
		RTE_LCORE_FOREACH(lcore)
			printf("  lcore %u: cpu %d%s\n", lcore, rte_lcore_to_cpu_id(lcore),
			       lcore == rte_get_main_lcore() ? " (main)" : "");
	}

	rte_eal_cleanup();
	return 0;
}
