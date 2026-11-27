# SPDX-License-Identifier: BSD-3-Clause
# Chapter 6 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

# ALLOW_EXPERIMENTAL_API: RTE_STACK_F_PILE (stack_demo.c) is experimental in 26.11.
CFLAGS += -O2 -g -Wall -Wextra -DALLOW_EXPERIMENTAL_API $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk) -lpthread

APPS = mempool_basics cache_explorer handler_bakeoff stranded_cache custom_ops stack_demo
SOLS = pool_sizing bakeoff_mp

all: $(APPS) $(SOLS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%: solutions/%.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -f $(APPS) $(SOLS)

.PHONY: all clean
