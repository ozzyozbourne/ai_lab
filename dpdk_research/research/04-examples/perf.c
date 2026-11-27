#include <stdio.h>
#include <rte_eal.h>
#include <rte_lcore.h>
#include <rte_ring.h>
#include <rte_mempool.h>
#include <rte_cycles.h>
#include <rte_launch.h>
#define ITER 2000000
static struct rte_ring *R; static unsigned BURST=32; static volatile int go;
static int prod(void*a){ void *o[64]; for(int i=0;i<64;i++)o[i]=(void*)1; while(!go); unsigned long s=0; while(s<ITER){ s+=rte_ring_enqueue_burst(R,o,BURST,NULL);} return 0;}
static int cons(void*a){ void *o[64]; while(!go); unsigned long s=0; uint64_t t=rte_rdtsc(); while(s<ITER){ s+=rte_ring_dequeue_burst(R,o,BURST,NULL);} *(uint64_t*)a=rte_rdtsc()-t; return 0;}
static struct rte_mempool *MP;
static int mpw(void*a){ void *o[32]; uint64_t t=rte_rdtsc(); for(int i=0;i<ITER/32;i++){ while(rte_mempool_get_bulk(MP,o,32)); rte_mempool_put_bulk(MP,o,32);} *(uint64_t*)a=rte_rdtsc()-t; return 0;}
int main(int c,char**v){ rte_eal_init(c,v);
 unsigned l1=rte_get_next_lcore(-1,1,0), l2=rte_get_next_lcore(l1,1,0);
 struct {const char*n; unsigned f;} m[]={{"SP/SC",RING_F_SP_ENQ|RING_F_SC_DEQ},{"MP/MC",0},{"MP_RTS/MC_RTS",RING_F_MP_RTS_ENQ|RING_F_MC_RTS_DEQ},{"MP_HTS/MC_HTS",RING_F_MP_HTS_ENQ|RING_F_MC_HTS_DEQ}};
 unsigned bursts[]={1,32};
 for(int b=0;b<2;b++) for(int i=0;i<4;i++){ char nm[32]; snprintf(nm,32,"p%d%d",b,i); R=rte_ring_create(nm,1024,0,m[i].f); BURST=bursts[b]; go=0; uint64_t cyc;
  rte_eal_remote_launch(prod,NULL,l1); rte_eal_remote_launch(cons,&cyc,l2); go=1; rte_eal_mp_wait_lcore();
  printf("ring %-14s burst=%2u : %.2f cycles/obj (1 prod lcore%u -> 1 cons lcore%u)\n",m[i].n,BURST,(double)cyc/ITER,l1,l2); }
 unsigned cs[]={0,256};
 for(int i=0;i<2;i++){ char nm[32]; snprintf(nm,32,"m%d",i); MP=rte_mempool_create(nm,8191,64,cs[i],0,NULL,NULL,NULL,NULL,0,0); uint64_t c1,c2;
  rte_eal_remote_launch(mpw,&c1,l1); rte_eal_remote_launch(mpw,&c2,l2); rte_eal_mp_wait_lcore();
  printf("mempool cache=%3u, 2 lcores get/put bulk32: %.2f cycles/obj\n",cs[i],(double)(c1+c2)/2/ITER); }
 rte_eal_cleanup(); }
