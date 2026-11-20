# 6. What the programmer writes

The hardware differences in chapters 3 to 5 surface as three very different programming
jobs. This chapter shows a fragment of real code for each and says who does the work the
hardware no longer does.

## Cerebras: a program for one PE, and a layout

A Cerebras program is written in CSL, the company's own language. It has two parts. A
**layout** says which code runs on which PEs and how each color is routed through each
router. A **PE program** is what one processing element does.

This is the task from the Cerebras course's program 02. It runs once for every wavelet that
arrives:

```csl
// Runs once per wavelet; the 32-bit payload arrives as the argument.
task on_value(v: f32) void {
  stats[0] += v;
  stats[1] += v * v;
  if (v > stats[2]) stats[2] = v;
  if (v < stats[3]) stats[3] = v;
  count[0] += 1;
  // Last value processed: if the host is waiting in wait_done(), release it.
  if (count[0] == @as(u32, N) and host_waiting) sys_mod.unblock_cmd_stream();
}
```

The programmer thinks like someone writing for a very large number of microcontrollers:
which PE holds which data, which color carries which message, which task fires on which
arrival, and how all of it fits in 48 KB per PE. Array operations are written with
descriptors that tell the hardware to step through memory or through a stream of wavelets
without a loop. The compiler places code and checks routes; it does not decide the
algorithm's shape. For neural networks Cerebras's own software does this mapping, and
Cerebras offers the result as an inference service. CSL is offered through the SDK to
people who want to program the fabric directly, for example for scientific computing.

## Tenstorrent: kernels for the processors in each core

At the low level (TT-Metalium), a Tenstorrent program is a set of small C++ kernels plus a
host program that says which cores run them and how big the buffers between them are. This
is the middle of the compute kernel from the `eltwise_binary` example in tt-metal, which
adds two streams of tiles (the loop is complete; the file's own comments are replaced by
two short ones):

```cpp
for (uint32_t i = 0; i < n_tiles; i++) {
    cb_wait_front(cb_in0, 1);          // wait for a tile in each input buffer
    cb_wait_front(cb_in1, 1);
    tile_regs_acquire();
    add_tiles(cb_in0, cb_in1, 0, 0, dst_reg);
    tile_regs_commit();
    tile_regs_wait();
    cb_reserve_back(cb_out0, 1);       // wait for room in the output buffer
    pack_tile(dst_reg, cb_out0);
    cb_push_back(cb_out0, 1);
    cb_pop_front(cb_in0, 1);
    cb_pop_front(cb_in1, 1);
    tile_regs_release();
}
```

Every `wait` and `reserve` is a place where the kernel may pause for a neighbour. That one
source file is compiled three times, once for each of the three processors that unpack,
calculate and pack; each build keeps only the calls that belong to its processor. Kernels are compiled on the host when the program first runs and
cached.

Most users never write this. TT-NN is a Python library of ready-made operations, and
compilers above it take models from PyTorch and other frameworks. The low level is open,
though, and it is ordinary C++ on ordinary RISC-V processors, which is the point: a new
operation is a new kernel, not a hardware change.

## Groq: a model in, a timetable out

Groq programs are not meant to be written by hand; the 2020 paper shows assembly only as
examples. The input is a model with every shape fixed. The output is one list of
instructions per unit, padded with delays. This is the start of what the `sim_grok_1`
compiler emits for a dense layer (shortened: debugging tags are removed and one list is
abbreviated with `...`):

```
unit MXM_W0
  Sync
  Nop n=11
  Iw dtype="int8" entries=[0:W0,1:W1,...,7:W7]
  Nop n=1
  Abc dtype="int8" src=W0 out=E0 n_rows=8
unit MEM_W7
  Sync
  Nop n=7
  Read addr=0 out=W0
unit MEM_W6
  Sync
  Nop n=6
  Read addr=0 out=W1
```

Read it as a timetable. `Sync` is the start-up synchronisation. Memory slice `MEM_W7`, the
one nearest the matrix unit, then waits 7 cycles and puts a row of weights on westward
stream 0. `MEM_W6`, one position farther from the matrix unit, waits only 6 and uses stream
1, so its row has one more cycle to travel. All eight rows arrive in front of `MXM_W0` on
the same cycle, which is exactly when its `Iw` (install weights) fires after 11 cycles of
waiting. The delays are the program.

The compiler in `sim_grok_1` is this project's own; Groq has not published its algorithm.
The real compiler also splits a model across chips and schedules the links between them
(chapter 8).

## Side by side

| | Cerebras | Tenstorrent | Groq |
|---|---|---|---|
| Lowest level a user can write | CSL: tasks, colors, routes | C++ kernels for RISC-V and the matrix engine | A model for the compiler; no lower level is described for users in the sources used here |
| What a program is | Code per PE plus a route map | Kernels per core, buffers, a host program | One instruction queue per unit |
| Loops and branches at run time | Yes, in tasks | Yes, ordinary C++ | No branch in the published instruction set; only fixed repeats |
| Shapes | Fixed when compiled; sizes are compile-time parameters | Chosen at run time by the host program | Fixed when compiled; dynamic sizes become padding and masks |
| When code is compiled | Before the run, by `cslc` | On first use, on the host, then cached | Before the run; an independent evaluation of a 72-chip rack reports builds of over 4,500 seconds |
| Who places data | The programmer, per PE | The programmer or TT-NN, per tensor: L1 or DRAM, which cores | The compiler |
| Who avoids collisions | The programmer assigns colors | Flow control, at run time | The compiler reserves every stream register per cycle |
| Typical bug (from the courses' labs; for Groq, from the design) | Two messages on one color; a task that fires before its data is complete | A core waiting for a signal that was sent too early or never | No timing bug can appear at run time unless the compiler is wrong; the compiler either finds a schedule or fails |
| Usual way in | Cerebras's own model software or inference service; CSL through the SDK | TT-NN or a model compiler | A model handed to Groq's compiler; Groq's cloud service, or NVIDIA's LPX racks |

Sources: Cerebras course chapters 5, 6, 10 and 11; Tenstorrent course chapters A10 to A13
and A18; Groq dossier sections 1, 3 and 4.

## The pattern

Work removed from hardware does not disappear. It moves:

- On Cerebras it moves mostly to **the person or tool laying out the program**. The hardware
  is simple and fast; fitting an algorithm onto 48 KB cells and 24 colors is the craft.
- On Tenstorrent it moves to **run-time software**: kernels, buffers, and a dispatcher on
  the host or on cores set aside for it. That costs some speed and buys generality, and it
  is open source.
- On Groq it moves to **the compiler**, almost entirely. That buys exact timing and costs
  flexibility: what the compiler cannot fix in advance has to be recast as a fixed shape
  with padding and masks.

This pattern is our summary of the three courses, not a statement by any of the vendors.
