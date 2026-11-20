# 4. How data moves

Each machine is a grid whose parts talk only to their neighbours. What travels between
neighbours, and how it finds its way, is where the three designs differ most visibly.

## Cerebras: wavelets on colored routes

The unit of communication is a **wavelet**: 32 bits of data plus a 5-bit tag, its
**color**. Each PE
has a router with five ports: north, south, east, west, and a ramp down to its own
processor. A link carries one wavelet per cycle.

A wavelet carries no destination address. Its color is its route. Before the program runs,
every router is told, for each color, which ports to listen on and which to send to. A
wavelet of color 3 arriving from the west goes wherever this router's entry for color 3
says. There are 24 colors a program can route [vendor, SDK 2.10.1], and the host-I/O library
takes four of them.

Routes can change during a run, but only in a planned way: a router holds a few switch
positions per color, and a special control wavelet advances it to the next position.

Hop cost is about one cycle [vendor, for WSE-2]. The SDK simulator charges two cycles per
hop on the WSE-3 target and one on WSE-2 when a wavelet passes straight through a router.
When each PE on the way takes the wavelet down into its processor, adds to it and sends it
on, a hop costs about nine cycles on WSE-3 and six on WSE-2 [measured, Cerebras course
chapters 4 and 12].

## Tenstorrent: packets with addresses

The unit is a **packet**: one header flit followed by up to 256 data flits, a flit being
what a link carries in one cycle: 32 bytes on Wormhole, 64 on Blackhole [vendor, ISA
documentation]. The header holds the destination's coordinates. A router reads it and
forwards the packet, so no route is set up in advance.

There are two networks, each a 2-D torus (a grid whose edges wrap around), and each is
one-way. On network 0 data flows only rightwards and downwards: a packet travels right as
far as it needs, turns at most once, then travels down. On network 1 data flows only
upwards and leftwards: up first, then left [vendor, ISA documentation]. The wrap-around is
what lets a one-way network reach every tile. Software picks a network per transaction;
the usual convention is network 0 for reading and network 1 for writing results out
[vendor, tt-metal's Metalium guide].

A core does not push raw words at its neighbour. It issues a transaction to its network
interface: "read 2 KiB from that address on that tile" or "write this buffer there". Reads
are request and response; writes can be acknowledged or posted. A write can be multicast to
a rectangle of cores in one transaction.

Hop cost is 9 cycles from one router to the next on Wormhole [vendor, ISA documentation],
and a Wormhole link carries 32 GB/s [vendor: 32 bytes per cycle at 1 GHz]. Routers forward
a packet's first flit before the last has arrived, so a long packet pays the hop latency
once, not per flit.

## Groq: streams that never stop

There are no messages. Each lane of the chip has 64 **streams**, 32 flowing east and 32
flowing west, each one byte wide [vendor]. Every cycle, every value on every stream moves
one register toward its edge of the chip. A value that reaches the edge is gone.

A unit that wants an operand samples the stream register in front of it on the cycle its
instruction fires. A unit that produces a result writes it onto a stream at its own
position, overwriting whatever was passing. Nothing is addressed, requested or
acknowledged. Whether the right value is in front of the right unit on the right cycle is
entirely the compiler's arithmetic: a result written at position *p* at cycle *t* is at
position *q* at cycle *t* + |*q* − *p*|.

## Side by side

| | Cerebras | Tenstorrent | Groq |
|---|---|---|---|
| Unit sent | 32-bit wavelet | Packet of up to 256 data flits | One byte per stream, 320 lanes tall |
| How it finds its way | Route per color, loaded before the run | Destination address in the header | It does not; it moves one hop per cycle |
| Set up when | Compile time | Each transaction, at run time | Compile time |
| Topology | 2-D mesh | Two one-way 2-D tori | Straight lines, east and west |
| Cost of a hop (a hop is PE to PE, router to router, and stream register to stream register: three different distances) | About 1 cycle [vendor, WSE-2]; 2 on WSE-3 and 1 on WSE-2 in the simulator [measured] | 9 cycles on Wormhole [vendor] | Exactly 1 cycle [vendor] |
| If the receiver is busy | Wavelets queue, then the sender stalls | Flow control holds the packet | Nothing waits; the value moves on past the unit |
| Limited resource | 24 colors | Link capacity and virtual channels | 32 streams each way |

## Why the difference

The three networks reflect what each machine sends and how far.

**Cerebras sends very many very small things between neighbours.** With 900,000 PEs, almost
all traffic is to a PE a few hops away. An address in every 32-bit wavelet would waste bits
and make every router decode it. Fixing the route per color keeps the whole wavelet for
data and each hop to about a cycle. The cost is that a program has only 24 colors, and
laying out routes so they do not collide is the programmer's main chore (Cerebras course,
chapters 4 and 12).

**Tenstorrent sends larger blocks, and often far.** A core fetches 2 KiB tiles from a DRAM
tile possibly a dozen hops away. One header on a 65-flit packet (a 2 KiB tile in 32-byte
flits on Wormhole) is cheap,
and addressing means any core can reach any other without planning. The cost is the
slower hop and contention: traffic shares links, and a careless layout congests them
(Tenstorrent course, chapter A08).

**Groq sends full-width vectors along one axis.** Its units are columns spanning the die,
so data only ever moves sideways between columns. A conveyor belt is the simplest thing
that does that, and its timing is known to the cycle with no flow control at all. The
cost is rigidity: 32 streams each way is all there is, and the compiler must find a
schedule in which no two values need the same stream register on the same cycle.
