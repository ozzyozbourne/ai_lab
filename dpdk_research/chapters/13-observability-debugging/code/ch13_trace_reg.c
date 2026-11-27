/* SPDX-License-Identifier: BSD-3-Clause
 * Chapter 13: ch13_trace_reg.c - the ONE translation unit that registers
 * the tracepoints. rte_trace_point_register.h must come BEFORE the header
 * that defines them: it switches RTE_TRACE_POINT() from "declare an inline
 * emitter" to "emit the field descriptions for the CTF metadata".
 * RTE_TRACE_POINT_REGISTER(object, name) gives each one the name that
 * --trace=<regex> matches (here "ch13.port_cfg" and "ch13.burst").
 */
#include <rte_trace_point_register.h>
#include "ch13_trace.h"

RTE_TRACE_POINT_REGISTER(ch13_trace_port_cfg, ch13.port_cfg)
RTE_TRACE_POINT_REGISTER(ch13_trace_burst, ch13.burst)
