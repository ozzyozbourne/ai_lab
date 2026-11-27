#include <stdio.h>
#include <stddef.h>
#include <rte_eal.h>
#include <rte_ring.h>
#include <rte_ring_elem.h>
#include <rte_ring_peek.h>
#include <rte_ring_peek_zc.h>
#include <rte_mempool.h>
#include <rte_mbuf.h>
#include <rte_mbuf_dyn.h>
#include <rte_stack.h>
#include <rte_reorder.h>
#include <rte_errno.h>
#include <rte_malloc.h>
#include <rte_mbuf_pool_ops.h>

static void ext_free(void *addr, void *opaque){ printf("  ext_free_cb called addr=%p\n", addr); rte_free(addr);}
int main(int argc,char**argv){
  if(rte_eal_init(argc,argv)<0) return 1;
  printf("sizeof(rte_mbuf)=%zu off: buf_addr=%zu data_off=%zu refcnt=%zu nb_segs=%zu port=%zu ol_flags=%zu packet_type=%zu pkt_len=%zu data_len=%zu vlan_tci=%zu hash=%zu buf_len=%zu pool=%zu next=%zu tx_offload=%zu shinfo=%zu priv_size=%zu dynfield1=%zu\n",
   sizeof(struct rte_mbuf), offsetof(struct rte_mbuf,buf_addr), offsetof(struct rte_mbuf,data_off), offsetof(struct rte_mbuf,refcnt), offsetof(struct rte_mbuf,nb_segs), offsetof(struct rte_mbuf,port), offsetof(struct rte_mbuf,ol_flags), offsetof(struct rte_mbuf,packet_type), offsetof(struct rte_mbuf,pkt_len), offsetof(struct rte_mbuf,data_len), offsetof(struct rte_mbuf,vlan_tci), offsetof(struct rte_mbuf,hash), offsetof(struct rte_mbuf,buf_len), offsetof(struct rte_mbuf,pool), offsetof(struct rte_mbuf,next), offsetof(struct rte_mbuf,tx_offload), offsetof(struct rte_mbuf,shinfo), offsetof(struct rte_mbuf,priv_size), offsetof(struct rte_mbuf,dynfield1));
  printf("sizeof(rte_ring)=%zu prod off=%zu cons off=%zu\n", sizeof(struct rte_ring), offsetof(struct rte_ring,prod), offsetof(struct rte_ring,cons));
  /* ring capacity */
  struct rte_ring *r=rte_ring_create("r1",1024,SOCKET_ID_ANY,RING_F_SP_ENQ|RING_F_SC_DEQ);
  struct rte_ring *r2=rte_ring_create("r2",1000,SOCKET_ID_ANY,RING_F_EXACT_SZ);
  struct rte_ring *r3=rte_ring_create("r3",1000,SOCKET_ID_ANY,0);
  printf("ring 1024: size=%u cap=%u; EXACT 1000: size=%u cap=%u; non-pow2 1000 w/o EXACT -> %p rte_errno=%d(%s)\n", rte_ring_get_size(r),rte_ring_get_capacity(r),rte_ring_get_size(r2),rte_ring_get_capacity(r2),(void*)r3,rte_errno,rte_strerror(rte_errno));
  printf("memsize ring 1024 ptrs=%zd\n", rte_ring_get_memsize(1024));
  void *objs[2000]; for(int i=0;i<2000;i++) objs[i]=(void*)(uintptr_t)(i+1);
  unsigned fs; unsigned n=rte_ring_enqueue_bulk(r,objs,1500,&fs); printf("bulk enqueue 1500 into cap 1023 -> %u\n",n);
  n=rte_ring_enqueue_burst(r,objs,1500,&fs); printf("burst enqueue 1500 -> %u free=%u\n",n,fs);
  void *out[64]; n=rte_ring_dequeue_burst(r,out,64,NULL); printf("dequeue burst 64 -> %u first=%lu\n",n,(uintptr_t)out[0]);
  /* index wrap: show prod.head/tail values */
  printf("prod.head=%u prod.tail=%u cons.head=%u cons.tail=%u count=%u\n", r->prod.head, r->prod.tail, r->cons.head, r->cons.tail, rte_ring_count(r));
  /* peek API on SP/SC ring */
  void *o; n=rte_ring_dequeue_bulk_start(r,&o,1,NULL); printf("peek start got %lu; finish(0) keeps it\n",(uintptr_t)o); rte_ring_dequeue_finish(r,0);
  n=rte_ring_dequeue_bulk_start(r,&o,1,NULL); printf("peek again -> %lu (same)\n",(uintptr_t)o); rte_ring_dequeue_finish(r,1);
  /* zc enqueue on ST ring */
  rte_ring_reset(r);
  for(int k=0;k<1020;k++){ void*x; rte_ring_enqueue(r,objs[0]); rte_ring_dequeue(r,&x);} /* move indices near wrap */
  struct rte_ring_zc_data zcd; n=rte_ring_enqueue_zc_burst_start(r,8,&zcd,NULL);
  printf("zc start n=%u n1=%u ptr2=%p (wrap split)\n",n,zcd.n1,zcd.ptr2);
  for(unsigned i=0;i<zcd.n1;i++) ((void**)zcd.ptr1)[i]=objs[i]; for(unsigned i=zcd.n1;i<n;i++) ((void**)zcd.ptr2)[i-zcd.n1]=objs[i];
  rte_ring_enqueue_zc_finish(r,n); printf("count after zc=%u\n",rte_ring_count(r));
  /* elem ring with 16B elems */
  struct e16{uint64_t a,b;} ein[4]={{1,2},{3,4},{5,6},{7,8}}, eout[4];
  struct rte_ring *re=rte_ring_create_elem("re",sizeof(struct e16),64,SOCKET_ID_ANY,RING_F_MP_HTS_ENQ|RING_F_MC_HTS_DEQ);
  rte_ring_enqueue_bulk_elem(re,ein,sizeof(struct e16),4,NULL); rte_ring_dequeue_bulk_elem(re,eout,sizeof(struct e16),4,NULL);
  printf("elem ring HTS: eout[3]={%lu,%lu} prod sync=%d\n",eout[3].a,eout[3].b,rte_ring_get_prod_sync_type(re));
  struct rte_ring *rr=rte_ring_create("rts",1024,SOCKET_ID_ANY,RING_F_MP_RTS_ENQ|RING_F_MC_RTS_DEQ);
  printf("RTS htd_max prod=%u\n", rte_ring_get_prod_htd_max(rr));
  /* mempool */
  struct rte_mempool *mp=rte_mempool_create("mp",4095,64,256,0,NULL,NULL,NULL,NULL,SOCKET_ID_ANY,0);
  printf("mempool 4095 elt64 cache256: ops=%s avail=%u inuse=%u header=%u trailer=%u\n", rte_mempool_get_ops(mp->ops_index)->name, rte_mempool_avail_count(mp), rte_mempool_in_use_count(mp), mp->header_size, mp->trailer_size);
  struct rte_mempool_cache *c=rte_mempool_default_cache(mp,rte_lcore_id());
  void *g[300]; rte_mempool_get_bulk(mp,g,1); printf(" after get 1: cache len=%u (refill size/2=128 then -1)\n",c->len);
  rte_mempool_put_bulk(mp,g,1); printf(" after put 1: cache len=%u\n",c->len);
  rte_mempool_get_bulk(mp,g,200); printf(" after get 200 (>size/2): cache len=%u ring count=%u\n",c->len, rte_mempool_ops_get_count(mp));
  rte_mempool_put_bulk(mp,g,200); printf(" after put 200: cache len=%u\n",c->len);
  rte_mempool_cache_flush(c,mp); printf(" after flush: cache len=%u\n",c->len);
  /* stack mempool */
  const char *opsn[]={"ring_sp_sc","stack","lf_stack","pile","bucket","ring_mt_hts"};
  for(int i=0;i<6;i++){ char nm[32]; snprintf(nm,32,"mp_%s",opsn[i]);
    struct rte_mempool *m2=rte_mempool_create_empty(nm,1023,128,32,0,SOCKET_ID_ANY,0);
    int rc=rte_mempool_set_ops_byname(m2,opsn[i],NULL); int p= rc?rc:rte_mempool_populate_default(m2);
    printf(" ops %-12s set=%d populate=%d avail=%u\n",opsn[i],rc,p,rte_mempool_avail_count(m2)); }
  /* pktmbuf pool */
  struct rte_mempool *pp=rte_pktmbuf_pool_create("pp",511,32,16,RTE_MBUF_DEFAULT_BUF_SIZE,SOCKET_ID_ANY);
  printf("pktmbuf pool: elt_size=%u header=%u dataroom=%u priv=%u ops=%s best_ops=%s\n", pp->elt_size, pp->header_size, rte_pktmbuf_data_room_size(pp), rte_pktmbuf_priv_size(pp), rte_mempool_get_ops(pp->ops_index)->name, rte_mbuf_best_mempool_ops());
  struct rte_mbuf *m=rte_pktmbuf_alloc(pp);
  printf("new mbuf: data_off=%u headroom=%u tailroom=%u buf_len=%u refcnt=%u nb_segs=%u pkt_len=%u priv area %p buf_addr-m=%ld\n", m->data_off, rte_pktmbuf_headroom(m), rte_pktmbuf_tailroom(m), m->buf_len, rte_mbuf_refcnt_read(m), m->nb_segs, m->pkt_len, rte_mbuf_to_priv(m), (char*)m->buf_addr-(char*)m);
  char *p=rte_pktmbuf_append(m,100); memset(p,'A',100); p=rte_pktmbuf_prepend(m,14); printf("after append100+prepend14: data_off=%u data_len=%u pkt_len=%u\n",m->data_off,m->data_len,m->pkt_len);
  rte_pktmbuf_adj(m,14); rte_pktmbuf_trim(m,10); printf("after adj14 trim10: data_off=%u len=%u\n",m->data_off,m->pkt_len);
  printf("prepend 200 (>headroom) -> %p\n",(void*)rte_pktmbuf_prepend(m,200));
  struct rte_mbuf *m2=rte_pktmbuf_alloc(pp); rte_pktmbuf_append(m2,50);
  rte_pktmbuf_chain(m,m2); printf("chained: nb_segs=%u pkt_len=%u contig=%d\n",m->nb_segs,m->pkt_len,rte_pktmbuf_is_contiguous(m));
  char buf[200]; const char *rd=rte_pktmbuf_read(m,80,30,buf); printf("read across segs at 80 len30 -> copied=%d\n", rd==buf);
  {int lr=rte_pktmbuf_linearize(m); printf("linearize -> %d nb_segs=%u contig=%d\n", lr, m->nb_segs, rte_pktmbuf_is_contiguous(m));}
  printf("pool avail before clone=%u\n", rte_mempool_avail_count(pp));
  struct rte_mempool *ip=rte_pktmbuf_pool_create("indir",63,0,0,0,SOCKET_ID_ANY);
  struct rte_mbuf *cl=rte_pktmbuf_clone(m,ip);
  printf("clone: m refcnt=%u cl indirect=%d cl->buf_addr==m->buf_addr %d, indir elt_size=%u\n", rte_mbuf_refcnt_read(m), !!RTE_MBUF_CLONED(cl), cl->buf_addr==m->buf_addr, ip->elt_size);
  rte_pktmbuf_free(m); printf("after free(m): avail=%u (data still alive)\n", rte_mempool_avail_count(pp));
  rte_pktmbuf_free(cl); printf("after free(clone): avail=%u\n", rte_mempool_avail_count(pp));
  /* refcnt multi free */
  m=rte_pktmbuf_alloc(pp); rte_mbuf_refcnt_update(m,2); rte_pktmbuf_free(m); rte_pktmbuf_free(m); printf("refcnt3, freed twice: refcnt now=%u\n", rte_mbuf_refcnt_read(m)); rte_pktmbuf_free(m);
  /* extbuf */
  uint16_t blen=1024; void *eb=rte_malloc(NULL,blen+sizeof(struct rte_mbuf_ext_shared_info),64);
  struct rte_mbuf_ext_shared_info *sh=rte_pktmbuf_ext_shinfo_init_helper(eb,&blen,ext_free,NULL);
  m=rte_pktmbuf_alloc(pp); rte_pktmbuf_attach_extbuf(m,eb,rte_malloc_virt2iova(eb),blen,sh);
  printf("extbuf attached: HAS_EXTBUF=%d buf_len=%u shinfo refcnt=%u\n", !!RTE_MBUF_HAS_EXTBUF(m), m->buf_len, rte_mbuf_ext_refcnt_read(sh));
  cl=rte_pktmbuf_clone(m,ip); printf("clone of extbuf: ext refcnt=%u\n",rte_mbuf_ext_refcnt_read(sh));
  rte_pktmbuf_free(m); printf("freed orig\n"); rte_pktmbuf_free(cl);
  /* dynfield */
  struct rte_mbuf_dynfield d={.name="course_seq",.size=sizeof(uint32_t),.align=__alignof__(uint32_t)};
  int off=rte_mbuf_dynfield_register(&d); struct rte_mbuf_dynflag f={.name="course_flag"}; int bit=rte_mbuf_dynflag_register(&f);
  printf("dynfield off=%d (dynfield1 at %zu) dynflag bit=%d; lookup=%d\n",off,offsetof(struct rte_mbuf,dynfield1),bit,rte_mbuf_dynfield_lookup("course_seq",NULL));
  int ts=rte_mbuf_dyn_rx_timestamp_register(&off,NULL); printf("timestamp register rc=%d off=%d\n",ts,off);
  rte_mbuf_dyn_dump(stdout);
  /* ptype name */
  char pn[256]; rte_get_ptype_name(RTE_PTYPE_L2_ETHER|RTE_PTYPE_L3_IPV4|RTE_PTYPE_L4_UDP|RTE_PTYPE_TUNNEL_VXLAN|RTE_PTYPE_INNER_L3_IPV6|RTE_PTYPE_INNER_L4_TCP,pn,sizeof pn); printf("ptype: %s\n",pn);
  /* stack */
  struct rte_stack *s=rte_stack_create("st",16,SOCKET_ID_ANY,0), *sl=rte_stack_create("stlf",16,SOCKET_ID_ANY,RTE_STACK_F_LF);
  rte_stack_push(s,objs,5); void *po[5]; rte_stack_pop(s,po,5); printf("stack pop order: %lu %lu ..; LF stack=%p count=%u free=%u\n",(uintptr_t)po[0],(uintptr_t)po[1],(void*)sl,rte_stack_count(s),rte_stack_free_count(s));
  /* reorder */
  struct rte_reorder_buffer *rb=rte_reorder_create("rob",SOCKET_ID_ANY,8);
  printf("reorder seqn dynfield offset=%d\n", rte_reorder_seqn_dynfield_offset);
  uint32_t seqs[]={1,0,3,2,5,4,20,6};
  for(int i=0;i<8;i++){ struct rte_mbuf *x=rte_pktmbuf_alloc(pp); *rte_reorder_seqn(x)=seqs[i]; int rc=rte_reorder_insert(rb,x); printf(" insert %u rc=%d errno=%d\n",seqs[i],rc,rc?rte_errno:0); if(rc) rte_pktmbuf_free(x);}
  struct rte_mbuf *dr[16]; unsigned nd=rte_reorder_drain(rb,dr,16); printf(" drained %u:",nd); for(unsigned i=0;i<nd;i++){printf(" %u",*rte_reorder_seqn(dr[i])); rte_pktmbuf_free(dr[i]);} printf("\n");
  rte_mempool_dump(stdout,pp);
  rte_ring_dump(stdout,r);
  rte_eal_cleanup(); return 0; }
