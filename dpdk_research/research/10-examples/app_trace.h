#include <rte_trace_point.h>
RTE_TRACE_POINT(
	app_trace_tick,
	RTE_TRACE_POINT_ARGS(uint64_t n, const char *tag),
	rte_trace_point_emit_u64(n);
	rte_trace_point_emit_string(tag);
)
