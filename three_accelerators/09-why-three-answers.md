# 9. Why three answers exist

Three capable teams looked at the same problem and built three different machines. This
chapter argues that each design follows from one bet about what matters most, and that
each bet has a price the other two declined to pay.

## The bets

### Cerebras: communication is the bottleneck, so remove the boundaries

The bet: the cost that matters is moving data between pieces of silicon. If everything is
on one piece, with memory in every core, the problem mostly goes away.

What follows from it:

- The chip is a whole wafer, so a defect cannot be allowed to kill it. Cerebras builds
  970,000 cores to get 900,000 working ones and routes around the rest [vendor].
- Cores must be tiny and identical so that spares are cheap, which is why a PE is a small
  processor with 48 KB and not something larger.
- Tiny cores a few hops apart need a network with almost no per-message overhead, which is
  why routes are fixed and wavelets carry no address.
- Power and cooling for about 23 to 27 kW in one square of silicon had to be invented
  [vendor].

The price: a machine only Cerebras can build, in one size, programmed in its own language,
with a narrow connection to the outside world. Past the wafer edge its advantage stops.

### Tenstorrent: openness and ordinary parts win over time

The bet: the winning accelerator will be the one people can program, buy in small steps,
and extend. So use a standard-size chip, standard DRAM, standard Ethernet, RISC-V
processors and open-source software, and make the compute core good at matrix work.

What follows from it:

- Each core has general-purpose processors as well as a matrix engine, so that any
  operation can be written as software.
- Weights sit in DRAM, because that is how an ordinary-sized chip gets tens of gigabytes.
- The on-chip network carries addressed packets, because a general machine cannot assume
  it knows the traffic in advance.
- Scaling is by adding chips over Ethernet, from one card to a rack.

The price: DRAM bandwidth caps single-stream speed well below what the matrix engines
could do; the software stack is deep, with five processors per core to coordinate; and
between-chip links are slower than on-chip ones. Tenstorrent accepts a lower ceiling for a
lower floor: a single card is sold to individuals, and the same code runs on one chip or 32.

### Groq: unpredictability is the enemy, so remove everything that reacts

The bet: what an inference service needs is low, guaranteed latency for one request.
Caches, arbiters, queues and flow control all trade worst-case time for average speed. Take
them all out and let a compiler decide everything.

What follows from it:

- There are no processors issuing requests, only units fed by instruction queues.
- Data moves on streams with no flow control, so its position at every cycle is known.
- Memory is only SRAM on the chip. (Our reading: a memory whose access time can vary would break a schedule fixed to the cycle. Groq's own 2026 paper notes that host memory over PCIe is not deterministic and needs a resynchronisation instruction.)
- The same discipline must extend to the network between chips, or the guarantee is lost.

The price: every shape must be fixed before the run; dynamic behaviour becomes padding and
masks; compiling is slow; memory per chip is small, so systems are large; and independent
reports put peak throughput well below a GPU's and batching as limited (dossier section 3).
Groq traded throughput per chip for latency per request.

## One table

| | Cerebras | Tenstorrent | Groq |
|---|---|---|---|
| The bet | Keep everything on one piece of silicon | Be open, general and incremental | Remove every source of timing uncertainty |
| Optimises for | Speed of one stream on a very large model | Cost, flexibility, reach | Latency you can promise |
| Unusual hardware | Wafer-scale chip | RISC-V cluster plus matrix engine per core | No processors; scheduled streams |
| Where complexity went | Manufacturing and layout | Run-time software | The compiler |
| Hard limit | 48 KB per PE; the wafer edge | DRAM bandwidth | Fixed shapes; SRAM per chip |
| Smallest purchase | A system of one wafer | One card | A rack, or a cloud service |

## What they agree on

The differences are easier to see than the agreement, which is larger than it looks:

1. **Shared memory is over.** None of the three has a memory that all compute units
   address. Each unit has its own, and data is sent.
2. **Programs are placed in space.** Performance on all three is decided by layout: which
   data sits where, and how far it travels. This is why all three courses spend chapters on
   hop counts.
3. **The model is known before it runs.** All three rely on compiling for a specific model
   with specific sizes, and differ only in how much they fix: Tenstorrent the kernels,
   Cerebras the routes as well, Groq the timing as well.
4. **Arithmetic is not the constraint.** Each machine's own analysis says its multipliers
   wait for data. The designs are three ways of feeding them.

## A spectrum, not three islands

Line the machines up by how much is decided before the run:

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
A GPU sits further left than all three.

That is why three answers exist. The memory wall does not have one solution, because
"closest possible memory", "lowest possible cost of entry" and "exactly known latency"
pull a design in different directions, and a chip can only be built one way.

## Which to reach for

These are tendencies, drawn from each company's own description of its product and from
the limits measured or sourced in the three courses.

- **A very large model, one stream, as fast as possible:** the wafer. This is what
  Cerebras's inference service sells.
- **A latency promise for each request, on models that fit the system:** the scheduled
  machine. This is what Groq's design is for.
- **Owning hardware, writing new operations, starting small, or wanting open source down to
  the kernel:** Tenstorrent.
- **Anything with shapes that change during a run, or throughput across many users at
  once:** a GPU still does this most easily, which fits NVIDIA's decision to sell Groq-designed
  chips in racks paired with its GPUs rather than as a replacement for them.
