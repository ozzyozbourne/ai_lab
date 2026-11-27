#include <stdio.h>
#include <inttypes.h>
#include <signal.h>
#include <stdlib.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_cycles.h>
static volatile int quit;
static void sig(int s){(void)s;quit=1;}
static int lsc(uint16_t p, enum rte_eth_event_type e, void *a, void *r){(void)a;(void)r;
  struct rte_eth_link l; char s[64]; rte_eth_link_get_nowait(p,&l); rte_eth_link_to_str(s,64,&l);
  printf("LSC event %d port %u: %s\n", e, p, s); fflush(stdout); return 0;}
int main(int argc,char**argv){
  if(rte_eal_init(argc,argv)<0) return 1; signal(SIGINT,sig); setvbuf(stdout,NULL,_IOLBF,0);
  struct rte_mempool *mp=rte_pktmbuf_pool_create("mp",2047,64,0,RTE_MBUF_DEFAULT_BUF_SIZE,rte_socket_id());
  struct rte_eth_dev_info di; rte_eth_dev_info_get(0,&di);
  struct rte_eth_conf c={0}; c.intr_conf.lsc=getenv("LSC")?1:0;
  if(getenv("CK")) c.rxmode.offloads = di.rx_offload_capa & (RTE_ETH_RX_OFFLOAD_IPV4_CKSUM|RTE_ETH_RX_OFFLOAD_UDP_CKSUM|RTE_ETH_RX_OFFLOAD_TCP_CKSUM);
  printf("configure lsc=1 -> %d\n", rte_eth_dev_configure(0,1,1,&c));
  rte_eth_rx_queue_setup(0,0,512,0,NULL,mp); rte_eth_tx_queue_setup(0,0,512,0,NULL);
  rte_eth_dev_callback_register(0,RTE_ETH_EVENT_INTR_LSC,lsc,NULL);
  uint32_t ptypes[32]; int np=rte_eth_dev_get_supported_ptypes(0,RTE_PTYPE_ALL_MASK,ptypes,32); printf("supported ptypes: %d\n",np);
  rte_eth_dev_start(0); if(getenv("PROMISC")) rte_eth_promiscuous_enable(0); printf("started promisc=%d\n", rte_eth_promiscuous_get(0)); fflush(stdout);
  uint64_t end=rte_get_tsc_cycles()+rte_get_tsc_hz()*8;
  while(!quit && rte_get_tsc_cycles()<end){
    struct rte_mbuf *b[32]; uint16_t n=rte_eth_rx_burst(0,0,b,32);
    for(int i=0;i<n;i++){ char pt[128]; rte_get_ptype_name(b[i]->packet_type,pt,sizeof pt);
      printf("rx len=%u ptype=%s ol_flags=0x%" PRIx64 " ipcksum=%s l4cksum=%s\n", b[i]->pkt_len, pt, b[i]->ol_flags,
        (b[i]->ol_flags&RTE_MBUF_F_RX_IP_CKSUM_MASK)==RTE_MBUF_F_RX_IP_CKSUM_GOOD?"GOOD":"other",
        (b[i]->ol_flags&RTE_MBUF_F_RX_L4_CKSUM_MASK)==RTE_MBUF_F_RX_L4_CKSUM_GOOD?"GOOD":((b[i]->ol_flags&RTE_MBUF_F_RX_L4_CKSUM_MASK)==RTE_MBUF_F_RX_L4_CKSUM_BAD?"BAD":"other"));
      rte_pktmbuf_free(b[i]); }
  }
  { struct rte_eth_stats st; rte_eth_stats_get(0,&st); printf("end: ipackets=%" PRIu64 " ierr=%" PRIu64 " nombuf=%" PRIu64 " quit=%d\n", st.ipackets, st.ierrors, st.rx_nombuf, quit);}
  rte_eth_dev_stop(0); rte_eth_dev_close(0); rte_eal_cleanup(); return 0;}
