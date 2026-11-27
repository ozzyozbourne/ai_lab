/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: trace_fp_on.h - force fast-path tracepoints ON for one build.
 *
 * Why not just -DRTE_ENABLE_TRACE_FP? Because the installed
 * rte_build_config.h (pulled in by rte_config.h, which every DPDK header
 * includes first) says "#undef RTE_ENABLE_TRACE_FP" when DPDK itself was
 * built without -Denable_trace_fp=true. A -D on the command line is undone
 * by that #undef. So: include rte_config.h first (its include guard stops a
 * second #undef), THEN define the macro. Build with:
 *     gcc -include trace_fp_on.h ...
 * This affects only code compiled into YOUR binary: your RTE_TRACE_POINT_FP
 * tracepoints and the inline ones of DPDK headers (rte_eth_rx_burst's).
 */
#include <rte_config.h>
#define RTE_ENABLE_TRACE_FP 1
