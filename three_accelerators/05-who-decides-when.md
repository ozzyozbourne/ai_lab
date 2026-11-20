# 5. Who decides when things happen

This is the deepest difference between the three machines. In two of them, an operation
runs when its data shows up. In the third, it runs at a cycle chosen before the program
started, whether or not the data is there.

## Cerebras: the data decides

A Cerebras PE runs **tasks**. A data task is bound to a color (or, on WSE-3, to an input
queue). When a wavelet of that color arrives, the task runs with the wavelet's 32 bits as
its argument. Other tasks are started by the program itself or by a control wavelet.

Nothing in the hardware knows in advance when a wavelet will arrive. If the PE is busy, the
wavelet waits in an input queue a few entries deep [vendor: 8, 4, 4, 4 on WSE-3]. If the
queue fills, the router upstream stops sending, and so on back to the source. Programs are
correct regardless of timing, as long as the tasks are written to tolerate any arrival
order the routes allow.

## Tenstorrent: the data decides, through buffers

A Tensix core runs up to five small programs at once, one per RISC-V processor: typically a
**reader** that fetches tiles, a **compute** kernel split across three processors that
unpack, calculate and pack, and a **writer** that sends results out.

They are connected by **circular buffers** in the core's L1 memory. The reader reserves
space, fills it and pushes; the compute kernel waits for a tile at the front, uses it and
pops. A stage with no input waits. A stage with no room for output waits. Inside the compute
kernel, hardware semaphores do the same job between the three processors. Between cores,
programs use semaphores over the network to say "your data has arrived".

So timing is again set at run time, by data and by back-pressure. The difference from
Cerebras is granularity: Cerebras reacts to each 32-bit wavelet, Tenstorrent to each
2 KiB tile.

## Groq: the compiler decides

A Groq chip has 144 instruction queues, one group per column of units [vendor]. Each queue
holds a list of instructions and `NOP n` delays. After one start-up synchronisation, which
takes 35 cycles [vendor], every queue simply counts cycles and issues its next instruction
when its count says so.

The matrix unit's "multiply now" fires at its cycle. If the compiler did its arithmetic
right, the operand vector that a memory slice put on a stream some cycles earlier is passing
at exactly that moment. No unit checks. There is no queue to wait in, no signal that says
"ready", no stall. The papers say the design removes "all reactive elements in the hardware
(e.g. arbiters, and caches)".

## An experiment on each simulator

The three scripts in [`experiments/`](experiments/) test this directly. Outputs are in
[`experiments/results/`](experiments/results/).

### Make one thing late

**Groq.** Compile a dense layer for the toy chip, then lengthen a single `Nop` in one
queue by one cycle, so that one instruction fires one cycle late. Do this for each of 14
queues in turn.

```
MXM_W0: Nop 11 -> 12: EmptyOperandError: MXM_W0: SR[W][0][0] is empty
MEM_W7: Nop 7 -> 8:   EmptyOperandError: MXM_W0: SR[W][0][0] is empty
VXM_A0: Nop 26 -> 27: EmptyOperandError: VXM_A0: SR[E][0][10] is empty
...
```

All 14 runs fail [measured]. The error is raised by the simulator, which tags every stream
register as empty or full so that it can catch a mistimed operand. Real hardware has no such
tag: it would compute with whatever byte happened to be passing. A one-cycle error
anywhere is a wrong answer.

**Tenstorrent.** Take the example that adds two tensors of 64 tiles, and replace the writer
kernel with one that idles for 300 simulator clocks before sending each tile (a patch from
the Tenstorrent course, lab B06).

```
stock writer: Test Passed clocks=[7959]
slow writer:  Test Passed clocks=[27702]
```

The result is still correct [measured]. The output buffer fills, the packer waits, the
calculation waits behind it, and the reader waits behind that. The run takes 3.5 times as
many clocks and nothing else changes.

**Cerebras.** Run the course's program 02 three times. The host streams 100 numbers into
one PE, and each arriving wavelet fires a task that updates running statistics. The host
injects wavelets whenever its own software gets to it, so arrival times differ between
runs.

```
run 1: tasks fired: 100  ... SUCCESS!   whole-run simulated cycles = 7023
run 2: tasks fired: 100  ... SUCCESS!   whole-run simulated cycles = 7021
run 3: tasks fired: 100  ... SUCCESS!   whole-run simulated cycles = 7048
```

Three different run lengths, one result [measured]. The Cerebras course shows the other
side of the same coin: remove the barrier that makes the host wait for the last task, and
the host reads half-finished statistics (course chapter 11). Event-driven code is immune to
lateness but not to the programmer forgetting that "sent" does not mean "processed".

### Run it twice

| Machine | Program | Run 1 | Run 2 |
|---|---|---|---|
| Groq sim | Dense layer, 12 inputs, 8 outputs | 68 cycles, trace digest `c4cc9c761af8` | 68 cycles, same digest |
| Groq sim | Same layer, different input values | 68 cycles | (digest differs only because the data does) |
| Cerebras sim | 100 × 100 matrix-vector product on one PE | 10,154 cycles | 10,154 cycles |
| ttsim | 640 × 640 matmul on one Tensix core | clock 330,591, hash `ef7abcd145720383` | same clock, same hash |

All three simulators repeat exactly [measured], but for different reasons, and only one of
them is a statement about hardware:

- The **Groq** count is the program. The compiler knew it was 68 before the simulator ran.
  It cannot depend on the data, because no instruction's timing depends on data.
- The **Cerebras** count is an on-device timer around a kernel with no outside input, so it
  repeats. Whole-run counts that include the host do not, as the three runs above show.
- The **ttsim** count is a count of simulator steps driven by the host program, not a model
  of time. The Tenstorrent course shows it change from 4,501 to about 5,000 to 6,600 when
  debug printing is switched on, because the host polls more often.

## What each choice buys

| | Decides timing | Gains | Gives up |
|---|---|---|---|
| Cerebras | Arrival of each wavelet | Programs tolerate any timing; sparse work costs nothing when no wavelet comes | Latency of a run is not known in advance; the programmer handles ordering |
| Tenstorrent | Arrival of each tile, with back-pressure | Stages can be written separately and run at different speeds; buffers hide the mismatch | Stall time when stages are unbalanced; synchronisation bugs between cores |
| Groq | The compiler | Latency known to the cycle before the run; no hardware spent on queues, arbiters or flow control | Everything must have a fixed shape and a fixed duration, and the compiler must solve the whole schedule |

The Groq papers' phrase for the result is that performance is "deterministic and precisely
predictable from run-to-run". The other two machines are deterministic in the weaker sense
that the same inputs give the same outputs; how long that takes depends on what else is
happening.
