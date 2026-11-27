/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 11 appendix: a run-and-read tour of the EAL toolbox.
 *
 * Small helpers every DPDK program ends up using. Each section prints what a
 * call returns so you can compare the output with the code:
 *   A. rte_common.h macros (RTE_MIN/MAX, RTE_DIM, RTE_ALIGN_*, RTE_DIV_ROUND_UP,
 *      RTE_BUILD_BUG_ON, RTE_PTR_ADD/SUB/DIFF, container_of, packed structs)
 *   B. random numbers: rte_srand, rte_rand, rte_rand_max, rte_drand
 *   C. bit sets: rte_bitset (flat, small) and rte_bitmap (two-level, huge)
 *   D. rte_reciprocal: division by a run-time constant without DIV
 *   E. errors and strings: rte_errno, rte_strerror, rte_strscpy, rte_strsplit
 *   F. rte_hexdump / rte_memdump
 *   G. sys/queue.h TAILQ lists (what the EAL uses for its object lists)
 *   H. rte_uuid
 *
 *   ./toolbox -l 0 --no-pci --no-huge -m 64 --file-prefix=ch11-tool
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <inttypes.h>
#include <sys/queue.h>

#include <rte_eal.h>
#include <rte_common.h>
#include <rte_bitops.h>
#include <rte_cycles.h>
#include <rte_random.h>
#include <rte_bitset.h>
#include <rte_bitmap.h>
#include <rte_malloc.h>
#include <rte_reciprocal.h>
#include <rte_errno.h>
#include <rte_string_fns.h>
#include <rte_hexdump.h>
#include <rte_uuid.h>
#include <rte_memzone.h>
#include <rte_tailq.h>    /* RTE_TAILQ_FOREACH_SAFE */

/* A wire header must have no padding: the 26.11 way to pack a struct. */
struct __rte_packed_begin wire_hdr {
	uint8_t  type;
	uint32_t seq;          /* would be at offset 4 without packing */
	uint16_t len;
} __rte_packed_end;

struct natural_hdr {      /* the same fields, natural alignment */
	uint8_t  type;
	uint32_t seq;
	uint16_t len;
};

struct flow {
	uint32_t id;
	TAILQ_ENTRY(flow) next;     /* the list links live inside the object */
	char name[16];
};
TAILQ_HEAD(flow_list, flow);

static int
cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;

	return (x > y) - (x < y);
}

static void
section(const char *t)
{
	printf("\n=== %s ===\n", t);
}

