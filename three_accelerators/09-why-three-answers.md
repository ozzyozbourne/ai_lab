# 9. Why three answers exist

Three capable teams looked at the same problem and built three different machines. This
chapter argues that each design follows from one bet about what matters most, and that
each bet has a price the other two declined to pay.

The "bets" are this series' interpretation. No company describes itself in these words.
The facts under each bet carry their usual labels; the sentences that join them into an
argument are ours. Nothing here is about price: the sources used give no like-for-like
costs for the three machines.

## The bets

### Cerebras: communication is the bottleneck, so remove the boundaries

The bet: the cost that matters is moving data between pieces of silicon. If everything is
on one piece, with memory in every core, the problem mostly goes away.

What follows from it:

- The chip is a whole wafer, so a defect cannot be allowed to kill it. Cerebras builds
  970,000 cores to get 900,000 working ones and routes around the rest [vendor].
- Tiny, identical cores make spares cheap: a defect costs one core of about 0.05 mm²
  [vendor]. We read the small 48 KB PE as following from that.
- Tiny cores a few hops apart suit a network with almost no per-message overhead: routes
  are fixed and wavelets carry no address.
- Power delivery and cooling had to be built for a system that draws 23 kW (reported at
  launch) to 27 kW (the datasheet maximum) around one square of silicon [vendor].

The price: a machine that only Cerebras builds, in one size, programmed at the low level in
its own language, with a connection to the outside world that is narrow next to the fabric
inside. Past the wafer edge its advantage stops.

### Tenstorrent: openness and ordinary parts win over time

The bet, as we read it from what Tenstorrent publishes (open-source software, an open ISA
document, cards sold singly): the accelerator that wins will be the one people can program,
buy in small steps, and extend. So use a standard-size chip, standard DRAM, standard
Ethernet, RISC-V processors and open-source software, and make the compute core good at
matrix work.

What follows from it:

- Each core has general-purpose processors as well as a matrix engine, so that any
  operation can be written as software.
- Weights sit in DRAM, because that is how an ordinary-sized chip gets tens of gigabytes.
- The on-chip network carries addressed packets, which suits a general machine that does
  not know its traffic in advance.
- Scaling is by adding chips over Ethernet, from one card to a rack.

The price: DRAM bandwidth caps single-stream speed well below what the matrix engines
could do (Tenstorrent course, chapters A20 and A22); the software stack is deep, with five
processors per core to coordinate; and between-chip links are slower than on-chip ones.
In our reading Tenstorrent accepts a lower ceiling for a lower floor: a single card can be
bought on its own, and the same software stack runs one chip or 32.

### Groq: unpredictability is the enemy, so remove everything that reacts

The bet, as we read it from the two ISCA papers, which stress determinism and speed at a
batch size of one: what inference needs is low, predictable latency for one request.
Caches, arbiters, queues and flow control all make timing depend on what else is
happening. Take them all out and let a compiler decide everything.

What follows from it:

- There are no processors asking for data, only units fed by instruction queues.
- Data moves on streams with no flow control, so its position at every cycle is known.
- Memory is only SRAM on the chip. (Our reading: a memory whose access time can vary would break a schedule fixed to the cycle. Groq's own 2026 paper notes that host memory over PCIe is not deterministic and needs a resynchronisation instruction.)
- The same discipline must extend to the network between chips, or the guarantee is lost.

The price: every shape must be fixed before the run; dynamic behaviour becomes padding and
masks; compiling is slow; and memory per chip is small, so systems are large. One
independent evaluation of a 72-chip rack of the first chip measured roughly ten times lower
peak throughput than NVIDIA H100 GPUs and found that batch-size scaling was not supported
(dossier section 3). In our reading, Groq traded throughput per chip for latency per
request.

## One table

The first two rows are our interpretation; the rest summarise earlier chapters.

| | Cerebras | Tenstorrent | Groq |
|---|---|---|---|
| The bet | Keep everything on one piece of silicon | Be open, general and incremental | Remove every source of timing uncertainty |
| Optimises for | Speed of one stream on a very large model | Flexibility and a low cost of entry | Latency known in advance |
| Unusual hardware | Wafer-scale chip | RISC-V cluster plus matrix engine per core | No processors; scheduled streams |
| Where complexity went | Manufacturing and layout | Run-time software | The compiler |
| Hard limit | 48 KB per PE; the wafer edge | DRAM bandwidth | Fixed shapes; SRAM per chip |

## What they agree on

The differences are easier to see than the agreement, which is larger than it looks:

1. **No memory is reached through a hidden cache hierarchy.** On Cerebras each PE has only
   its own memory. On Tenstorrent each core has its own SRAM, and the shared DRAM is reached
   by explicit requests over the network. On Groq the memory slices serve the whole chip
   (the paper calls them "globally shared SRAM"), but only by putting vectors on streams at
   scheduled times. In all three, software says when data moves.
2. **Programs are placed in space.** Performance on all three is decided by layout: which
   data sits where, and how far it travels. All three courses count hops.
3. **Code is specialised to the model.** All three build code for specific tensor sizes,
   and differ in when and in how much they fix: Tenstorrent builds and caches kernels the
   first time an operation runs, Cerebras fixes code and routes before the run, Groq fixes
   the timing as well.
4. **Arithmetic is not the constraint.** The analyses in the three courses each find that
   for token generation the multipliers wait for data. The designs are three ways of
   feeding them.

## A spectrum, not three islands

Line the machines up by how much is decided before the run (our ordering, built from
chapters 4 to 6):

```
decided at run time                                   decided at compile time
        |                                                       |
   Tenstorrent  ───────────────  Cerebras  ───────────────  Groq
   routes per packet            routes fixed                routes fixed
   timing by flow control       timing by arrival           timing fixed
   kernels compiled on use      code and layout fixed       every cycle fixed
```

Moving right buys predictability and strips out hardware that exists only to cope with
surprise. Moving left buys generality: the ability to run something nobody planned for.
A GPU, with its caches and run-time schedulers (chapter 1), sits further left than all
three.

That, we think, is why three answers exist. The memory wall does not have one solution, because
"closest possible memory", "lowest possible cost of entry" and "exactly known latency"
pull a design in different directions, and a chip can only be built one way.

## Which to reach for

These are tendencies, and they are our opinion, drawn from the limits measured or sourced
in the three courses. They are not buying advice, and none of the three simulators measures
real speed.

- **A very large model, one stream, as fast as possible:** the wafer. This is the case
  Cerebras's Hot Chips 2024 talk presents.
- **Latency known in advance for each request, on models that fit the system:** the
  scheduled machine. Predictable latency is the 2020 Groq paper's stated aim.
- **Writing new operations, starting with one card, or wanting open source down to the
  kernel:** Tenstorrent.
- **Anything with shapes that change during a run, or throughput across many users at
  once:** a GPU still does this most easily. NVIDIA sells its Groq-designed chips in racks
  that work alongside its GPU racks [vendor]; we read that as the two being complementary.
