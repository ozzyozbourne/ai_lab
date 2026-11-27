#include <stdio.h>
#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_errno.h>
int main(int c,char**v){ rte_eal_init(c,v);
 struct rte_mempool *p=rte_pktmbuf_pool_create("d",2047,256,0,RTE_MBUF_DEFAULT_BUF_SIZE,0);
 if(!p){printf("fail %s\n",rte_strerror(rte_errno));return 1;}
 size_t tot=0; struct rte_mempool_memhdr *h; STAILQ_FOREACH(h,&p->mem_list,next) tot+=h->len;
 printf("hugepages? %d chunks=%u mem=%zu bytes/obj=%.1f total_obj=%u\n", rte_eal_has_hugepages(), p->nb_mem_chunks, tot, (double)tot/p->size, p->header_size+p->elt_size+p->trailer_size);
 rte_eal_cleanup();}
