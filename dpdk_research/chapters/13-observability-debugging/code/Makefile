# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.
PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

CFLAGS += -O2 -g -Wall -Wextra $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk)
# the trace API (rte_trace_*.h) is experimental in 26.11
EXP     = -DALLOW_EXPERIMENTAL_API

APPS = telemetry_app latency_metrics logdp trace_demo trace_demo_fp \
       panic_demo asan_demo asan_demo_asan port_rates

all: $(APPS) labs band2

%: %.c ch13_common.h
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

trace_demo: trace_demo.c ch13_trace_reg.c ch13_trace.h ch13_common.h
	$(CC) $(CFLAGS) $(EXP) trace_demo.c ch13_trace_reg.c -o $@ $(LDLIBS)

# the same source with fast-path tracepoints compiled in (see trace_fp_on.h)
trace_demo_fp: trace_demo.c ch13_trace_reg.c ch13_trace.h trace_fp_on.h ch13_common.h
	$(CC) $(CFLAGS) $(EXP) -include trace_fp_on.h trace_demo.c ch13_trace_reg.c -o $@ $(LDLIBS)

# -O0 so that gdb shows every local variable and frame exactly
panic_demo: panic_demo.c ch13_common.h
	$(CC) $(CFLAGS) -O0 $< -o $@ $(LDLIBS)

# gcc's AddressSanitizer (the clang runtime is not installed here)
asan_demo_asan: asan_demo.c ch13_common.h
	$(CC) $(CFLAGS) -O1 -fsanitize=address -fno-omit-frame-pointer $< -o $@ $(LDLIBS)

port_rates: solutions/port_rates.c ch13_common.h
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

labs:
	$(MAKE) -s -C debug_labs

band2:
	$(MAKE) -s -C band2_project

clean:
	rm -f $(APPS)
	$(MAKE) -s -C debug_labs clean
	$(MAKE) -s -C band2_project clean

.PHONY: all labs band2 clean
