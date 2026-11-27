#include <stdio.h>
#include <stdint.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_cycles.h>
#include <rte_malloc.h>
#include <rte_prefetch.h>
#include <rte_random.h>
#define ITERS 50000000UL
struct packed { volatile uint64_t c; };              /* 8 bytes: neighbours share a line */
struct padded { volatile uint64_t c; } __rte_cache_aligned; /* one line each */
static struct packed P[RTE_MAX_LCORE];
static struct padded Q[RTE_MAX_LCORE];
static volatile int mode;
static int worker(void *a) {
  (void)a; unsigned id = rte_lcore_id();
  if (mode == 0) for (uint64_t i = 0; i < ITERS; i++) P[id].c++;
  else           for (uint64_t i = 0; i < ITERS; i++) Q[id].c++;
  return 0;
}
static uint64_t run(int m) {
  mode = m; uint64_t t = rte_rdtsc();
  rte_eal_mp_remote_launch(worker, NULL, CALL_MAIN); rte_eal_mp_wait_lcore();
  return rte_rdtsc() - t;
}
/* prefetch demo: random index gather over a big array */
#define N (8u<<20)
static uint64_t gather(uint64_t *arr, uint32_t *idx, int pf) {
  uint64_t s = 0, t = rte_rdtsc();
  for (uint32_t i = 0; i < N; i++) {
    if (pf && i + 16 < N) rte_prefetch0(&arr[idx[i + 16]]);
    s += arr[idx[i]];
  }
  t = rte_rdtsc() - t; if (s == 42) printf("!");
  return t;
}
int main(int argc, char **argv) {
  if (rte_eal_init(argc, argv) < 0) return 1;
  printf("sizeof(packed)=%zu sizeof(padded)=%zu RTE_CACHE_LINE_SIZE=%d\n", sizeof(struct packed), sizeof(struct padded), RTE_CACHE_LINE_SIZE);
  uint64_t a = run(0), b = run(1), hz = rte_get_tsc_hz();
  printf("false sharing (packed): %.1f ms\npadded (__rte_cache_aligned): %.1f ms  -> %.1fx\n", a*1e3/hz, b*1e3/hz, (double)a/b);
  uint64_t *arr = rte_malloc("arr", N * 8ull, 64); uint32_t *idx = rte_malloc("idx", N * 4ull, 64);
  if (!arr || !idx) { printf("alloc failed\n"); return 1; }
  for (uint32_t i = 0; i < N; i++) { arr[i] = i; idx[i] = rte_rand_max(N); }
  uint64_t n0 = gather(arr, idx, 0), n1 = gather(arr, idx, 1);
  printf("random gather 64MB: no prefetch %.2f cyc/elem, prefetch0(+16) %.2f cyc/elem\n", (double)n0/N, (double)n1/N);
  rte_eal_cleanup(); return 0;
}
