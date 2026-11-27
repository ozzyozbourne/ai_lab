#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <sys/mman.h>
#include <unistd.h>
#include <rte_eal.h>
#include <rte_memory.h>
#include <rte_memzone.h>
#include <rte_malloc.h>
#include <rte_lcore.h>
#include <rte_errno.h>

static int msl_cb(const struct rte_memseg_list *msl, void *arg) {
  (void)arg;
  printf("  MSL base_va=%p page_sz=%" PRIu64 "K socket=%d len=%zuMB external=%u heap=%u nsegs=%u used=%u\n",
     msl->base_va, msl->page_sz>>10, msl->socket_id, msl->len>>20, msl->external, msl->heap,
     msl->memseg_arr.len, msl->memseg_arr.count);
  return 0;
}
static int ms_cb(const struct rte_memseg_list *msl, const struct rte_memseg *ms, void *arg) {
  int *n = arg; (void)msl;
  if ((*n)++ < 4)
   printf("  seg va=%p iova=0x%" PRIx64 " len=%zuK socket=%d flags=%x\n", ms->addr, ms->iova, ms->len>>10, ms->socket_id, ms->flags);
  return 0;
}
static int contig_cb(const struct rte_memseg_list *msl, const struct rte_memseg *ms, size_t len, void *arg) {
  (void)msl;(void)arg;
  printf("  contig chunk va=%p iova=0x%" PRIx64 " len=%zuK\n", ms->addr, ms->iova, len>>10);
  return 0;
}
static void ev(enum rte_mem_event t, const void *addr, size_t len, void *arg) {
  (void)arg;
  printf("  [mem event] %s addr=%p len=%zuK\n", t==RTE_MEM_EVENT_ALLOC?"ALLOC":"FREE", addr, len>>10);
}
int main(int argc, char **argv) {
  if (rte_eal_init(argc, argv) < 0) { printf("init failed %s\n", rte_strerror(rte_errno)); return 1; }
  printf("iova_mode=%s has_hugepages=%d using_phys=%d physmem=%" PRIu64 "MB sockets=%u\n",
    rte_eal_iova_mode()==RTE_IOVA_PA?"PA":rte_eal_iova_mode()==RTE_IOVA_VA?"VA":"DC",
    rte_eal_has_hugepages(), rte_eal_using_phys_addrs(), rte_eal_get_physmem_size()>>20, rte_socket_count());
  int r = rte_mem_event_callback_register("demo", ev, NULL);
  printf("event cb register: %d (%s)\n", r, r? rte_strerror(rte_errno):"ok");
  printf("memseg lists:\n"); rte_memseg_list_walk(msl_cb, NULL);
  int n=0; rte_memseg_walk(ms_cb, &n); printf("  total segs mapped=%d\n", n);
  const struct rte_memzone *mz = rte_memzone_reserve_aligned("demo_mz", 3<<20, SOCKET_ID_ANY, RTE_MEMZONE_IOVA_CONTIG, 4096);
  if (mz) printf("memzone %s va=%p iova=0x%" PRIx64 " len=%zu hpsz=%" PRIu64 "K socket=%d\n", mz->name, mz->addr, mz->iova, mz->len, mz->hugepage_sz>>10, mz->socket_id);
  else printf("memzone failed: %s\n", rte_strerror(rte_errno));
  void *p = rte_malloc("demo", 100, 0), *q = rte_malloc("demo", 100, 4096), *z = rte_zmalloc_socket("demo", 5<<20, 64, 0);
  printf("rte_malloc(100,0)=%p (mod64=%lu) rte_malloc(100,4096)=%p (mod4096=%lu) zmalloc 5MB=%p\n", p, (uintptr_t)p%64, q, (uintptr_t)q%4096, z);
  printf("virt2iova(p)=0x%" PRIx64 " virt2phy(p)=0x%" PRIx64 " malloc_virt2iova=0x%" PRIx64 "\n", rte_mem_virt2iova(p), rte_mem_virt2phy(p), rte_malloc_virt2iova(p));
  size_t sz; rte_malloc_validate(p, &sz); printf("validate size=%zu\n", sz);
  printf("contig walk:\n"); rte_memseg_contig_walk(contig_cb, NULL);
  struct rte_malloc_socket_stats st; rte_malloc_get_socket_stats(0, &st);
  printf("heap0: total=%zu free=%zu alloc=%zu greatest_free=%zu nalloc=%u nfree=%u\n", st.heap_totalsz_bytes, st.heap_freesz_bytes, st.heap_allocsz_bytes, st.greatest_free_size, st.alloc_count, st.free_count);
  /* external heap */
  size_t elen = 4<<20; void *ext = mmap(NULL, elen, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  r = rte_malloc_heap_create("ext_heap");
  r |= rte_malloc_heap_memory_add("ext_heap", ext, elen, NULL, 0, 4096);
  int esock = rte_malloc_heap_get_socket("ext_heap");
  void *e = rte_malloc_socket("ext", 1000, 0, esock);
  printf("ext heap rc=%d socket_id=%d is_external=%d ptr=%p in [%p,%p) iova=0x%" PRIx64 "\n", r, esock, rte_malloc_heap_socket_is_external(esock), e, ext, (char*)ext+elen, rte_malloc_virt2iova(e));
  rte_free(e);
  rte_free(z); rte_free(p); rte_free(q); rte_memzone_free(mz);
  rte_malloc_heap_memory_remove("ext_heap", ext, elen); rte_malloc_heap_destroy("ext_heap");
  if (getenv("PAUSE")) sleep(3);
  if (getenv("DUMP")) { rte_dump_physmem_layout(stdout); rte_memzone_dump(stdout); rte_malloc_dump_heaps(stdout); }
  rte_eal_cleanup();
  return 0;
}
