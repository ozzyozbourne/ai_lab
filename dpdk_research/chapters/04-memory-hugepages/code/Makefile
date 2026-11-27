# SPDX-License-Identifier: BSD-3-Clause
# Chapter 4 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Static link, as in the rest of the course.

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

# rte_memzone_max_set, rte_extmem_*, rte_mem_event_* are stable in 26.11;
# ALLOW_EXPERIMENTAL_API is still set so the exercises can try newer calls.
CFLAGS += -O2 -g -Wall -Wextra -DALLOW_EXPERIMENTAL_API $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk)

APPS = hello_memory tlb_bench sleeper memseg_walk memzones heap_events extmem_dma
SOLS = solutions/overhead solutions/no_cap

all: $(APPS) $(SOLS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

solutions/%: solutions/%.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -f $(APPS) $(SOLS)

.PHONY: all clean
