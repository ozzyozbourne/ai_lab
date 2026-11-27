/* SPDX-License-Identifier: BSD-3-Clause
 *
 * args.c - Chapter 2: how EAL options and application options share argv.
 *
 *   ./args <EAL options> -- <application options>
 *
 * rte_eal_init() parses everything up to (and including) the "--" separator
 * and returns how many argv entries it consumed. We shift argc/argv by that
 * amount (EAL has already copied the program name into the slot that held
 * "--", so the new argv[0] is the program name again) and hand the rest to
 * plain getopt_long(). Words without a leading dash that appear before "--"
 * are not EAL options: EAL moves them behind its own, so the app gets them.
 *
 * Run: ./args -l 0 --no-pci --no-huge -m 64 --file-prefix=ch02-args \
 *             -- --count 3 --name demo
 */
#include <stdio.h>
#include <stdlib.h>
#include <getopt.h>

#include <rte_eal.h>
#include <rte_common.h>
#include <rte_lcore.h>

/* Application settings with defaults. */
static unsigned int app_count = 1;
static const char *app_name = "world";

static void
usage(const char *prog)
{
	printf("usage: %s [EAL options] -- [--count N] [--name NAME]\n", prog);
}

/* Parse the application part of the command line with ordinary getopt. */
static int
parse_app_args(int argc, char **argv)
{
	static const struct option longopts[] = {
		{ "count", required_argument, NULL, 'c' },
		{ "name",  required_argument, NULL, 'n' },
		{ "help",  no_argument,       NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int opt;

	/* getopt keeps its cursor in the global optind. EAL in 26.11 parses
	 * its options with rte_argparse, but older EALs used getopt and left
	 * optind pointing past their options: always reset it to 1. */
	optind = 1;
	while ((opt = getopt_long(argc, argv, "c:n:h", longopts, NULL)) != -1) {
		switch (opt) {
		case 'c':
			app_count = (unsigned int)strtoul(optarg, NULL, 10);
			break;
		case 'n':
			app_name = optarg;
			break;
		case 'h':
		default:
			usage(argv[0]);
			return -1;
		}
	}
	return 0;
}

static void
dump_argv(const char *who, int argc, char **argv)
{
	printf("%s sees argc=%d:", who, argc);
	for (int i = 0; i < argc; i++)
		printf(" [%d]=%s", i, argv[i]);
	printf("\n");
}

int
main(int argc, char **argv)
{
	dump_argv("main() before rte_eal_init", argc, argv);

	int ret = rte_eal_init(argc, argv);
	if (ret < 0)
		rte_exit(EXIT_FAILURE, "Invalid EAL arguments\n");

	printf("rte_eal_init() consumed %d arguments\n", ret);

	/* The classic two lines found in every DPDK example. EAL copies
	 * argv[0] into the last argument it parsed (the "--"), so after the
	 * shift argv[0] is still the program name. */
	argc -= ret;
	argv += ret;
	dump_argv("app after shift", argc, argv);

	if (parse_app_args(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "Invalid application arguments\n");

	printf("app options: count=%u name=%s (EAL gave us %u lcore(s))\n",
	       app_count, app_name, rte_lcore_count());
	for (unsigned int i = 0; i < app_count; i++)
		printf("  %u: hello, %s\n", i + 1, app_name);

	rte_eal_cleanup();
	return 0;
}
