/* SPDX-License-Identifier: BSD-3-Clause
 *
 * reverse_wait.c - Chapter 3, exercise 1 (easy): launch a DIFFERENT function
 * on each worker lcore, then wait for them from the main lcore in REVERSE
 * order and print each return value.
 *
 *   ./reverse_wait -l 0-3 --no-pci --no-huge -m 64 --file-prefix=ch03-ex1
 */
#include <stdio.h>
#include <rte_eal.h>
#include <rte_errno.h>
#include <rte_launch.h>
#include <rte_lcore.h>
#include <rte_cycles.h>

static int f_add(void *a)  { (void)a; return 1 + 1; }
static int f_mul(void *a)  { (void)a; rte_delay_ms(30); return 6 * 7; }
static int f_slow(void *a) { (void)a; rte_delay_ms(60); return -5; }

static lcore_function_t *const funcs[] = { f_add, f_mul, f_slow };
static const char *const names[] = { "f_add", "f_mul", "f_slow" };
#define NFUNCS (sizeof(funcs) / sizeof(funcs[0]))

int
main(int argc, char **argv)
{
	unsigned int ids[RTE_MAX_LCORE], n = 0, id;

	if (rte_eal_init(argc, argv) < 0) {
		fprintf(stderr, "rte_eal_init: %s\n", rte_strerror(rte_errno));
		return 1;
	}
	/* Launch: worker k gets funcs[k % NFUNCS]. Remember the order. */
	RTE_LCORE_FOREACH_WORKER(id) {
		unsigned int k = n % NFUNCS;
		printf("launch %-6s on lcore %u\n", names[k], id);
		rte_eal_remote_launch(funcs[k], NULL, id);
		ids[n++] = id;
	}
	/* Wait in reverse. wait_lcore blocks until that worker is back in WAIT,
	 * so the order of the results is the order we ask, not finish order. */
	while (n > 0) {
		id = ids[--n];
		printf("wait lcore %u -> %d\n", id, rte_eal_wait_lcore(id));
	}
	return rte_eal_cleanup() == 0 ? 0 : 1;
}
