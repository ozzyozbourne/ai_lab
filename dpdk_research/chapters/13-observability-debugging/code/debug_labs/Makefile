# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13 debug labs: each lab directory builds 'lab' (with the bug) and
# 'lab_fixed' (the same source with -DFIXED).
PKGCONF ?= pkg-config
CFLAGS += -O2 -g -Wall -Wextra $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk)
LABS = promisc_off mtu_noscatter leak double_free two_lcores_one_queue
BINS = $(foreach l,$(LABS),$(l)/lab $(l)/lab_fixed)

all: $(BINS)

%/lab: %/lab.c ../ch13_common.h
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%/lab_fixed: %/lab.c ../ch13_common.h
	$(CC) $(CFLAGS) -DFIXED $< -o $@ $(LDLIBS)

clean:
	rm -f $(BINS)

.PHONY: all clean
