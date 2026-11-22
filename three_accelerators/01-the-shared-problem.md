# 1. The problem all three are solving

## Arithmetic is cheap; moving data is not

Running a neural network is mostly multiply-and-add. The multiplies are not the hard part.
The hard part is that every weight must reach a multiplier, and a large model has far more
weights than fit next to the arithmetic.

One number makes this concrete. Generating one token with a 70-billion-parameter model at
16 bits per weight reads about 140 GB of weights [derived: 70 × 10⁹ × 2 bytes]. A chip that
can do the arithmetic in a millisecond still takes as long as it takes to deliver 140 GB to
its multipliers. The limit is memory bandwidth, in bytes per second, not arithmetic, in
operations per second.

The standard way to draw this is a *roofline*. Divide a chip's peak arithmetic rate by its
memory bandwidth and you get a ridge, in operations per byte. A workload that does fewer
operations per byte than the ridge is waiting for memory. Single-stream token generation
does about one operation per weight byte (one multiply-add, counted as two operations, per
two-byte weight), and current GPUs have ridges in the hundreds [derived in the Cerebras
course, chapter 1, from vendor figures: an H100 is about 295 FLOP per byte at dense BF16,
a 16-bit floating-point format]. So the arithmetic units of a GPU that is serving one user
spend most of their time idle.

## What a GPU does about it

A GPU keeps weights in high-bandwidth DRAM stacked beside the die (HBM), and hides the gap
in two ways. It caches: small, fast memories near the arithmetic hold whatever is in use.
And it batches: many users share one pass over the weights, so each weight byte feeds many
multiplies. Batching raises throughput without making any one user's tokens arrive sooner.

Both remedies are *reactive*. Caches, schedulers and arbiters decide at run time what to
fetch and what to wait for. They work well on average and give no guarantee for a single
request.

## What the three machines have in common

Cerebras, Tenstorrent and Groq each start from the same diagnosis and share four choices:

1. **Memory sits next to arithmetic.** All three spread SRAM (fast memory built from the
   same transistors as the logic) through the compute fabric, so that the data a multiplier
   is working on is a few wires away, not across a package boundary. Tenstorrent also keeps
   a larger, slower DRAM outside the chip (chapter 3).
2. **The machine is a grid, and the program is laid out on it.** A model is placed in space:
   this layer here, that one beside it. Data flows between neighbours. None of the three is
   a pool of interchangeable cores fed through caches from one shared memory.
3. **Communication is explicit.** There is no cache hierarchy that quietly fetches things.
   The program, or its compiler, says which data goes where.
4. **Software does work that hardware does elsewhere.** Placement is decided before the
   run on all three, routes on two of them (Cerebras and Groq), and exact timing on one
   (Groq).

## Where they part

They part on three questions, which give the next chapters their order:

| Question | Cerebras | Tenstorrent | Groq |
|---|---|---|---|
| How much memory can be kept that close? (ch. 3) | A whole wafer of it | A little per core, the rest in ordinary DRAM | A little per chip, so many chips |
| How does data get from one place to another? (ch. 4) | Along routes fixed before the run | In addressed packets routed as they go | On conveyor belts that never stop |
| Who decides when an operation happens? (ch. 5) | The data, on arrival | The data, with flow control | The compiler, to the cycle |

The rest of this series works through those three questions, then asks what each choice
costs (chapter 9).
