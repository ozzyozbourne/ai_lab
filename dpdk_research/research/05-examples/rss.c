#include <stdio.h>
#include <rte_thash.h>
#include <rte_ip.h>
static uint8_t key[40] = {0x6d,0x5a,0x56,0xda,0x25,0x5b,0x0e,0xc2,0x41,0x67,0x25,0x3d,0x43,0xa3,0x8f,0xb0,0xd0,0xca,0x2b,0xcb,0xae,0x7b,0x30,0xb4,0x77,0xcb,0x2d,0xa3,0x80,0x30,0xf2,0x0c,0x6a,0x42,0xb7,0x3b,0xbe,0xac,0x01,0xfa};
static uint8_t symkey[40];
int main(void){
  /* MS test vector: src 66.9.149.187:2794 dst 161.142.100.80:1766 -> 0x51ccc178 */
  struct rte_ipv4_tuple t = { .src_addr = RTE_IPV4(66,9,149,187), .dst_addr = RTE_IPV4(161,142,100,80), .sport = 2794, .dport = 1766 };
  uint32_t h = rte_softrss((uint32_t*)&t, RTE_THASH_V4_L4_LEN, key);
  printf("toeplitz(test vector) = 0x%08x (expect 0x51ccc178)\n", h);
  struct rte_ipv4_tuple r = { .src_addr = t.dst_addr, .dst_addr = t.src_addr, .sport = t.dport, .dport = t.sport };
  printf("reverse direction       = 0x%08x (asymmetric!)\n", rte_softrss((uint32_t*)&r, RTE_THASH_V4_L4_LEN, key));
  for (int i=0;i<40;i+=2){symkey[i]=0x6d;symkey[i+1]=0x5a;}
  printf("symmetric key fwd/rev   = 0x%08x / 0x%08x\n", rte_softrss((uint32_t*)&t, RTE_THASH_V4_L4_LEN, symkey), rte_softrss((uint32_t*)&r, RTE_THASH_V4_L4_LEN, symkey));
  /* distribution over a 128-entry RETA filled round-robin with 4 queues */
  unsigned q[4]={0}; uint8_t reta[128]; for(int i=0;i<128;i++) reta[i]=i%4;
  for (unsigned s=0;s<10000;s++){ struct rte_ipv4_tuple x={.src_addr=RTE_IPV4(10,0,s>>8,s&255),.dst_addr=RTE_IPV4(10,1,0,1),.sport=1000+s,.dport=80};
    uint32_t hh=rte_softrss((uint32_t*)&x,RTE_THASH_V4_L4_LEN,key); q[reta[hh & 127]]++; }
  printf("10000 flows over 4 queues: %u %u %u %u\n", q[0],q[1],q[2],q[3]);
  return 0; }