int
main(int argc, char **argv)
{
	if (rte_eal_init(argc, argv) < 0)
		rte_exit(EXIT_FAILURE, "EAL init failed\n");

	/* ------------------------------------------------------------ A */
	section("A. rte_common.h");
	{
		int ports[] = {3, 9, 4, 1};
		char buf[64];
		char *p = buf, *q;
		struct flow f = { .id = 7 };
		uint32_t *idp = &f.id;

		printf("RTE_MIN(3, 9)=%d  RTE_MAX(3, 9)=%d  RTE_DIM(ports)=%zu\n",
		       RTE_MIN(3, 9), RTE_MAX(3, 9), RTE_DIM(ports));
		printf("RTE_ALIGN_CEIL(100, 64)=%d  RTE_ALIGN_FLOOR(100, 64)=%d  "
		       "RTE_DIV_ROUND_UP(100, 64)=%d\n",
		       RTE_ALIGN_CEIL(100, 64), RTE_ALIGN_FLOOR(100, 64),
		       RTE_DIV_ROUND_UP(100, 64));
		printf("rte_is_power_of_2(48)=%d  rte_align32pow2(48)=%u  "
		       "RTE_CACHE_LINE_SIZE=%d\n",
		       rte_is_power_of_2(48), rte_align32pow2(48), RTE_CACHE_LINE_SIZE);
		/* compile-time assertion: the build fails if the condition is true */
		RTE_BUILD_BUG_ON(sizeof(struct wire_hdr) != 7);
		printf("sizeof(packed wire_hdr)=%zu, sizeof(natural_hdr)=%zu "
		       "(seq at offset %zu vs %zu)\n",
		       sizeof(struct wire_hdr), sizeof(struct natural_hdr),
		       offsetof(struct wire_hdr, seq), offsetof(struct natural_hdr, seq));
		/* 26.11: RTE_PTR_ADD/SUB take a POINTER as first argument. Passing an
		 * integer (an address stored in a uintptr_t) no longer compiles:
		 * use plain + and - on integers. */
		q = RTE_PTR_ADD(p, 10);
		printf("RTE_PTR_ADD(buf, 10) - buf = %zu  RTE_PTR_DIFF = %" PRIuPTR
		       "  RTE_PTR_SUB back == buf: %s\n",
		       (size_t)(q - p), RTE_PTR_DIFF(q, p),
		       RTE_PTR_SUB(q, 10) == p ? "yes" : "no");
		printf("container_of(&f.id, struct flow, id) == &f: %s\n",
		       container_of(idp, struct flow, id) == &f ? "yes" : "no");
	}

	/* ------------------------------------------------------------ B */
	section("B. random numbers");
	{
		int i, hist[6] = {0};

		rte_srand(42);   /* fixed seed: same sequence every run */
		printf("rte_rand() x3 after rte_srand(42): %016" PRIx64 " %016" PRIx64
		       " %016" PRIx64 "\n", rte_rand(), rte_rand(), rte_rand());
		for (i = 0; i < 60000; i++)
			hist[rte_rand_max(6)]++;      /* uniform in [0, 6), no modulo bias */
		printf("rte_rand_max(6) histogram of 60000 draws: %d %d %d %d %d %d\n",
		       hist[0], hist[1], hist[2], hist[3], hist[4], hist[5]);
		printf("rte_drand() = %.6f (a double in [0, 1))\n", rte_drand());
	}

	/* ------------------------------------------------------------ C */
	section("C. bit sets");
	{
		RTE_BITSET_DECLARE(ports_up, 128);   /* 128 bits = 2 x uint64_t */
		ssize_t b;
		uint32_t bm_bits = 1 << 20, sz, pos = 0;
		uint64_t slab;
		uint8_t *mem;
		struct rte_bitmap *bmp;

		rte_bitset_init(ports_up, 128);
		rte_bitset_set(ports_up, 3);
		rte_bitset_set(ports_up, 64);
		rte_bitset_set(ports_up, 100);
		printf("rte_bitset: count=%zu first=%zd test(64)=%d test(65)=%d; set bits:",
		       rte_bitset_count_set(ports_up, 128),
		       rte_bitset_find_first_set(ports_up, 128),
		       rte_bitset_test(ports_up, 64), rte_bitset_test(ports_up, 65));
		RTE_BITSET_FOREACH_SET(b, ports_up, 128)
			printf(" %zd", b);
		printf("\n");

		/* rte_bitmap: a 2-level bitmap for millions of bits (e.g. one bit per
		 * flow or per queue in the QoS scheduler); scanning skips empty
		 * 512-bit groups using the upper level. Needs cache-aligned memory. */
		sz = rte_bitmap_get_memory_footprint(bm_bits);
		mem = rte_zmalloc("bmp", sz, RTE_CACHE_LINE_SIZE);
		bmp = rte_bitmap_init(bm_bits, mem, sz);
		rte_bitmap_set(bmp, 5);
		rte_bitmap_set(bmp, 700000);
		printf("rte_bitmap: %u bits in %u bytes; get(700000)=%d get(6)=%d\n",
		       bm_bits, sz, rte_bitmap_get(bmp, 700000) != 0, rte_bitmap_get(bmp, 6) != 0);
		/* rte_bitmap_scan returns one non-empty 64-bit slab at a time */
		if (rte_bitmap_scan(bmp, &pos, &slab))
			printf("rte_bitmap_scan: first slab at bit %u, slab=0x%" PRIx64 "\n", pos, slab);
		if (rte_bitmap_scan(bmp, &pos, &slab))
			printf("rte_bitmap_scan: next  slab at bit %u, slab=0x%" PRIx64
			       " (bit %u)\n", pos, slab, pos + rte_ctz64(slab));
		rte_bitmap_free(bmp);
		rte_free(mem);
	}

	/* ------------------------------------------------------------ D */
	section("D. rte_reciprocal");
	{
		/* Dividing by a value known only at run time (e.g. the number of
		 * worker queues) costs a slow DIV instruction. rte_reciprocal turns
		 * it into a multiply and a shift, computed once. */
		struct rte_reciprocal r7 = rte_reciprocal_value(7);
		uint32_t a, errors = 0;
		uint64_t t;
		double c_div[5], c_rec[5];
		int run;
		volatile uint32_t sink = 0, d = 7;

		for (a = 0; a < 10000000; a += 3)
			if (rte_reciprocal_divide(a, r7) != a / 7)
				errors++;
		printf("rte_reciprocal_divide(a, 7) == a / 7 for 3.3M values: %u errors\n",
		       errors);
		/* 5 runs of 10M operations each; report median [min..max] */
		for (run = 0; run < 5; run++) {
			t = rte_rdtsc();
			for (a = 0; a < 10000000; a++)
				sink += a / d;        /* volatile d: forces a real DIV */
			c_div[run] = (rte_rdtsc() - t) / 1e7;
			t = rte_rdtsc();
			for (a = 0; a < 10000000; a++)
				sink += rte_reciprocal_divide(a, r7);
			c_rec[run] = (rte_rdtsc() - t) / 1e7;
		}
		qsort(c_div, 5, sizeof(double), cmp_double);
		qsort(c_rec, 5, sizeof(double), cmp_double);
		printf("cycles per division, median of 5 runs [min..max] (VM, gcc -O2):\n"
		       "  a / d (DIV):            %.2f [%.2f..%.2f]\n"
		       "  rte_reciprocal_divide:  %.2f [%.2f..%.2f]\n",
		       c_div[2], c_div[0], c_div[4], c_rec[2], c_rec[0], c_rec[4]);
	}

	/* ------------------------------------------------------------ E */
	section("E. errors and strings");
	{
		char small[8], line[] = "10.11.0.1,10.11.0.2,,eth1";
		char *tok[8];
		const struct rte_memzone *mz;
		ssize_t n;
		int i, nt;

		/* DPDK functions that return NULL or -1 set the per-lcore rte_errno */
		mz = rte_memzone_lookup("no-such-zone");
		printf("rte_memzone_lookup(missing) -> %p, rte_errno=%d (%s)\n",
		       (const void *)mz, rte_errno, rte_strerror(rte_errno));
		printf("rte_strerror(E_RTE_NO_CONFIG)=\"%s\" (DPDK-specific codes too)\n",
		       rte_strerror(E_RTE_NO_CONFIG));
		/* rte_strscpy: like strlcpy but returns -E2BIG on truncation */
		n = rte_strscpy(small, "abc", sizeof(small));
		printf("rte_strscpy(\"abc\") -> %zd\n", n);
		n = rte_strscpy(small, "net_ring0,nodeaction=x", sizeof(small));
		printf("rte_strscpy(too long) -> %zd (-E2BIG=%d), dst=\"%s\" (always terminated)\n",
		       n, -E2BIG, small);
		/* rte_strsplit modifies the string in place, keeps empty fields */
		nt = rte_strsplit(line, sizeof(line), tok, RTE_DIM(tok), ',');
		printf("rte_strsplit -> %d tokens:", nt);
		for (i = 0; i < nt; i++)
			printf(" [%s]", tok[i]);
		printf("\n");
	}

	/* ------------------------------------------------------------ F */
	section("F. rte_hexdump / rte_memdump");
	{
		struct wire_hdr h = { .type = 0x11, .seq = 0xdeadbeef, .len = 64 };

		rte_hexdump(stdout, "wire_hdr (packed, 7 bytes)", &h, sizeof(h));
		rte_memdump(stdout, "same bytes, rte_memdump", &h, sizeof(h));
	}

	/* ------------------------------------------------------------ G */
	section("G. TAILQ lists");
	{
		struct flow_list head = TAILQ_HEAD_INITIALIZER(head);
		struct flow fl[3] = {{1, {0}, "dns"}, {2, {0}, "http"}, {3, {0}, "ssh"}};
		struct flow *f, *tmp;
		int i;

		for (i = 0; i < 3; i++)
			TAILQ_INSERT_TAIL(&head, &fl[i], next);
		/* remove while iterating: the _SAFE variant keeps a lookahead */
		RTE_TAILQ_FOREACH_SAFE(f, &head, next, tmp)
			if (f->id == 2)
				TAILQ_REMOVE(&head, f, next);
		printf("flows after removing id 2:");
		TAILQ_FOREACH(f, &head, next)
			printf(" %u:%s", f->id, f->name);
		printf("\n");
	}

	/* ------------------------------------------------------------ H */
	section("H. rte_uuid");
	{
		rte_uuid_t a, b;
		char s[RTE_UUID_STRLEN];

		rte_uuid_parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8", a);
		rte_uuid_unparse(a, s, sizeof(s));
		memset(b, 0, sizeof(rte_uuid_t));   /* the null UUID */
		printf("parsed+unparsed: %s  is_null(a)=%d is_null(cleared)=%d compare=%d\n",
		       s, rte_uuid_is_null(a), rte_uuid_is_null(b), rte_uuid_compare(a, b) != 0);
	}

	rte_eal_cleanup();
	return 0;
}
