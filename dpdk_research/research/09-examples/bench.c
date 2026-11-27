#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_spinlock.h>
#include <rte_ticketlock.h>
#include <rte_mcslock.h>
#include <rte_rwlock.h>
#include <rte_stdatomic.h>
#include <rte_common.h>

#define ITERS 2000000ULL
struct packed { uint64_t c; };
struct padded { alignas(RTE_CACHE_LINE_SIZE) uint64_t c; RTE_CACHE_GUARD; };
static struct packed P[RTE_MAX_LCORE];
static struct padded Q[RTE_MAX_LCORE];
static rte_spinlock_t sl = RTE_SPINLOCK_INITIALIZER;
static rte_ticketlock_t tl = RTE_TICKETLOCK_INITIALIZER;
static RTE_ATOMIC(rte_mcslock_t *) mcs;
static RTE_ATOMIC(uint64_t) shared_ctr;
static uint64_t plain_ctr;
static RTE_ATOMIC(int) go;
static int mode;

static int worker(void *arg) {
	unsigned id = rte_lcore_id(); (void)arg;
	while (!rte_atomic_load_explicit(&go, rte_memory_order_acquire)) rte_pause();
	uint64_t t0 = rte_rdtsc();
	for (uint64_t i = 0; i < ITERS; i++) {
		switch (mode) {
		case 0: __atomic_fetch_add(&P[id].c, 1, __ATOMIC_RELAXED); break;
		case 1: __atomic_fetch_add(&Q[id].c, 1, __ATOMIC_RELAXED); break;
		case 2: rte_atomic_fetch_add_explicit(&shared_ctr, 1, rte_memory_order_relaxed); break;
		case 3: rte_spinlock_lock(&sl); plain_ctr++; rte_spinlock_unlock(&sl); break;
		case 4: rte_ticketlock_lock(&tl); plain_ctr++; rte_ticketlock_unlock(&tl); break;
		case 5: { rte_mcslock_t me; rte_mcslock_lock(&mcs, &me); plain_ctr++; rte_mcslock_unlock(&mcs, &me); } break;
		}
	}
	uint64_t dt = rte_rdtsc() - t0;
	printf("  lcore %u: %.2f cycles/op\n", id, (double)dt / ITERS);
	return 0;
}
int main(int argc, char **argv) {
	if (rte_eal_init(argc, argv) < 0) return 1;
	const char *names[] = {"false-sharing (packed)", "padded per-lcore", "shared atomic add", "spinlock", "ticketlock", "mcslock"};
	printf("TSC hz=%lu\n", rte_get_tsc_hz());
	for (mode = 0; mode < 6; mode++) {
		printf("%s:\n", names[mode]);
		rte_atomic_store_explicit(&go, 0, rte_memory_order_relaxed);
		rte_eal_mp_remote_launch(worker, NULL, SKIP_MAIN);
		rte_atomic_store_explicit(&go, 1, rte_memory_order_release);
		rte_eal_mp_wait_lcore();
	}
	/* rdtsc overhead */
	uint64_t a = rte_rdtsc(); for (int i=0;i<1000000;i++) (void)rte_rdtsc(); uint64_t b = rte_rdtsc();
	uint64_t c = rte_rdtsc(); for (int i=0;i<1000000;i++) (void)rte_rdtsc_precise(); uint64_t d = rte_rdtsc();
	printf("rte_rdtsc: %.1f cyc, rte_rdtsc_precise: %.1f cyc\n", (b-a)/1e6, (d-c)/1e6);
	rte_eal_cleanup(); return 0;
}
