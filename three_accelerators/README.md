# Three ways around the memory wall: Cerebras, Tenstorrent and the Groq LPU

Ten short chapters comparing three AI accelerators that all reject the GPU's design, and
reject it in three different ways. Each chapter says what is the same, what differs, and why
a team would choose that route.

The chapters draw on three longer courses, each checked twice against primary sources and
against a simulator:

| Machine | Course | Simulator used here |
|---|---|---|
| Cerebras Wafer-Scale Engine | [`ozzyozbourne/cerebrus`](https://github.com/ozzyozbourne/cerebrus), `course/` | Cerebras SDK 2.10.1 (`cslc`, `cs_python`), WSE-3 and WSE-2 targets |
| Tenstorrent Wormhole and Blackhole | [`ozzyozbourne/tenstorrents`](https://github.com/ozzyozbourne/tenstorrents) | [`ttsim`](https://github.com/tenstorrent/ttsim) v1.15.0 driven by tt-metal `7aad8aac` |
| Groq TSP / LPU | [`../sim_grok_1`](../sim_grok_1) | `sim_grok_1` itself, a Python model built from the ISCA 2020 and 2022 papers |

## Chapters

1. [The problem all three are solving](01-the-shared-problem.md)
2. [Three machines at a glance](02-at-a-glance.md)
3. [Where the data lives](03-where-data-lives.md)
4. [How data moves](04-how-data-moves.md)
5. [Who decides when things happen](05-who-decides-when.md)
6. [What the programmer writes](06-programming-models.md)
7. [One layer on three simulators](07-one-layer-three-simulators.md)
8. [Growing past one chip](08-scaling-out.md)
9. [Why three answers exist](09-why-three-answers.md)
10. [What was checked, and what was not](10-what-was-checked.md)

## Reading the numbers

Every number carries one of these labels, in brackets or in a table column:

- **vendor**: stated by the company in a paper, datasheet, slide deck or source file.
- **measured**: read off a simulator run made for these chapters or for the three courses.
  A simulator cycle count is not a hardware measurement; chapter 7 says what each one means.
- **derived**: arithmetic on the numbers beside it.
- **assumed**: chosen by the simulator's authors because no source gives it. This applies
  mainly to the Groq model, whose instruction latencies are not published.

## Running the experiments

The three scripts under [`experiments/`](experiments/) produce the outputs saved in
[`experiments/results/`](experiments/results/). They need the three simulators installed:

```bash
python3 three_accelerators/experiments/groq/dense_layer.py
```

```bash
SDK=/home/user/cerebras-sdk COURSE=/home/user/cerebrus/course bash three_accelerators/experiments/cerebras/run.sh
```

```bash
TT_COURSE=/home/user/tenstorrents bash three_accelerators/experiments/tenstorrent/run.sh
```

The Groq script needs only Python and NumPy. The Cerebras script needs the SDK and the
`cerebrus` course checkout. The Tenstorrent script needs a built tt-metal and ttsim, set up
as the Tenstorrent course's lab B00 describes.
