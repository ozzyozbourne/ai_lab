/* SPDX-License-Identifier: BSD-3-Clause
 *
 * newline_bad.c - Chapter 3, exercise 3: this file is SUPPOSED to fail to
 * compile. RTE_LOG_LINE() adds the newline itself and rejects a format string
 * that already ends in "\n" with a static assertion. run.sh builds it with
 * "make newline_bad" and shows the compiler error.
 */
#include <rte_eal.h>
#include <rte_log.h>

#define RTE_LOG_DEFAULT_LOGTYPE user
RTE_LOG_REGISTER_SUFFIX(app_logtype, ch03app, INFO);
#define RTE_LOGTYPE_APP app_logtype

int
main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		return 1;
	RTE_LOG_LINE(INFO, APP, "oops, a trailing newline\n");   /* <- error */
	return rte_eal_cleanup();
}
