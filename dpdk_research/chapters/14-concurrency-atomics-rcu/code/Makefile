# SPDX-License-Identifier: BSD-3-Clause
# Chapter 14 Makefile. Run "source <dpdk-env.sh>" first so that pkg-config
# finds libdpdk.pc. Every program links DPDK statically.
#
#   make               build all programs and exercise solutions
#   make objdump       disassemble litmus_mp.o (x86-64, gcc -O2)
#   make objdump-arm   disassemble litmus_mp for AArch64 (clang cross-compile, no run)
#   make thread_safety clang -Wthread-safety static lock check (compile only)

PKGCONF ?= pkg-config

ifneq ($(shell $(PKGCONF) --exists libdpdk && echo 0),0)
$(error "no installation of DPDK found (is PKG_CONFIG_PATH set?)")
endif

# ALLOW_EXPERIMENTAL_API: lcore variables (rte_lcore_var_alloc) are
# experimental in 26.11; counters.c needs it.
CFLAGS += -O2 -g -Wall -Wextra -DALLOW_EXPERIMENTAL_API $(shell $(PKGCONF) --cflags libdpdk)
LDLIBS  = $(shell $(PKGCONF) --libs --static libdpdk) -lpthread

APPS = litmus locks_bench seqlock_cfg rcu_swap counters cas128
SOLS = rcu_dq port_26_11

all: $(APPS) $(SOLS)

%: %.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

%: solutions/%.c
	$(CC) $(CFLAGS) $< -o $@ $(LDLIBS)

# --- compiler reordering, seen in the machine code ---------------------------
OBJDUMP_FUNCS = writer_plain writer_barrier writer_relaxed writer_release \
		reader_plain reader_acquire

litmus_mp.o: litmus_mp.c
	$(CC) -O2 -Wall $(shell $(PKGCONF) --cflags libdpdk) -c $< -o $@

litmus_mp_arm.o: litmus_mp.c
	clang --target=aarch64-linux-gnu -O2 -Wall -DNO_DPDK -c $< -o $@

objdump: litmus_mp.o
	@for f in $(OBJDUMP_FUNCS); do \
		objdump -d --no-show-raw-insn --disassemble=$$f $< \
		| sed -n '/<'$$f'>:/,/^$$/p' | grep -v 'endbr64' | sed 's/^ *//; s/ *#.*//' ; \
	done

objdump-arm: litmus_mp_arm.o
	@for f in $(OBJDUMP_FUNCS); do \
		llvm-objdump -d --no-show-raw-insn --disassemble-symbols=$$f $< \
		| sed -n '/<'$$f'>:/,/^$$/p' | sed 's/^ *//; s/ *\/\/.*//' ; \
	done

# --- static lock checking (clang only, compile only) -------------------------
TS_FLAGS = -fsyntax-only -Wthread-safety -DRTE_ANNOTATE_LOCKS \
	   $(filter-out -march=%,$(shell $(PKGCONF) --cflags libdpdk))

thread_safety:
	-clang $(TS_FLAGS) thread_safety/counter_ts.c

clean:
	rm -f $(APPS) $(SOLS) litmus_mp.o litmus_mp_arm.o

.PHONY: all clean objdump objdump-arm thread_safety
