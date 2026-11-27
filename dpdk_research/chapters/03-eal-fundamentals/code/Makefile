# SPDX-License-Identifier: BSD-3-Clause
# Chapter 3 Makefile: every program links DPDK statically through pkg-config.
# Run "source <dpdk-env.sh>" first so pkg-config finds libdpdk.pc.

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

CFLAGS += -O2 -g -Wall -Wextra $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk)

APPS      = eal_tour log_lab tsc_lab
SOLUTIONS = reverse_wait clean_stop

all: $(APPS) $(SOLUTIONS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

reverse_wait clean_stop: %: solutions/%.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

# Exercise 3: this target is EXPECTED to fail (RTE_LOG_LINE rejects '\n').
newline_bad: solutions/newline_bad.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

clean:
	rm -f $(APPS) $(SOLUTIONS) newline_bad

.PHONY: all clean
