# Chapter 13, exercise 3 (solution): find the corrupted mbuf's pool name
# and reference count in a core file. Works without the bad_mbuf global
# too: the mbuf is the argument 'm' of the frame that called rte_panic.
set pagination off
frame function check_and_maybe_panic
info args
# the mbuf header, field by field
p m->refcnt
p m->data_len
p m->buf_len
# the pool: struct rte_mempool, reached through m->pool
p m->pool->name
p m->pool->size
p m->pool->elt_size
# the headroom + payload bytes of the packet
x/s (char *)m->buf_addr + m->data_off
