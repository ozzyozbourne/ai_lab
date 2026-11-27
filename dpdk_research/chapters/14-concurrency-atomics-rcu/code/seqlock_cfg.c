/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Chapter 14: seqlock_cfg.c - a 64-byte config read by the data plane,
 * written by the control plane about 1000 times per second.
 *
 * The config is too big for one atomic instruction. The invariant is that
 * all seven fields equal 'version'. A reader that copies the struct while
 * the writer is half-way through sees a "torn" copy (mixed versions).
 *
 * Three phases, each PHASE_MS long, writer on the main lcore and readers on
 * every worker lcore:
 *   1. naive    : readers just copy the struct (no protection)
 *   2. seqlock  : rte_seqlock_write_lock/unlock and read_begin/read_retry
 *                 (works with any number of writers: the spinlock inside
 *                 serialises them)
 *   3. seqcount : rte_seqcount_write_begin/end + read_begin/read_retry
 *                 (no lock: correct only because there is ONE writer)
 *
 * Readers never block the writer; they retry instead. We count reads,
 * retries and torn copies that were accepted (must be 0 in phases 2 and 3).
 *
 * Run: ./seqlock_cfg -l 0-2 --no-pci --no-huge -m 64 --file-prefix=ch14-seq
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_launch.h>
#include <rte_cycles.h>
#include <rte_pause.h>
#include <rte_common.h>
#include <rte_debug.h>
#include <rte_stdatomic.h>
#include <rte_seqlock.h>
#include <rte_seqcount.h>

#define PHASE_MS 500
#define WRITE_HZ 1000
#define NFIELDS 7

/* The protected data: exactly one cache line. */
struct __rte_cache_aligned cfg {
	uint64_t version;
	uint64_t field[NFIELDS];
};

/* The lock lives on its own line: readers hammer it with loads, the writer
 * stores to it twice per update. */
static struct __rte_cache_aligned { rte_seqlock_t sl; } lock = { RTE_SEQLOCK_INITIALIZER };
static struct __rte_cache_aligned { rte_seqcount_t sc; } count = { RTE_SEQCOUNT_INITIALIZER };
static struct cfg config;

enum phase { NAIVE, SEQLOCK, SEQCOUNT };
static const char *phase_name[] = { "naive (no lock)", "rte_seqlock", "rte_seqcount" };
static enum phase phase;
static RTE_ATOMIC(int) stop;

struct __rte_cache_aligned rstats {
	uint64_t reads;		/* copies accepted */
	uint64_t retries;	/* copies thrown away because a write overlapped */
	uint64_t torn;		/* accepted copies that were inconsistent */
};
static struct rstats stats[RTE_MAX_LCORE];

/* Slow the writer down between fields, so that a write takes about a
 * microsecond: that is what makes overlaps (and torn copies) likely. */
static inline void
slow(void)
{
	for (int i = 0; i < 4; i++)
		rte_pause();
}

static void
write_fields(uint64_t v)
{
	config.version = v;
	for (int i = 0; i < NFIELDS; i++) {
		config.field[i] = v;
		slow();
	}
}

static inline int
consistent(const struct cfg *c)
{
	for (int i = 0; i < NFIELDS; i++)
		if (c->field[i] != c->version)
			return 0;
	return 1;
}

static int
reader(void *arg)
{
	struct rstats *st = &stats[rte_lcore_id()];
	struct cfg copy = {0};
	uint32_t sn;
	(void)arg;

	memset(st, 0, sizeof(*st));
	while (!rte_atomic_load_explicit(&stop, rte_memory_order_relaxed)) {
		switch (phase) {
		case NAIVE:
			rte_compiler_barrier();	/* force a fresh copy every time */
			memcpy(&copy, &config, sizeof(copy));
			break;
		case SEQLOCK:
			do {
				sn = rte_seqlock_read_begin(&lock.sl);
				memcpy(&copy, &config, sizeof(copy));
				if (!rte_seqlock_read_retry(&lock.sl, sn))
					break;
				st->retries++;
			} while (1);
			break;
		case SEQCOUNT:
			do {
				sn = rte_seqcount_read_begin(&count.sc);
				memcpy(&copy, &config, sizeof(copy));
				if (!rte_seqcount_read_retry(&count.sc, sn))
					break;
				st->retries++;
			} while (1);
			break;
		}
		st->reads++;
		if (!consistent(&copy))
			st->torn++;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	uint64_t hz, v = 0;
	unsigned int l;

	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");
	if (rte_lcore_count() < 2)
		rte_exit(EXIT_FAILURE, "need at least one worker lcore, e.g. -l 0-2\n");
	hz = rte_get_tsc_hz();

	printf("seqlock_cfg: writer on lcore %u at ~%d Hz, %u reader lcore(s), %d ms per phase\n\n",
	       rte_lcore_id(), WRITE_HZ, rte_lcore_count() - 1, PHASE_MS);
	printf("%-16s %8s %12s %10s %10s %14s\n", "phase", "writes",
	       "reads", "retries", "torn", "write cycles");

	for (phase = NAIVE; phase <= SEQCOUNT; phase++) {
		uint64_t writes = 0, wcyc = 0;

		write_fields(++v);
		rte_atomic_store_explicit(&stop, 0, rte_memory_order_relaxed);
		rte_eal_mp_remote_launch(reader, NULL, SKIP_MAIN);

		uint64_t start = rte_get_tsc_cycles(), next = start;
		while (rte_get_tsc_cycles() - start < hz * PHASE_MS / 1000) {
			while (rte_get_tsc_cycles() < next)	/* pace: ~1 kHz */
				rte_pause();
			next += hz / WRITE_HZ;
			uint64_t t0 = rte_rdtsc();
			switch (phase) {
			case NAIVE:
				write_fields(++v);
				break;
			case SEQLOCK:
				rte_seqlock_write_lock(&lock.sl);	/* sn becomes odd */
				write_fields(++v);
				rte_seqlock_write_unlock(&lock.sl);	/* sn even again */
				break;
			case SEQCOUNT:
				rte_seqcount_write_begin(&count.sc);
				write_fields(++v);
				rte_seqcount_write_end(&count.sc);
				break;
			}
			wcyc += rte_rdtsc() - t0;
			writes++;
		}
		rte_atomic_store_explicit(&stop, 1, rte_memory_order_relaxed);
		rte_eal_mp_wait_lcore();

		struct rstats sum = {0};
		RTE_LCORE_FOREACH_WORKER(l) {
			sum.reads += stats[l].reads;
			sum.retries += stats[l].retries;
			sum.torn += stats[l].torn;
		}
		printf("%-16s %8" PRIu64 " %12" PRIu64 " %10" PRIu64 " %10" PRIu64 " %14.0f\n",
		       phase_name[phase], writes, sum.reads, sum.retries, sum.torn,
		       (double)wcyc / writes);
	}
	printf("\nfinal version %" PRIu64 ", seqlock sn=%u (even = no writer inside)\n",
	       v, rte_atomic_load_explicit(&lock.sl.count.sn, rte_memory_order_relaxed));
	rte_eal_cleanup();
	return 0;
}
