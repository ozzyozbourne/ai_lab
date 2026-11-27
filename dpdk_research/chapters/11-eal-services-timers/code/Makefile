# SPDX-License-Identifier: BSD-3-Clause
# Chapter 11 Makefile. "source <dpdk-env.sh>" first so that pkg-config finds
# libdpdk.pc. Every program links DPDK statically.
#
# -DALLOW_EXPERIMENTAL_API: rte_argparse_parse() (step 5) and the rte_bitset
# functions (toolbox.c) are __rte_experimental in 26.11. Without the flag gcc
# warns "... is deprecated: Symbol is not yet part of stable ABI".

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

CFLAGS += -O2 -g -Wall -Wextra -D_GNU_SOURCE -DALLOW_EXPERIMENTAL_API $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk) -lpthread

STEPS = step1_timer step2_service step3_keepalive step4_cli step5_options
APPS  = alarm_demo toolbox
SOLS  = ex1_timer_service ex3_manage_cost ex4_burst_range

all: $(STEPS) $(APPS) $(SOLS)

%: evolve/%.c evolve/app_common.h
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%: solutions/%.c evolve/app_common.h
	$(CC) $(CFLAGS) -Ievolve $< -o $@ $(LDLIBS)

clean:
	rm -f $(STEPS) $(APPS) $(SOLS)

.PHONY: all clean
