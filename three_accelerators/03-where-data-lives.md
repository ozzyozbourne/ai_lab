# 3. Where the data lives

All three machines put memory beside arithmetic. They differ in how much, in how it is
divided, and in what holds the weights of a model too big to fit.

## Cerebras: all of it in the processors

Each processing element owns 48 KB of SRAM. That one memory holds the PE's program, its
variables and its share of the model's weights. There is nothing else: no shared memory, no
DRAM on the wafer, no cache hierarchy above a few hundred bytes. A PE reads its own memory
in a single cycle, two 64-bit reads and one write per cycle [vendor, Hot Chips 2022].

Multiply 48 KB by 900,000 and the wafer holds 44 GB at that speed. The vendor's aggregate
figure is 21 PB/s of memory bandwidth [vendor], thousands of times a GPU's, because every PE
reads at once.

The price is the 48 KB limit. A program that needs more data in one place cannot have it;
the data must be spread across PEs, and the algorithm reshaped to match. The Cerebras
course measures the edge exactly: a single-PE matrix-vector product links at 104 × 104 and
fails at 105 × 105 for lack of memory (course chapter 1).

## Tenstorrent: a little close, a lot nearby

A Tensix core has 1,536 KiB of SRAM, called L1, on Blackhole (1,464 KiB on Wormhole)
[vendor]. L1 holds the kernels' code, the circular buffers that pass tiles between the
core's processors, and any tensor small enough to keep there.

Weights and large tensors live in GDDR6 DRAM at the edge of the die: 32 GB on a Blackhole
p150 card at 512 GB/s [vendor]. A core that needs a tile sends a read request across the
on-chip network to a DRAM tile and gets the data back in packets.

So Tenstorrent has two tiers, and the programmer chooses per tensor. Data in L1 is next to
the matrix engine. Data in DRAM is plentiful, cheap, and reached at a few hundred gigabytes
per second shared by the whole chip. The Tenstorrent course's performance chapter (A20)
puts numbers on the trade: with weights in DRAM a matrix multiply is limited by DRAM
bandwidth well before the matrix engines are busy.

## Groq: a little per chip, on a timetable

The TSP has 88 memory slices, 44 on each side of the central vector unit, 220 MiB in total
[vendor]. A memory slice is a column that reads or writes one 320-byte vector per cycle and
puts it on a stream. There is no addressing from the arithmetic side at all. A matrix unit
never asks for data. The compiler issues a `Read` to a memory slice at the right cycle so
that the vector, travelling one hop per cycle, reaches the unit exactly when the unit's own
instruction fires.

220 MiB holds a ResNet. It does not hold a large language model, so one model is split
across many chips, each holding a few layers' weights, with activations passed between them
(chapter 8).

## The same three machines, by where a 70B model's weights sit

| | Cerebras | Tenstorrent | Groq |
|---|---|---|---|
| Weights are stored in | SRAM inside the PEs that use them | DRAM on each chip | SRAM slices on each chip |
| Distance from weight to multiplier | Same PE | Across the on-chip network, from the die edge | A few stream hops, same chip |
| Chips or wafers for 140 GB | 4 wafers [vendor] | 5 or more chips' DRAM [derived: 140 / 32] | Hundreds or more [vendor, in general terms] |
| What limits token rate | Activations crossing the wafer and between wafers | DRAM bandwidth | Chip-to-chip hops and pipeline depth |

## Why the difference

Memory this close to logic costs area. About half of each Cerebras core is SRAM [vendor].
A company can pay that cost in three ways:

- **Make the silicon bigger.** Cerebras takes the whole wafer, so 44 GB fits. This needs
  wafer-scale yield and power engineering that nobody else has built (chapter 9).
- **Keep the fast memory small and add a slower tier.** Tenstorrent stays on a normal die
  and normal DRAM, which keeps cost and supply ordinary, and gives up bandwidth.
- **Keep the fast memory small and add chips.** Groq stays on a normal die with no slow
  tier, which keeps timing exact, and gives up density: many chips, many links.

None of the three found a way to have close, plentiful and cheap at once. Each kept two.
