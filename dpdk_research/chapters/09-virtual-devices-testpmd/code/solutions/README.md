# Chapter 9 exercise solutions

- `ex1_flowgen.sh` (easy): flowgen with 1, 16 and 100 flows into a pcap file;
  `count_flows.py` counts distinct 5-tuples, xstats give the packet count.
- `ex2_csum.sh` (medium): a pcap with zero UDP and wrong TCP checksums replayed
  through `--forward-mode=csum`; read the RX/TX flags and check the output file.

Run from the `code/` directory: `./solutions/ex1_flowgen.sh`, `./solutions/ex2_csum.sh`.
