# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13 band 2 project. 'make' builds the solution; to test your own
# version, put it in my_l2fwd_mc.c and run 'make mine && BIN=./my_l2fwd_mc ./run.sh'.
PKGCONF ?= pkg-config
CFLAGS += -O2 -g -Wall -Wextra $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk)

all: l2fwd_mc
l2fwd_mc: solution/l2fwd_mc.c ../ch13_common.h
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)
mine: my_l2fwd_mc.c ../ch13_common.h
	$(CC) $(CFLAGS) $< -o my_l2fwd_mc $(LDLIBS)
clean:
	rm -f l2fwd_mc my_l2fwd_mc
.PHONY: all mine clean
