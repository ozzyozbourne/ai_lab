#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <inttypes.h>
#include <rte_eal.h>
#include <rte_memzone.h>
int main(int argc, char **argv) {
  if (rte_eal_init(argc, argv) < 0) return 1;
  const struct rte_memzone *mz;
  if (rte_eal_process_type() == RTE_PROC_PRIMARY) {
    mz = rte_memzone_reserve("shared_cfg", 4096, SOCKET_ID_ANY, 0);
    strcpy(mz->addr, "hello from primary");
    printf("[primary] mz at va=%p iova=0x%" PRIx64 "\n", mz->addr, mz->iova); fflush(stdout);
    sleep(4);
  } else {
    mz = rte_memzone_lookup("shared_cfg");
    printf("[secondary] lookup -> va=%p iova=0x%" PRIx64 " content='%s'\n", mz ? mz->addr : NULL, mz ? mz->iova : 0, mz ? (char *)mz->addr : "");
  }
  rte_eal_cleanup(); return 0;
}
