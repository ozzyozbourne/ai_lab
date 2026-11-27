# Chapter 13: gdb_live.gdb - a guided gdb session on a running DPDK app.
# usage: gdb -batch -x gdb_live.gdb --args ./panic_demo <EAL args>
set pagination off
set print thread-events off
set print pretty off
# 1. stop inside the PMD's RX function, on the worker lcore's thread.
#    rte_eth_rx_burst() is an inline wrapper that calls through
#    rte_eth_fp_ops[port].rx_pkt_burst; the real code is eth_null_rx.
break eth_null_rx
run
bt 4
info threads
p rte_eth_fp_ops[0].rx_pkt_burst
p rte_eth_fp_ops[0].rx_pkt_burst == eth_null_rx
# 2. let it run into rte_panic -> abort -> SIGABRT
delete
continue
bt
frame function check_and_maybe_panic
printf "data_off=%u data_len=%u pkt_len=%u buf_len=%u refcnt=%u nb_segs=%u\n", m->data_off, m->data_len, m->pkt_len, m->buf_len, m->refcnt, m->nb_segs
p m->pool->name
# functions without debug info need their return type spelled out
p (unsigned int) rte_mempool_in_use_count(m->pool)
p (unsigned int) rte_mempool_avail_count(m->pool)
