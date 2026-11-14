# 03 — Recent (2023–2026) material on the Groq LPU

Research date: 2026-11-14. Scope: NVIDIA "Inside NVIDIA Groq 3 LPX" blog, the Hot Chips 2026 LPU talk, independent evaluations, and Groq's own recent descriptions. Every claim below names the source it came from. Labels used:

- **[VENDOR]**: Groq or NVIDIA material (marketing or technical marketing).
- **[PRESS]**: journalist or analyst reporting, often repeating vendor slides.
- **[INDEP]**: independent measurement or academic evaluation.
- **[INFER]**: my own inference. It is not a sourced claim.

"Fetched" means I downloaded the page or PDF in this session and read the text. "Snippet only" means I saw only a search-engine summary and did not read the page.

---

## 1. Sources consulted (with reachability)

| # | Source | Status |
|---|---|---|
| S1 | NVIDIA Technical Blog, K. Aubrey & F. Ghodsian, "Inside NVIDIA Groq 3 LPX: The Low-Latency Inference Accelerator for the NVIDIA Vera Rubin Platform", **Mar 16, 2026**. https://developer.nvidia.com/blog/inside-nvidia-groq-3-lpx-the-low-latency-inference-accelerator-for-the-nvidia-vera-rubin-platform/ | **Fetched, full text read** (curl + HTML→text) |
| S2 | NVIDIA Technical Blog, S. Weidman, K. Devleker, A. Ling, "How NVIDIA Groq 3 LPX Unlocks Ultrafast Interactivity at Long Context on NVIDIA Vera Rubin", **Aug 24, 2026**. https://developer.nvidia.com/blog/how-nvidia-groq-3-lpx-unlocks-ultrafast-interactivity-at-long-context-on-nvidia-vera-rubin/ | **Fetched, full text read** |
| S3 | NVIDIA product page "NVIDIA Groq 3 LPX". https://www.nvidia.com/en-us/data-center/lpx/ | Fetched |
| S4 | Hot Chips 2026 conference program. https://hc2026.hotchips.org/program/conference/ | **Fetched.** The program lists the talk. The slide PDF link (`/assets/program/conference/day2/NV_HC2026_LP30_Final.pdf`) returned **HTTP 401 Unauthorized**, and so did another day-2 PDF (Cerebras) I tried as a control. The slides appear to be access-restricted, so **I could not read them.** |
| S5 | ServeTheHome (live blog, author shown as Ryan Smith), "NVIDIA's Groq 3 LPU Accelerators for Heterogeneous AI Compute at Hot Chips 2026", Aug 25, 2026. https://www.servethehome.com/nvidias-groq-3-lpu-accelerators-for-heterogeneous-ai-compute-at-hot-chips-2026/ | Fetched (text; I did not view the slide images) |
| S6 | Tom's Hardware, Luke James, "Hot Chips 2026: Nvidia presents Groq 3 LPX architecture and unveils its first third-party inference benchmark", published 2026-08-26. https://www.tomshardware.com/tech-industry/semiconductors/nvidia-presents-groq-3-lpx-architecture-and-unveils-its-first-third-party-inference-benchmark | Fetched |
| S7 | Tom's Hardware, Luke James, "How Nvidia's $20 billion Groq 3 LPU deal reshapes the Nvidia Vera Rubin Platform — Samsung 4nm process…", published 2026-03-19. https://www.tomshardware.com/tech-industry/semiconductors/nvidias-20-billion-groq-deal-produces-its-first-chip | Fetched |
| S8 | The Register, "Nvidia slaps $20B Groq tech into massive new LPX racks…", 2026-03-16. https://www.theregister.com/2026/03/16/nvidia_lpx_groq_3/ | Fetched |
| S9 | The Decoder, "Nvidia says its Groq 3 LPX is four times faster than Cerebras, but the math is more complicated", 2026-08-25. https://the-decoder.com/nvidia-says-its-groq-3-lpx-is-four-times-faster-than-cerebras-but-the-math-is-more-complicated/ | Fetched |
| S10 | StorageReview, "NVIDIA Groq 3 LPX: Everything We Know", 2026-03-19. https://www.storagereview.com/news/nvidia-groq-3-lpx-everything-we-know | Fetched (secondary source; contains at least one internal inconsistency, see §2.1) |
| S11 | A. Golden, C.-J. Wu, G.-Y. Wei, D. Brooks, "The xPU-athalon: Quantifying the Competition of AI Acceleration", arXiv:2604.10852, Apr 12, 2026. https://arxiv.org/abs/2604.10852 | **PDF fetched, Groq sections read** |
| S12 | S. Shanmugavelu et al., "Impacts of floating-point non-associativity on reproducibility for HPC and deep learning applications", arXiv:2408.05148 v3 (Oct 30, 2024). https://arxiv.org/abs/2408.05148 | PDF fetched, Groq sections read. **The first author is affiliated with "Maxeler Technologies, a Groq Company" and the experiments ran in "Groq ZankerLab", so this is not independent of Groq.** |
| S13 | Groq, "What is a Language Processing Unit?" https://groq.com/architecture (Groq's blog index dates this post Mar 7, 2025) | Fetched |
| S14 | Groq GroqFlow user guide (GitHub, `main` branch, accessed 2026-11-14). https://raw.githubusercontent.com/groq/groqflow/main/docs/user_guide.md | Fetched |
| S15 | SemiAnalysis, D. Patel & D. Nishball, "Groq Inference Tokenomics: Speed, But At What Cost?", 2024-02-21. https://newsletter.semianalysis.com/p/groq-inference-tokenomics-speed-but | **Free portion only fetched** (paywalled after the opening sections) |
| S16 | The Next Platform, Timothy Prickett Morgan, "Groq Says It Can Deploy 1 Million AI Inference Chips In Two Years", 2023-11-27. https://www.nextplatform.com/2023/11/27/groq-says-it-can-deploy-1-million-ai-inference-chips-in-two-years/ | Fetched |
| S17 | DeepLearning.AI *The Batch*, "Groq Elevates AI Processing Speeds with Advanced Chips", 2024-02-28. https://www.deeplearning.ai/the-batch/groq-elevates-ai-processing-speeds-with-advanced-chips | Fetched |
| S18 | arXiv abstracts only (not full text): TauLang arXiv:2611.06079 (2026-11-04); FastAFD arXiv:2611.07149 (2026-11-04) | Abstracts fetched via the arXiv API |
| — | Groq blog, A. Ling, "Inside the LPU: Deconstructing Groq's Speed" (Aug 2025, per search snippet and S11 ref [22]). https://groq.com/blog/inside-the-lpu-deconstructing-groq-speed | **Not readable.** The URL now returns a generic Groq site shell with no article body. Wayback Machine copies failed: web.archive.org connections were reset through the session proxy, and WebFetch refuses that domain. |
| — | Groq blog "From Speed to Scale: How Groq Is Optimized for MoE & Other Large Models" (May 27, 2025) | Fetched, but marketing-only text with no numbers. Not used. |
| — | Groq "What Is A LPU" PDF (`groq.com/wp-content/uploads/2024/07/GroqThoughts_WhatIsALPU-vF.pdf`) | HTTP 404 |
| — | EE Times "Groq Demos Fast LLMs on 4-Year-Old Silicon" | Connection failed (HTTP/2 stream error). Not read. |
| — | Artificial Analysis primary pages | Not fetched directly. AA numbers below come from NVIDIA (S2) and press (S6, S9, S17). |
| — | NVIDIA newsroom press release "NVIDIA Groq 3 LPX Now in Full Production…" (Aug 2026) | Downloaded but not analysed. Its benchmark content duplicates S2. |
| — | Chips and Cheese, EE Times, Argonne ALCF Groq LLM evaluation papers | Not found or not read. See §5. |

