#include <stdio.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_dev.h>
#include <rte_cycles.h>
#include <rte_mbuf.h>
static const char *evn[] = {"UNKNOWN","INTR_LSC","QUEUE_STATE","INTR_RESET","VF_MBOX","MACSEC","INTR_RMV","NEW","DESTROY","IPSEC","FLOW_AGED","RX_AVAIL_THRESH","ERR_RECOVERING","RECOVERY_SUCCESS","RECOVERY_FAILED"};
static int cb(uint16_t p, enum rte_eth_event_type e, void *a, void *r){(void)a;(void)r;
  printf("[event] port=%u %s\n", p, e < 15 ? evn[e] : "?"); return 0;}
int main(int argc,char**argv){
  setvbuf(stdout,NULL,_IOLBF,0);
  if(rte_eal_init(argc,argv)<0) return 1;
  rte_eth_dev_callback_register(RTE_ETH_ALL, RTE_ETH_EVENT_NEW, cb, NULL);
  rte_eth_dev_callback_register(RTE_ETH_ALL, RTE_ETH_EVENT_DESTROY, cb, NULL);
  rte_eth_dev_callback_register(RTE_ETH_ALL, RTE_ETH_EVENT_INTR_LSC, cb, NULL);
  rte_eth_dev_callback_register(RTE_ETH_ALL, RTE_ETH_EVENT_QUEUE_STATE, cb, NULL);
  printf("hotplug net_null7 -> %d\n", rte_dev_probe("net_null7"));
  char vh[512]; snprintf(vh, sizeof vh, "net_vhost9,iface=%s,queues=1", argv[argc-1]);
  printf("hotplug vhost -> %d\n", rte_dev_probe(vh));
  uint16_t pid; struct rte_mempool *mp=rte_pktmbuf_pool_create("mp",1023,32,0,RTE_MBUF_DEFAULT_BUF_SIZE,0);
  RTE_ETH_FOREACH_DEV(pid){ struct rte_eth_conf c={0}; struct rte_eth_dev_info di; rte_eth_dev_info_get(pid,&di); c.intr_conf.lsc = !!(*di.dev_flags & RTE_ETH_DEV_INTR_LSC); printf("port %u lsc-capable=%d\n", pid, c.intr_conf.lsc);
    rte_eth_dev_configure(pid,1,1,&c); rte_eth_rx_queue_setup(pid,0,256,0,NULL,mp); rte_eth_tx_queue_setup(pid,0,256,0,NULL); rte_eth_dev_start(pid);}
  rte_delay_ms(9000);
  uint16_t np; rte_eth_dev_get_port_by_name("net_null7",&np); rte_eth_dev_stop(np); rte_eth_dev_close(np); printf("remove net_null7 -> %d\n", rte_eal_hotplug_remove("vdev","net_null7"));
  return 0;}
