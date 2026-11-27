#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_udp.h>
#include <rte_tcp.h>
#include <rte_cycles.h>
#include <rte_gso.h>
static struct rte_mbuf *mk(struct rte_mempool *mp, int tcp, int paylen){
  struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
  int l4 = tcp ? sizeof(struct rte_tcp_hdr) : sizeof(struct rte_udp_hdr);
  char *p = rte_pktmbuf_append(m, 14 + 20 + l4 + paylen);
  struct rte_ether_hdr *e = (void*)p; memset(e->dst_addr.addr_bytes,0xff,6); rte_eth_macaddr_get(0,&e->src_addr); e->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);
  struct rte_ipv4_hdr *ip = (void*)(p+14); memset(ip,0,20); ip->version_ihl = 0x45; ip->time_to_live = 64;
  ip->next_proto_id = tcp ? IPPROTO_TCP : IPPROTO_UDP; ip->total_length = rte_cpu_to_be_16(20 + l4 + paylen);
  ip->src_addr = rte_cpu_to_be_32(RTE_IPV4(10,58,0,2)); ip->dst_addr = rte_cpu_to_be_32(RTE_IPV4(10,58,0,1));
  ip->hdr_checksum = 0; /* deliberately NOT computed in software */
  if (tcp) { struct rte_tcp_hdr *t = (void*)(ip+1); memset(t,0,sizeof *t); t->src_port=rte_cpu_to_be_16(5555); t->dst_port=rte_cpu_to_be_16(7777); t->data_off = 5<<4; t->tcp_flags = RTE_TCP_ACK_FLAG|RTE_TCP_PSH_FLAG; t->rx_win = 0xffff;
    t->cksum = rte_ipv4_phdr_cksum(ip, RTE_MBUF_F_TX_TCP_SEG); }
  else { struct rte_udp_hdr *u = (void*)(ip+1); u->src_port=rte_cpu_to_be_16(5555); u->dst_port=rte_cpu_to_be_16(9999); u->dgram_len=rte_cpu_to_be_16(8+paylen);
    u->dgram_cksum = rte_ipv4_phdr_cksum(ip, 0); /* pseudo-header only, NIC completes */ }
  memset(p+14+20+l4, 'A', paylen);
  m->l2_len = 14; m->l3_len = 20; m->l4_len = l4;
  m->ol_flags = RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM | (tcp ? RTE_MBUF_F_TX_TCP_SEG : RTE_MBUF_F_TX_UDP_CKSUM);
  if (tcp) m->tso_segsz = 1000;
  return m; }
int main(int argc,char**argv){
  if(rte_eal_init(argc,argv)<0) return 1; setvbuf(stdout,NULL,_IOLBF,0);
  struct rte_mempool *mp=rte_pktmbuf_pool_create("mp",2047,64,0,RTE_MBUF_DEFAULT_BUF_SIZE+4096,0);
  struct rte_eth_dev_info di; rte_eth_dev_info_get(0,&di);
  uint64_t want = RTE_ETH_TX_OFFLOAD_IPV4_CKSUM|RTE_ETH_TX_OFFLOAD_UDP_CKSUM|RTE_ETH_TX_OFFLOAD_TCP_TSO|RTE_ETH_TX_OFFLOAD_TCP_CKSUM;
  printf("tx capa 0x%lx, want 0x%lx, missing 0x%lx\n", di.tx_offload_capa, want, want & ~di.tx_offload_capa);
  struct rte_eth_conf c={0}; c.txmode.offloads = want & di.tx_offload_capa;
  rte_eth_dev_configure(0,1,1,&c); rte_eth_rx_queue_setup(0,0,256,0,NULL,mp); rte_eth_tx_queue_setup(0,0,256,0,NULL);
  rte_eth_dev_start(0); rte_delay_ms(2500);
  struct rte_mbuf *b[2] = { mk(mp,0,32), mk(mp,1,3000) };
  { struct rte_mbuf *t = mk(mp,1,3000); struct rte_gso_ctx g = {.direct_pool=mp,.indirect_pool=mp,.gso_types=RTE_ETH_TX_OFFLOAD_TCP_TSO,.gso_size=1054,.flag=0}; struct rte_mbuf *o[16]; int r = rte_gso_segment(t,&g,o,16); printf("direct rte_gso_segment -> %d\n", r); }
  uint16_t np = rte_eth_tx_prepare(0,0,b,2); printf("tx_prepare ok for %u/2 (rte_errno=%d)\n", np, rte_errno);
  uint16_t ns = rte_eth_tx_burst(0,0,b,np); if (ns < np) printf("unsent pkt: pkt_len=%u nb_segs=%u ol=0x%lx\n", b[ns]->pkt_len, b[ns]->nb_segs, b[ns]->ol_flags); printf("tx_burst sent %u\n", ns);
  rte_delay_ms(1500); struct rte_eth_stats st; rte_eth_stats_get(0,&st); printf("opackets=%lu obytes=%lu oerrors=%lu\n", st.opackets, st.obytes, st.oerrors);
  rte_eth_dev_stop(0); rte_eth_dev_close(0); rte_eal_cleanup(); return 0; }
