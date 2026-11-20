# 8. Growing past one chip

No single chip holds a large model and serves many users. Each company had to decide what
joins one piece of silicon to the next, and each answer follows from the single-chip design.

## Cerebras: make the chip so big that crossing a boundary is rare

The wafer is Cerebras's answer to scaling. On it, 900,000 PEs talk over the same fabric at
the same speed; there is no boundary to cross. The off-wafer links are narrow by
comparison: 1.2 Tb/s of Ethernet for a whole CS-3 system [vendor], against 26.8 PB/s of
fabric bandwidth on the wafer [vendor].

So the software's job is to keep traffic on the wafer:

- **For inference**, a model is cut into runs of consecutive layers, one run per wafer.
  Only the activations at each cut cross to the next wafer. Cerebras's Hot Chips 2024 talk
  describes a 70-billion-parameter model on four WSE-3 systems, 20 layers each, using a
  small fraction of the Ethernet capacity for the hand-off [vendor].
- **For training**, an external store called MemoryX holds the weights and streams them to
  the wafers, and a fabric called SwarmX broadcasts weights out and sums gradients back
  [vendor].
- **The next system, CS-4**, puts three wafers in one rack and doubles the per-wafer I/O to
  2.4 Tb/s [vendor].

## Tenstorrent: the network continues off the chip as Ethernet

A Tenstorrent chip has Ethernet tiles in its grid: 16 ports of 100 GbE on Wormhole, 10 of
400 GbE on Blackhole [vendor]. Each has its own small processor running firmware that
forwards packets. To the software, a core on another chip is addressed much like a core on
the same one, with extra hops.

Products are built by wiring chips into a mesh: two on one card, eight in a workstation, 32
in a Galaxy server arranged 4 × 8 [vendor]. Meshes of servers extend the same way, with no
separate switch.

The cost is that the link between chips is slower than the links inside one. On Wormhole an
Ethernet link carries 12.5 GB/s against 32 GB/s for an on-chip network link; on Blackhole 50
against 86 [vendor figures; the Blackhole Galaxy currently runs its links at half rate].
So multi-chip programs are written to split a model so that each chip does as much as it
can locally: tensors are sharded across chips, and special operations (all-gather,
reduce-scatter) move only what must move. Large models are run with each layer's matrices
split across several chips in parallel.

ttsim models this. It ships multi-chip builds, and the Tenstorrent course's lab B10 runs a
two-chip program on one.

## Groq: schedule the cables too

A Groq chip has too little memory for a large model (chapter 3), so many chips are the
normal case, not the large case. The 2022 paper describes 8 chips per node, fully
connected; 9 nodes per rack; and a Dragonfly network reaching 264 chips within 3 hops and
10,440 within 5 [vendor]. Each chip uses 7 local and 4 global links.

What is unusual is how the links are run. There is no flow control, no arbitration, no
retry at the link level [vendor]. The compiler partitions the model, emits one program per
chip, and schedules every transfer between chips at a fixed time, just as it schedules
streams inside a chip. To make that possible the chips must agree on what time it is, even
though each has its own clock:

- Chips continuously exchange a counter and align to it; a `DESKEW` instruction pauses a
  chip until the shared counter wraps [vendor].
- A second, software-visible counter compensates for clocks drifting apart during a run.
- Link errors are handled by forward error correction; an error too large to correct causes
  the whole inference to be replayed [vendor].

The paper reports that a cable hop between chips in a node takes about 216 cycles, and that
the compiler's prediction of a model's latency was within 2% of the measured value
[vendor]. The current generation, sold by NVIDIA, has 96 links per chip and 256 chips per
rack [vendor].

`sim_grok_1` models a single chip only; the multi-chip instructions are listed as left out.

## Side by side

| | Cerebras | Tenstorrent | Groq |
|---|---|---|---|
| Typical unit | One wafer | One chip; 32 in a server | One chip; hundreds in a system |
| What joins units | Ethernet at the system edge; direct wafer links in CS-4 | Ethernet ports on every chip, wired as a mesh | Dedicated chip-to-chip links |
| On-unit versus between-unit bandwidth | Enormous gap | Moderate gap | Links are the main path |
| Who schedules between-unit traffic | Run-time software | Run-time software and firmware, with flow control | The compiler, to the cycle |
| What crosses | Activations between runs of layers | Shards of tensors; activations | Activations and partial results, on a timetable |
| A lost or corrupted transfer | Handled by the network stack | Retransmitted by the fabric | Corrected, or the whole inference is replayed |
| Modelled in the simulator used here | Not beyond the fabric | Yes, two-chip and larger builds | No |

## Why the difference

The scaling story is the single-chip story repeated one level up.

- Cerebras put everything on one wafer so that communication would be uniform and fast.
  Past the wafer edge that advantage ends abruptly, so it cuts models where little data
  crosses, and its roadmap is about widening that edge.
- Tenstorrent built a chip that is a grid of cores joined by a packet network. Extending
  the packets over Ethernet makes a bigger grid out of the same parts. It scales smoothly
  and in small steps, and every step adds slower links.
- Groq built a chip with no reactive parts. A network with flow control would have put the
  uncertainty back, so the network is scheduled as well. The reward is a system of
  hundreds of chips whose latency is still known in advance; the price is clock alignment
  machinery and a compiler that must schedule the entire system at once.