---

## 2. Findings by topic

### 2.1 NVIDIA Groq 3 LPU / LP30 chip: what is stated [VENDOR unless marked]

**Generation and naming.** NVIDIA calls the chip the "NVIDIA Groq 3 LPU", and the tray table names it "LP30" (S1, Table 2: "LP30 chips | 16"). S1 also calls it "the seventh chip of the Vera Rubin Platform". S3 says: "The NVIDIA Groq 3 LPU is the next generation of Groq's innovative language processing unit."

**Process node.** S1 and S3 do **not** state a process node. Tom's Hardware (S7, [PRESS]) says it is "manufactured by Samsung on a 4nm process". This matches Groq's own earlier roadmap statements: S13 says "Our current chip set is built on a 14 nanometer process. As we move towards a 4 nanometer process…", and S16 reports "Groq's next-generation GroqChip, due in 2025, etched in Samsung's 4 nanometer processes". I found no NVIDIA primary source that confirms 4 nm. → For the ledger: *4 nm Samsung = press-sourced, not vendor-confirmed.*

**On-chip SRAM per chip.**
- S1: "500 MB of high-speed on-chip SRAM serves as the primary working storage for inference." S3: "Each LPU accelerator delivers 500 megabytes (MB) of SRAM".
- Discrepancy: S7 (Tom's, Mar 2026) says "512 MB of on-chip SRAM per die". NVIDIA's own pages say 500 MB, and 256 × 500 MB = 128 GB matches S1's rack figure.
- Prior generation (GroqChip v1): S15 says "each chip only has 230MB of SRAM". S11 Table III lists Groq capacity as 0.23 GB at 8.0×10^13 B/s.

**SRAM bandwidth per chip.** S1: "150 TB/s of on-chip memory bandwidth" per LPU. A tray of 16 has 2.4 PB/s, and a rack has 40 PB/s. Groq's earlier gen-1 claim (S13): "upwards of 80 terabytes/second".

**Unit of work: 320-byte vectors.** S1: "Compute and communication in the LPU are organized around 320-byte vectors as the unit of work. Arithmetic operations, memory access, and inter-device transfers all operate on these fixed-size vectors, simplifying scheduling and synchronization." S2 adds: "the compiler schedules workloads on its compute and communication units at the level of 320-byte vectors". StorageReview (S10, secondary) describes it as "a 320-element vector consisting of 320 bytes at INT8, 640 bytes at FP16". I did not confirm that wording in an NVIDIA or Groq primary source.

**Functional units** (S1). These keep the TSP naming:
- "Matrix execution modules (MXM) provide dense multiply-accumulate capability for tensor operations, operating on fixed data types with predictable throughput."
- "Vector execution modules (VXM) handle pointwise arithmetic, type conversions, and activation functions using a mesh of arithmetic logic units (ALUs) per lane."
- "Switch execution modules (SXM) perform structured data movement, including permutation, rotation, distribution, and transposition of vectors."
- "MEM block — a flat, SRAM-first memory architecture … Rather than relying on hardware-managed caches, the compiler and runtime place the active working set, including weights, activations, and KV state, into on-chip memory and move data explicitly."

S1 gives no counts of MXM/VXM/SXM/MEM slices, lanes, superlanes, stream registers, or clock frequency. S10 (secondary) repeats the ISCA-2020 layout: instructions flow from top and bottom toward the middle, data streams flow east–west, and "Data moves at exactly one hop per clock cycle". It gives no numbers specific to LP30.

**Compute and precision.**
- Rack: 315 PFLOPS (S1 Table 1; S5 and S6 say FP8). Tray: "AI inference compute (FP8) 19.2 PFLOPS" (S1 Table 2). That works out to 1.2 PFLOPS FP8 per chip [INFER: 19.2/16].
- S8 (The Register): "Each Groq 3 LPU is capable of 1.2 petaFLOPS of FP8". S7: "1.23 FP8 PFLOPS".
- FP4 is not mentioned in S1. S7 ([PRESS]): "a future LP35 will add NVFP4 support, aligning with the Rubin Ultra generation."
- S10 has an internal inconsistency: it says "Each of the 8 Groq 3 LP30 chips … totalling 9.6 PFLOPS of FP8 compute per LPX tray", which contradicts NVIDIA's 16 chips and 19.2 PFLOPS per tray.
- Prior gen (S11 Table III, citing SemiAnalysis): Groq "188" TFLOPS for prefill compute. S11 does not state the precision in that table.

**Numerics (TruePoint).** S10 only (secondary): "TruePoint technology, where the architecture's guaranteed order of operations enables FP32-level accuracy from FP16 inputs via a 320-element fused dot product with a single rounding step." I could not open a Groq primary TruePoint document. S2 says that for the AA benchmark, "Testing by Artificial Analysis and NVIDIA confirmed that the NVIDIA configuration for both of these benchmarks had no loss of precision or model quality in its outputs." S2 does not say which precision was used.

**Chip-to-chip (C2C).**
- S1: "Each LPU connects through 96 C2C links running at 112 Gbps each, enabling a streamlined LPX scale-up topology with high aggregate I/O bi-directional bandwidth of 2.5 TB/s and predictable communication timing." The rack figure is 640 TB/s. [INFER: 96 × 112 Gb/s = 10.75 Tb/s ≈ 1.34 TB/s per direction. That is consistent with "2.5 TB/s bidirectional" after encoding overhead.]
- S6 (from the Hot Chips talk): "350 ns of chip-to-chip latency", in a rack that "scales past 1,000 LPUs".
- S5 (Hot Chips live): "each chip acts as both a processor and a router … the compiler schedules all resources, both processing and networking". Also: "there is no hardware flow control or virtual channels here."
- S2: "The links are point-to-point between pairs of LPUs and each LPU can act as a router as well as a processor, meaning that if needed, data can be routed to LPUs by way of other LPUs."

**Clocking and synchronisation.** S1: "the compiler relies on plesiosynchronous, chip-to-chip protocol in hardware that cancels natural clock drift and aligns hundreds of LPU accelerators to act as a single coordinated system. With predictable data arrival and periodic software synchronization, developers can reason more directly about timing". S6: chips are synchronised "to a single virtual clock". S6 adds that the fabric needs "no adaptive routing or congestion sensing".

**Static scheduling and determinism.**
- S1: "the compiler explicitly schedules computation, data movement, and synchronization. Instead of relying on dynamic hardware schedulers at runtime…"
- S2: the compiler "can use this information to produce a schedule, down-to-the-clock cycle of exactly how the workload will run before it begins". It also says this "eliminates the need for real-time arbitration of transfers because it can plan when each piece of data will move over each C2C link".
- S5: "This is a fully deterministic chip. There is no branching or other sources of non-determinism." and "Because the chip is deterministic, the instruction scheduling is handled in software as well."
- S6: the design "drops caches, branch prediction, and out-of-order execution in favor of a fully deterministic pipeline that the compiler schedules at clock-cycle granularity."

**Fine-grained compute/communication overlap** (S2). "the compiler can schedule individual LPUs to compute 320 columns of an output matrix and send them over the C2C links immediately after they are computed", and it begins "the transfer of data as soon as enough of the result to fill a 320-byte vector is ready, instead of waiting for an entire matrix operation to complete."

**Uses of determinism beyond latency** (Hot Chips, via S5 and S6).
- The compiler predicts power cycle by cycle, which allows look-ahead current ordering. This cut "voltage droop by more than 60% and overshoot by more than 70%" (S6). S5 gives the droop figure as 60%.
- Thermal-aware placement gives "about 10 to 11% more performance under the same thermal limit" (S6, quoting Arsovski).

**Fault handling** (S6). On a chip failing mid-workload, Arsovski said users "would just checkpoint it or reconfigure the hardware." No hardware fault tolerance was described.

### 2.2 LPX system and pairing with GPUs [VENDOR]

- **Rack (S1 Table 1):** 315 PFLOPS, 128 GB SRAM, 40 PB/s, 256 chips, 640 TB/s scale-up. 16 liquid-cooled 2U trays in NVIDIA MGX ETL racks.
- **Tray (S1 Table 2):** 16 LP30, 8 GB SRAM, 2.4 PB/s, "DRAM via fabric expansion logic Up to 512 GB", "DRAM via host CPU Up to 256 GB", 19.2 PFLOPS FP8, 40 TB/s scale-up. S3 says each rack has "12 TB of DDR5 memory for large models and workloads".
  - The NVIDIA sources I read do **not** explain how the LPU uses the DRAM, for example whether it holds weights or KV-cache spill. [INFER: 16 × (512+256) GB = 12 TB, consistent with S3.]
- **Sync/async boundary** (S5, S6): "The LPUs are in a synchronous domain, but talking to the GPUs or going to an external KV cache is an async operation. So NVIDIA employs a FPGA to function as an async bridge between the two worlds" (S5). S5 also reports a slide titled "Static Scheduling" about "static scheduling of dynamic workloads".
- **Work split** (S1, S2, S6). Three modes are described:
  1. **Prefill–decode disaggregation:** "Vera Rubin NVL72 handles prefill and hands off the KV cache once per turn. Groq 3 LPX uses this KV cache, along with weights held in SRAM, to perform the entire decode step" (S2).
  2. **Attention–FFN disaggregation (AFD):** "Vera Rubin NVL72 computes attention and holds the KV cache in DRAM, while Groq 3 LPX executes the FFN layers. Only intermediate tokens are sent between racks, once per full-attention layer" (S2). S1: GPUs run "full-context attention over the accumulated KV cache", and LPX runs "sparse MoE expert feed-forward networks (FFNs) and other pointwise operations".
  3. **External-drafter speculative decoding:** "Groq 3 LPX runs a small draft model ahead of the large target model on Vera Rubin NVL72 … only draft tokens cross the link" (S2).
- **Micro-batching** (S5): "NVIDIA uses micro-batches of workloads that are executed concurrently on the GPUs and LPUs."
- **Software:** NVIDIA Dynamo orchestrates the work (S1).
  - CUDA: at GTC in March 2026, Ian Buck said "There are no changes to CUDA at this time. We are leveraging the LPU as an accelerator to the CUDA that's running on the Vera NVL 72 platform" (S8).
  - By Hot Chips in August 2026, S5 reports "NVIDIA has adding LPU support to CUDA ecosystem", and S6 mentions "an LPU extension to CUDA".
  - I found no public detail of the LPU compiler toolchain in the 2026 NVIDIA material.

### 2.3 Hot Chips 2026 talk

- **Program entry (S4, fetched):** Conference Day 2, Tuesday August 25, 2026, "Session: AI 1" (2:15–4:15 PM). Title "Think Fast: LPU Accelerator for Heterogeneous Compute", presenters "Igor Arsovski & Santosh Raghavan, NVIDIA". The slide PDF exists at `NV_HC2026_LP30_Final.pdf` but returned HTTP 401.
- **What I know of the content comes from press:** S5 (live blog with slide-image captions) and S6. Highlights are in §2.1–2.2. S6 notes the title reuses the ISCA 2020 TSP paper title "Think Fast".
- **Not available to me:** the slides themselves, any video, any abstract text beyond the title.

### 2.4 Throughput benchmarks

| Claim | Who measured | Conditions | Source |
|---|---|---|---|
| **3,431** output tok/s median, Gemma 4 31B (dense), 100K input context | Artificial Analysis (third party), on an NVIDIA-hosted system | S6: "a private, pre-release Gemma 4 31B endpoint served through Google Cloud, taking the median of 50 sequential client requests at a concurrency of one" | S2 (vendor-reported AA result), S6 |
| **3,382** tok/s median, same model, 10K context | Artificial Analysis | as above | S2 |
| 4,767 tok/s median, P80 5,520, SPEED-Bench coding, Gemma 4 | NVIDIA | — | S2 |
| 10,996 tok/s (S6) / "11,000 tokens per second" (S5), Gemma 4 31B, one rack | NVIDIA on-stage demo, flagged by the presenter as "self-reported" | — | S5, S6 |
| ~4× next-fastest public endpoint (870 tok/s per S6; Cerebras at 882 tok/s per S9) | AA numbers chosen and framed by NVIDIA | Competitors measured on shared production serverless endpoints | S6, S9 |
| "up to 35x higher inference throughput per megawatt" vs GB200 NVL72 at 400 TPS/user, 2T-param MoE, 400K context | NVIDIA projection | No methodology given | S1 |

**Independent caveats on these benchmarks** [PRESS]:
- S6: "Serving one request at a time produces the highest per-user token rate the hardware can post, and it's not directly comparable to the multi-tenant conditions the other endpoints run under."
- S6: "Gemma 4 31B is also a dense model small enough to sit inside a single LPX rack, and the picture at trillion-parameter mixture-of-experts scale, where memory capacity becomes the main constraint, went unaddressed."
- S9: "its architecture needs at least 64 chips to reach that result, while Cerebras gets by with one or two accelerators."

**Historical benchmarks (GroqChip v1, 14 nm):**
- S17 (Feb 2024) [PRESS citing AA]: AA "clocked the median speed of Groq's instances of Llama 2 70B at 241 tokens per second, while Azure's was around 18". Groq advertised 300 tok/s for Llama 2 70B with a 4,096-token context, 750 tok/s for Llama 7B (2,048 context), and 480 tok/s for Mixtral 8x7B (32K context).
- S16 (Nov 2023) [VENDOR claims reported by press]: Llama 2 70B on 576 GroqChips, "512 token inputs and 1,024 token outputs at INT8 processing", "above 300 tokens per second".

### 2.5 Model size vs SRAM: chips per model

- **Gen 1:**
  - S15: "Because each chip only has 230MB of SRAM, no useful models can actually fit on a single chip. … In the case of the Mixtral model, Groq had to connect 8 racks of 9 servers each with 8 chips per server. That's a total of 576 chips".
  - S16: Llama 2 70B used 576 chips ("574 of these linked in three switched pods across those eight racks"; there is a minor internal inconsistency between "nine nodes" and 574/576). Each node had 8 GroqCards. A pod scaled to 264 chips over optical interconnect, and "4,128 GroqChips on a single fabric" was promised for the next generation.
  - S16 [INFER by the TNP author]: the same Llama 2 70B work "might only take around 100 chips in two racks in 2025" on 4 nm.
- **Gen 3 (LP30):**
  - S6: a Rubin GPU's 288 GB of HBM4 is "roughly 576 times the memory of a single LP30, so a 31-billion-parameter model at FP8 needs on the order of 62 LPUs to hold its weights, and a large mixture-of-experts model runs into four figures of chips across several racks." [INFER: 31 GB / 0.5 GB = 62, weights only, with no KV or activations.]
  - S8: "At 4-bit precision you'd need at least 512 GB of memory or about a thousand LPUs to hold a 1 trillion-parameter model in memory."
  - S9: "DeepSeek V3, for one, would need 1,342 accelerators, or a little over five racks."
  - S8 quotes NVIDIA's Ian Buck: "The trade off, of course, is that you need many chips in order to perform that kind of performance … The tokens per second per chip, is actually quite low."
  - S1 [VENDOR]: "Because on-chip SRAM capacity is finite, larger models are scaled across many interconnected LPU accelerators using parallel execution strategies such as layer-wise partitioning".

### 2.6 Batch size

- **Vendor framing:** NVIDIA positions the LPU for small-batch decode. S1: "In interactive decode, many operations run at very small batch sizes". It says determinism keeps latency stable "even at small batch sizes". It also advises: "Keep throughput-first workloads on Rubin GPUs, such as batch serving … where high concurrency and batching keep GPUs consistently busy". S2: "the highest levels of interactivity require very small batch sizes, where the fixed coordination cost can outweigh the time saved from TP."
- **Hot Chips trade-off (S5):** "the trade-off is that total throughput efficiency is dropping the more the LPUs are used; GPUs are still the king of efficiency when total throughput is all that matters".
- **Gen 1 (S15, Feb 2024):** Groq ran "their current pipeline parallelism and with batch size 3, which we we hear they will implement in production next week". S15 also says, of serving many users at very high batch sizes (the throughput- and cost-optimised regime), "GPUs are king".
- **Independent (S11):** "even simple batch size scaling is not supported with our physical CS-3 and Groq setup." S11 Key Takeaway 2 says the optimal platform "var[ies] with batch size, sequence length, and model scale".

### 2.7 Static shapes / fixed sequence length / compile flow

- **GroqFlow (S14) [VENDOR docs]:**
  - On the `inputs` argument: "Used by `groqit()` to determine the shape of input to build against. Dictates the maximum input size the model will support." Hint: "At runtime, pad your inference inputs to this expected input size." Under inference: "Pad your inputs to the same shape used when creating the model".
  - By default the model is converted to ONNX and its "trained parameters into type float16". Optional post-training int8 quantisation is available, and "rebuild is required when different quantization samples are provided".
  - `--effort=standard|high` trades "program cycle count" against compile time.
  - Build output includes `num_chips_used`. "By default, GroqFlow will automatically partition models across multiple GroqChip™ processors".
  - Power analysis assumes a "default … 900MHz" frequency (gen-1 GroqChip).
  - On determinism: "compute performance on Groq systems is completely deterministic. All performance variance comes from I/O between the host system and GroqChip processors."
- **Compile/build time (S11, independent):**
  - "We observe build times for Groq can be upwards of 4500 seconds, and scale linearly with the number of chips."
  - Fig. 11: "Groq sees largest build times, followed by Cerebras and SambaNova. Groq also requires highest build frequency." Compilation and assembly take "40% and 59% of total build time".
  - Across all novel accelerators: "compilation times can reach 5000× higher for novel accelerators as compared to GPUs."
  - S11 used GroqFlow 4.3.1 on one GroqRack (72 GroqChips).
- **Operator coverage (S11):**
  - "the set of PyTorch operators supported is quite limited, supporting only a few hundred. Groq notably lacks support for several key operators when running on their physical hardware platform, including torch.mm and the standard PyTorch attention operation (i.e., Scaled Dot Product Attention). Furthermore, code wrappers are needed to export code and convert to onnx before it can be run on the hardware."
  - Elsewhere S11 reports mm microbenchmark results on Groq, so the torch.mm statement may refer to a specific op path. I did not resolve this.
- **Deployment effort (S11):** "despite advertised LLaMA support, deploying a LLaMA model on nine Groq racks required approximately 1.5 years of coordination and repeated compiler issues, and ultimately only hand-compiled models from Groq engineers were executable; variants could not be run."
- **2026 LP30 compiler:** I found no public information on compile times, dynamic-shape support, or sequence-length handling. S5 mentions "static scheduling of dynamic workloads" only as a slide title.

### 2.8 Other independent measurements (S11, GroqRack gen 1)

- Roofline: "Groq sees roughly 10× lower peak throughput than H100s, yet is less memory bandwidth bound due to its on-chip SRAM."
- Area: "Groq has poorest area efficiency, with 10.43× the amount of area used to get equivalent FLOPS to CS-3."
- Scale-out: "Groq achieves pareto optimality on decode under zero-communication assumptions, yet loses that position when scale-out communication costs are incorporated. This highlights the drawback of Groq's highly disaggregated architecture when serving large models."
- Llama-3.1-8B low batch (Groq measured via API): latency per token at "30.03%" of H100.
- Primitives: Groq "1.64x faster than H100 for sin operations, 14.42× faster for matrix multiply (mm), and 300.16× faster for rsqrt". Key Takeaway 5: "Groq's latency advantage emerges primarily at small scales".
- Power: "Groq is the most power-hungry platform, drawing up to 35× more power than others on rqsrt, 51.44× more on sin, and 18.61× more on matrix multiply."
- Communication energy: CS-3 uses "2.74× less energy per byte than Groq" at 161 mm.
- Software: across "13 different package versions" over six months, "no statistically significant change in performance".

### 2.9 Determinism and reproducibility (S12, Groq-affiliated authors)

- S12: GraphSAGE inference took "0.066" ms on Groq versus "3.92(0.2)" ms deterministic and "2.17(0.1)" ms non-deterministic on H100. Inference on the LPU "is 30 times faster than the fastest PyTorch implementation".
- S12: "On the LPU architecture, inter-chip communication can be software scheduled, removing such communication variations".
- Setup: "GroqWare SDK 0.11". "A GroqNode has 8 Groq LPUs connected with a fully connected 88 RealScale™ chip-to-chip connectors".

### 2.10 Groq's own recent descriptions (S13) [VENDOR]

- Software-first: "We didn't touch chip design until the compiler's architecture was designed."
- Compiler output: "As the compiler maps and schedules a program to run across one or multiple LPUs, it optimizes performance and utilization. The result is a program encompassing all data movement information throughout execution."
- Assembly line: "data 'conveyor belts' which move instructions and data between the chip's SIMD (single instruction/multiple data) function units … This process is all software-controlled; no synchronization is required within the hardware."
- Determinism: "every execution step is completely predictable to the smallest execution period (also known as clock cycle)". It is achieved "by eliminating contention for critical resources, namely data bandwidth and compute". "Data flow is statically scheduled by the software during compilation, and executes the same way every time the program runs."
- Chip-to-chip: "There is no need for routers or controllers for inter-chip connectivity". This is worded differently from the 2026 NVIDIA statement that each chip "acts as both a processor and a router" (S5, S2). [INFER: the 2026 wording likely refers to software-scheduled forwarding through intermediate chips, not hardware routing logic. Unverified.]
- Kernel-less framing: "To maximize hardware utilization on GPUs, every new AI model requires coding of model-specific kernels". The LPU instead uses "a generic, model-independent compiler".
- Memory bandwidth and node: on-chip SRAM "upwards of 80 terabytes/second" versus "about eight terabytes/second" for GPU HBM. "Our current chip set is built on a 14 nanometer process."

### 2.11 Corporate context [PRESS]

- S6 and S7 describe the Groq–NVIDIA deal (December 2025, ~$20B) as "a non-exclusive IP license plus the hiring of Ross, president Sunny Madra, and most of Groq's engineers" (S6).
- S7 reports Samsung production ramping "from roughly 9,000 wafers to about 15,000 wafers".
- These items are not relevant to simulator parameters. They are listed only to date the material.

---

## 3. Implications for an educational simulator

Each recommendation is tied to a source. Where a parameter is gen-1 versus gen-3, I say which.

1. **Static input shapes; pad to a compiled maximum.**
   - Source: GroqFlow S14 says inputs "Dictates the maximum input size the model will support" and "pad your inference inputs to this expected input size".
   - The toy compiler should take fixed tensor shapes at compile time and reject or pad other shapes at runtime. Recompiling for a new shape is the only way to change it.
   - Also model "rebuild required" when quantisation parameters change (S14).
2. **Compile-time vs runtime split; compile cost is real.**
   - Source: S11 reports build times "upwards of 4500 seconds" that "scale linearly with the number of chips", and S14 has the `--effort` flag.
   - The simulator can report a nominal compile-cost metric, for example scheduler work units, and offer an effort knob that trades schedule length against compile time.
   - Any absolute compile time would be ASSUMED.
3. **No runtime arbitration: every op, memory access, and C2C transfer gets a fixed issue cycle from the compiler.**
   - Sources: S1, S2 ("schedule, down-to-the-clock cycle"), S5 ("no hardware flow control or virtual channels"), S13.
   - The simulator should *check* the schedule for conflicts rather than resolve them, so a conflict is a compile error, not a stall. This matches the TauLang framing (S18 abstract): "when an operation runs is a condition for correctness."
4. **Fixed-width vector as the unit of everything.**
   - Source: S1 says "320-byte vectors" are used for arithmetic, memory, and C2C.
   - Make the vector width a parameter, default 320 bytes (SOURCED for LP30 from S1). Element count per precision is only secondary-sourced (S10).
5. **Determinism: identical input means identical cycle count. Variable latency appears only at async boundaries.**
   - Sources: S14 says variance only "from I/O between the host system and GroqChip processors". S5 and S6 describe the FPGA async bridge to GPUs and external KV.
   - The simulator can show data-independent timing and treat host I/O as the only non-deterministic component.
6. **Capacity-bound partitioning: chips per model = weights ÷ per-chip SRAM, plus KV and activations.**
   - Sources: S1 (500 MB per chip, "layer-wise partitioning"), S6 (~62 LP30 for a 31B FP8 model), S15 (230 MB per chip on gen 1, 576 chips for Mixtral).
   - The toy compiler should refuse models that exceed aggregate SRAM and choose a chip count, or ask for one. Nothing spills to DRAM by default. Tray DRAM exists on LP30 (S1) but its use is undocumented, so any spill model is ASSUMED.
7. **Batch size: optimise for batch 1 to small batches; expose the throughput trade-off.**
   - Sources: S1 and S2 (small-batch design target), S5 (GPU efficiency wins at high throughput), S15 (gen-1 production batch size 3), S11 (batch scaling not supported on their setup).
   - The simulator should treat batch as a compile-time constant that is part of the static shape. Larger batches mean a recompile and more SRAM for activations and KV.
8. **Multi-chip pipeline and tensor parallelism with compiler-scheduled C2C.**
   - Sources: S2 (TP at small batch is dominated by "first bit latency"; streaming 320-byte partial results lets communication overlap compute), S6 (350 ns C2C latency), S1 (96 × 112 Gbps links).
   - A simple link model with fixed latency plus bytes/bandwidth is justified by S2's own equation framing (Fig. 2: time = first-bit latency + N/B).
9. **Communication cost changes rankings.**
   - Source: S11 found Groq loses Pareto optimality "when scale-out communication costs are incorporated".
   - Educational point: show how chip count and C2C cost erode the single-chip advantage.
10. **Operator coverage is limited.** S11 reports a few hundred PyTorch ops and no fused SDPA on gen 1. A toy compiler supporting only matmul, elementwise, and permute ops is realistic, not just a simplification.
11. **Power predictability as an optional extra.** S5 and S6 report cycle-by-cycle power prediction from the static schedule. A simulator could emit a per-cycle activity trace. This is an easy, sourced bonus feature.

**Candidate ledger entries (LP30, Groq 3):**

| Parameter | Value | Status |
|---|---|---|
| SRAM per chip | 500 MB | SOURCED [S1, S3]. S7 says 512 MB (discrepancy) |
| SRAM bandwidth per chip | 150 TB/s | SOURCED [S1] |
| FP8 compute per chip | 1.2 PFLOPS | SOURCED: S1 tray ÷ 16; S8 |
| Vector width | 320 B | SOURCED [S1] |
| C2C links | 96 × 112 Gbps, 2.5 TB/s bidirectional | SOURCED [S1] |
| C2C latency | 350 ns | SOURCED, press report of a Hot Chips slide [S6] |
| Chips per rack | 256 (16 trays × 16) | SOURCED [S1] |

**Not public for LP30 (ASSUMED if used, or take from the ISCA 2020/2022 papers covered in reports 01/02):** clock frequency, number of slices or lanes, MXM array dimensions, stream-register count, instruction set, per-op latencies, compile time.

**Gen-1 GroqChip values that appear in the recent sources:** 230 MB [S15, S11]; ~80 TB/s [S13, S11]; 14 nm GlobalFoundries [S13, S15, S16]; ~725 mm² die [S15]; 900 MHz default power-analysis frequency [S14]; 188 TFLOPS [S11 Table III].

---

## 4. Vendor vs independent: summary

- **Independent measurement:** S11 (Harvard; physical GroqRack gen 1 plus Groq API) and the Artificial Analysis LPX runs. The AA runs used an NVIDIA-chosen model, endpoint, and concurrency (S6, S9), and AA's original pages were not read here.
- **Groq-affiliated academic work:** S12.
- **Vendor technical marketing:** S1, S2, S3, S13, S14.
- **Press:** S5–S10, S15–S17. These largely relay vendor slides. S6, S8, S9 and S15 add critical analysis of chip counts and capacity.

---

## 5. Not found / unverified

- **Hot Chips 2026 slides:** the PDF link exists on the program page but returned HTTP 401. Any slide content beyond the S5 and S6 reporting is unverified, including LP30 floor plan, slice counts, clock, ISA, and compiler pipeline.
- **LP30 process node from an NVIDIA primary source:** not found. "Samsung 4 nm" comes from Tom's Hardware (S7) and Groq's pre-deal roadmap statements (S13, S16).
- **LP30 clock frequency, MXM dimensions, number of functional-unit slices, and on-chip stream organisation:** not found in any 2026 source I read.
- **LP30 compile times, dynamic shape or sequence-length support, max context per chip, and how KV cache is laid out across SRAM:** not found. S2 says only "we expect to be able to maintain this speed into the multi-hundred thousands of tokens" (a vendor expectation).
- **Use of the 512 GB + 256 GB per-tray DRAM by the LPU:** not explained in S1 or S3.
- **TruePoint numerics:** only secondary (S10). Groq's TruePoint document and the "Inside the LPU" blog (A. Ling, 2025) could not be read. The live URL has no body, and archive.org was unreachable from this session.
- **Precision used in the Gemma 4 AA benchmark:** not stated (S2 says only "no loss of precision or model quality").
- **Argonne ALCF evaluations of Groq for LLMs:** search found ALCF testbed pages, a GroqRack deployment announcement, and a BraggNN inference study mention (snippets only). I did not find or read a paper with Groq LLM results. "LLM-Inference-Bench" (Chitty-Venkata et al., PMBS 2024) came up in a search snippet, but I did not confirm whether it includes Groq. **Unverified.**
- **Chips and Cheese, and EE Times analyses of Groq LPU:** not found or not read. The EE Times "4-year-old silicon" article failed to load.
- **SemiAnalysis full tokenomics tables:** paywalled. Only the free opening was read.
- **Artificial Analysis primary pages:** not fetched. AA figures are second-hand via NVIDIA (S2) and press (S6, S9, S17).
- **Unread arXiv papers:** TauLang (S18) and FastAFD (S18) abstracts only. "AI Hardware Accelerators for Large Language Models: Architectures and the Memory Wall" (arXiv:2608.28048) is a survey that mentions Groq; I did not read it.
- **Unverified recollection:** I recall from memory that the ISCA 2022 Groq paper and Groq marketing gave GroqChip v1 figures of ~750 TOPS INT8 and ~188 TFLOPS FP16 at 900 MHz. In this session I confirmed only "188" TFLOPS (S11, precision unstated) and a 900 MHz power-analysis default (S14). Treat the rest as unverified here; reports 01/02 should be the source for those numbers.
