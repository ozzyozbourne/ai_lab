/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11, exercise 4 solution: --burst with a range check INSIDE the
 * argument parser.
 *
 * step5_options autosaves --burst as a U16 and checks the range afterwards.
 * Here --burst has no val_saver, so rte_argparse calls our callback with the
 * raw string. The callback reuses the library's typed parser
 * (rte_argparse_parse_type) and then checks 1..64. Returning a negative value
 * makes rte_argparse_parse() fail like for any other bad argument.
 *
 *   ./ex4_burst_range -l 0 --no-pci --no-huge -m 64 --file-prefix=ch11-ex4 -- --burst 16
 */
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <stdint.h>
#include <rte_eal.h>
#include <rte_argparse.h>

#define BURST_MIN 1
#define BURST_MAX 64
#define ARG_BURST 1          /* index passed to the callback via val_set */

static uint16_t burst = 32;

static int
arg_cb(uint32_t index, const char *value, void *opaque)
{
	uint16_t v;

	(void)opaque;
	if (index != ARG_BURST)
		return -EINVAL;
	if (rte_argparse_parse_type(value, RTE_ARGPARSE_VALUE_TYPE_U16, &v) != 0) {
		printf("--burst: '%s' is not a uint16\n", value);
		return -EINVAL;
	}
	if (v < BURST_MIN || v > BURST_MAX) {
		printf("--burst: %u is out of range %u..%u\n", v, BURST_MIN, BURST_MAX);
		return -ERANGE;
	}
	burst = v;
	return 0;
}

static struct rte_argparse args = {
	.prog_name = "ex4_burst_range",
	.usage = "[EAL options] -- --burst N",
	.exit_on_error = false,
	.callback = arg_cb,
	.args = {
		/* val_saver NULL -> callback; val_set carries the index */
		{ "--burst", "-b", "RX burst size, 1..64", NULL, (void *)ARG_BURST,
		  RTE_ARGPARSE_VALUE_REQUIRED, RTE_ARGPARSE_VALUE_TYPE_NONE, 0 },
		ARGPARSE_ARG_END(),
	},
};

int
main(int argc, char **argv)
{
	int ret = rte_eal_init(argc, argv);

	if (ret < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	argc -= ret;
	argv += ret;
	ret = rte_argparse_parse(&args, argc, argv);
	if (ret < 0)
		printf("rte_argparse_parse -> %d, keeping burst=%u\n", ret, burst);
	else
		printf("burst = %u\n", burst);
	rte_eal_cleanup();
	return ret < 0 ? EXIT_FAILURE : 0;
}
