# Chapter 01, exercise 2: burst size vs cycles per packet

bypass_bench already accepts burst sizes after `--`:

    ./bypass_bench -l 1 --no-pci --no-huge -m 128 --file-prefix=ch01-bb --vdev=net_null0 -- 1 8 32

run.sh runs exactly this; see section 3 of ../expected_output.txt for the
measured numbers (median of 5 runs, with min and max). Try more sizes,
e.g. `-- 1 2 4 8 16 32 64 128`, and plot cycles/packet against burst size.
The fixed cost of each rx_burst()+tx_burst() pair is shared by n packets, so
the curve falls quickly and then flattens at the per-packet cost.
