/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: ch13_trace.h - the application's own tracepoints.
 *
 * RTE_TRACE_POINT() declares an inline function ch13_trace_port_cfg(...)
 * that writes the listed fields into this thread's trace buffer when the
 * tracepoint is enabled at run time (--trace=<regex>). When it is disabled
 * the cost is one load and one branch.
 *
 * RTE_TRACE_POINT_FP() is the fast-path flavour: its body is compiled to
 * nothing unless RTE_ENABLE_TRACE_FP is defined when THIS file is compiled
 * (meson -Denable_trace_fp=true defines it for the DPDK libraries; for your
 * own code a -DRTE_ENABLE_TRACE_FP on the compiler line is enough).
 *
 * Every tracepoint must be registered exactly once, in one .c file:
 * see ch13_trace_reg.c.
 */
#ifndef CH13_TRACE_H
#define CH13_TRACE_H

#include <rte_trace_point.h>

/* slow path: once per port configuration */
RTE_TRACE_POINT(
	ch13_trace_port_cfg,
	RTE_TRACE_POINT_ARGS(uint16_t port, uint16_t nb_desc, const char *drv),
	rte_trace_point_emit_u16(port);
	rte_trace_point_emit_u16(nb_desc);
	rte_trace_point_emit_string(drv);
)

/* fast path: once per RX burst */
RTE_TRACE_POINT_FP(
	ch13_trace_burst,
	RTE_TRACE_POINT_ARGS(uint16_t port, uint16_t nb_rx),
	rte_trace_point_emit_u16(port);
	rte_trace_point_emit_u16(nb_rx);
)

#endif
