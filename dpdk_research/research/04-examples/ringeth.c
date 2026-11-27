#include <stdio.h>
#include <rte_eal.h>
#include <rte_ethdev.h>
#include <rte_eth_ring.h>
#include <rte_mbuf.h>
int main(int c,char**v){ rte_eal_init(c,v);
 struct rte_mempool *mp=rte_pktmbuf_pool_create("p",255,0,0,RTE_MBUF_DEFAULT_BUF_SIZE,0);
 struct rte_ring *r=rte_ring_create("loop",256,0,RING_F_SP_ENQ|RING_F_SC_DEQ);
 int port=rte_eth_from_ring(r);
 struct rte_eth_conf conf={0}; rte_eth_dev_configure(port,1,1,&conf);
 rte_eth_rx_queue_setup(port,0,128,0,NULL,mp); rte_eth_tx_queue_setup(port,0,128,0,NULL); rte_eth_dev_start(port);
 struct rte_mbuf *tx[4],*rx[4]; rte_pktmbuf_alloc_bulk(mp,tx,4);
 for(int i=0;i<4;i++){ char*d=rte_pktmbuf_append(tx[i],64); d[0]=i;}
 unsigned nt=rte_eth_tx_burst(port,0,tx,4); printf("port %d tx=%u ring count=%u\n",port,nt,rte_ring_count(r));
 unsigned nr=rte_eth_rx_burst(port,0,rx,4); for(unsigned i=0;i<nr;i++) printf(" rx[%u]=%p same as tx: %d\n",i,(void*)rx[i],rx[i]==tx[i]);
 rte_pktmbuf_free_bulk(rx,nr); printf("avail=%u\n",rte_mempool_avail_count(mp)); rte_eal_cleanup();}
