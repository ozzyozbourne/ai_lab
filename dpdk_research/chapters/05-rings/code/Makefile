# SPDX-License-Identifier: BSD-3-Clause
# Chapter 5 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

# ALLOW_EXPERIMENTAL_API: the SORING API (rte_soring_*) is experimental in 26.11.
CFLAGS += -O2 -g -Wall -Wextra -DALLOW_EXPERIMENTAL_API $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk)

APPS = ring_basics ring_wrap ring_modes_bench elem_peek soring_demo
SOLS = ring_basics_spsc pipeline3

all: $(APPS) $(SOLS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

# Exercise 1: the same ring_basics.c, with an SP/SC "pipe" ring.
ring_basics_spsc: ring_basics.c
	$(CC) $(CFLAGS) '-DPIPE_FLAGS=RING_F_SP_ENQ|RING_F_SC_DEQ' $< -o $@ $(LDLIBS)

# Exercise 2: three-stage pipeline.
pipeline3: solutions/pipeline3.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -f $(APPS) $(SOLS)

.PHONY: all clean
