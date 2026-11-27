#include <stdio.h>
#include <stdlib.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_malloc.h>
#include <rte_rcu_qsbr.h>
#include <rte_stdatomic.h>
struct cfg { uint64_t version; uint64_t payload[7]; };
static RTE_ATOMIC(struct cfg *) cur;
static struct rte_rcu_qsbr *qs;
static RTE_ATOMIC(int) stop;
static uint64_t reads[RTE_MAX_LCORE];
static int reader(void *a) {
	unsigned id = rte_lcore_id(); (void)a;
	rte_rcu_qsbr_thread_register(qs, id);
	rte_rcu_qsbr_thread_online(qs, id);
	while (!rte_atomic_load_explicit(&stop, rte_memory_order_relaxed)) {
		struct cfg *c = rte_atomic_load_explicit(&cur, rte_memory_order_acquire);
		if (c->payload[0] != c->version) { printf("USE-AFTER-FREE detected!\n"); abort(); }
		reads[id]++;
		rte_rcu_qsbr_quiescent(qs, id);   /* end of "while(1)" iteration */
	}
	rte_rcu_qsbr_thread_offline(qs, id);
	rte_rcu_qsbr_thread_unregister(qs, id);
	return 0;
}
int main(int argc, char **argv) {
	if (rte_eal_init(argc, argv) < 0) return 1;
	size_t sz = rte_rcu_qsbr_get_memsize(RTE_MAX_LCORE);
	qs = rte_zmalloc(NULL, sz, RTE_CACHE_LINE_SIZE);
	rte_rcu_qsbr_init(qs, RTE_MAX_LCORE);
	struct cfg *c = calloc(1, sizeof(*c)); c->version = c->payload[0] = 1;
	rte_atomic_store_explicit(&cur, c, rte_memory_order_release);
	rte_eal_mp_remote_launch(reader, NULL, SKIP_MAIN);
	uint64_t tot = 0, t0;
	for (uint64_t v = 2; v < 20002; v++) {
		struct cfg *n = calloc(1, sizeof(*n)); n->version = n->payload[0] = v;
		struct cfg *old = rte_atomic_exchange_explicit(&cur, n, rte_memory_order_acq_rel);
		t0 = rte_rdtsc();
		rte_rcu_qsbr_synchronize(qs, RTE_QSBR_THRID_INVALID); /* grace period */
		tot += rte_rdtsc() - t0;
		old->payload[0] = 0xdead; free(old);          /* safe now */
	}
	rte_atomic_store_explicit(&stop, 1, rte_memory_order_relaxed);
	rte_eal_mp_wait_lcore();
	printf("avg grace period: %.0f cycles (%.2f us)\n", tot / 20000.0, tot / 20000.0 / (rte_get_tsc_hz() / 1e6));
	unsigned l; RTE_LCORE_FOREACH_WORKER(l) printf("reader %u: %lu reads\n", l, reads[l]);
	rte_eal_cleanup(); return 0;
}
