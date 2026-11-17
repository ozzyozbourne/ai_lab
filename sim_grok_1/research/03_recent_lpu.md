# 03 — Recent Groq LPU material (2023–2026)

Research date: 2026-11-14. Every source below was opened by the author of this note (via web fetch or by downloading the PDF and extracting the text), except where a row says otherwise. Verbatim phrases are in "quotes". Arithmetic I did myself is labelled **[derived]**. Anything I recall but could not verify is under §9 and labelled "from memory, unverified".

**Re-check of 2026-11-17 (independent verifier).** Every URL below was fetched again and the quotations compared with the page or PDF text. All were reachable except: EE Times (§6.4, connection failed; not re-verified), the GitHub repository page for GroqFlow (§7.4, blocked; the "archived" date is not re-verified, the README and user guide were), and the sources this note already lists as paywalled or not retrievable. Corrections made: three phrases that were in quotation marks but were not the sources' exact words (§2.1 revenue claim, §2.3 schedule, §7.1 speed advantage), the use of the Series A money (§1), the StorageReview rack counts (§5), and an unsupported "10,996" figure (§8 item 6). One cross-check was added in §4.1.

Primary = written by Groq or NVIDIA (including Groq engineers' peer-reviewed papers). Independent = press, analysts, academics.

---

## 0. TL;DR for the simulator project

* There are now **two documented LPU generations**:
  * **LPUv1 / GroqChip.** GlobalFoundries 14 nm, 230 MB SRAM, 235 GB/s C2C. A Groq-authored **retrospective paper (SHIP, MLSys 2026)** describes it in production detail.
  * **LP30, marketed as "NVIDIA Groq 3 LPU".** Samsung 4 nm, 500 MB SRAM, 150 TB/s SRAM bandwidth, 1.2 PFLOPS FP8, 96×112 Gbps C2C. NVIDIA describes it at rack level and has published little about the microarchitecture.
* The core TSP ideas carry over to LP30 unchanged, as NVIDIA and Groq both say themselves:
  * MXM / VXM / SXM / MEM functional units
  * 320-wide vectors as the unit of work
  * compiler-scheduled execution with no runtime arbitration
  * chips that act as their own routers
  * clock-drift-compensated synchronous C2C
* The biggest limitation, which every independent source repeats, is **capacity**:
  * models must be spread over hundreds to thousands of chips
  * KV cache caps batch size at long context
  * NVIDIA's own answer is to pair LPX with HBM GPUs (attention/KV on the GPU, FFN/decode or draft model on the LPU)
* Static shapes are confirmed in primary sources:
  * GroqFlow: compile for a maximum input size and "pad your inference inputs"
  * SHIP: dynamic context length and MoE routing are "mapped to static shapes with runtime-provided masks"
* An independent ISPASS 2026 paper measured:
  * **build times "upwards of 4500 seconds"** that grow linearly with chip count
  * a limited set of supported operators
  * no batch-size scaling on its physical rack

---

## 1. Corporate context (needed to read the 2026 sources)

| Claim | Source | Type |
|---|---|---|
| On 24 Dec 2025 Groq entered a "non-exclusive licensing agreement" with NVIDIA for its inference technology. Founder Jonathan Ross, President Sunny Madra and other team members "join Nvidia to help advance and scale the licensed technology". Groq "will continue to operate as an independent company" with Simon Edwards as CEO, and "GroqCloud will continue to operate without interruption". | https://groq.com/newsroom/groq-and-nvidia-enter-non-exclusive-inference-technology-licensing-agreement-to-accelerate-ai-inference-at-global-scale (Groq press release, 2025-12-24) | Primary |
| Reported price is about $20B. NVIDIA told press it is not an acquisition of the whole company. Analysts disagree on whether it is a license, an acquihire or an acquisition. | https://www.constellationr.com/insights/news/nvidias-groq-deal-acquisition-acquihire-or-creative-licensing-deal ; https://www.tomshardware.com/tech-industry/semiconductors/nvidia-confirms-20-billion-groq-deal-to-bolster-ai-inference-dominance (search-result summaries only; I did not open the bodies) | Independent |
| Groq (the remaining company, now a cloud operator) raised a $350M "Series A" (2026-08-17) at a $3.5B valuation, with planned NVIDIA participation, led by Disruptive; the release says the capital "will support those seeking usage of medium and larger sized clusters of NVIDIA accelerated computing for training and inference". It became an "NVIDIA Cloud Partner" (blog listing dated 2026-08-12). It plans to deploy Vera Rubin NVL72 plus Groq 3 LPX (2026-08-24). | https://groq.com/newsroom/groq-closes-usd350-million-series-a-building-the-world-s-leading-ai-inference-cloud ; https://groq.com/blog (listing) ; https://groq.com/blog/groq-among-the-first-to-bring-nvidia-groq-3-lpx-and-vera-rubin-nvl72-to-market | Primary |

What this means for reading the sources:

* From 2026 on, "Groq 3 LPU / LP30 / LPX" is an **NVIDIA product**, presented by ex-Groq engineers.
* Groq-the-company now runs a cloud on NVIDIA hardware.
* Groq's older first-generation hardware is documented in the SHIP paper (§4).

---

## 2. NVIDIA "Groq 3" / LP30 / LPX sources (primary)

### 2.1 NVIDIA Technical Blog: "Inside NVIDIA Groq 3 LPX: The Low-Latency Inference Accelerator for the NVIDIA Vera Rubin Platform"

* **URL:** https://developer.nvidia.com/blog/inside-nvidia-groq-3-lpx-the-low-latency-inference-accelerator-for-the-nvidia-vera-rubin-platform/
* **Date:** 2026-03-16 (GTC 2026)
* **Authors:** Kyle Aubrey, Farshad Ghodsian (NVIDIA)
* **Status:** Reachable. Primary source.

**Per-chip technical specifics**

* "500 MB of on-chip SRAM", used as the primary working storage. The compiler and runtime place weights, activations and KV state there explicitly, with no hardware-managed caches. The blog calls this "SRAM-first".
* About 150 TB/s on-chip SRAM bandwidth per LPU. This matches the tray figure of 2.4 PB/s ÷ 16.
* "320-byte vectors" are the unit of work for arithmetic, memory access and inter-device transfer.
* Functional units:
  * **MXM** (matrix execution modules): dense multiply-accumulate
  * **VXM** (vector execution modules): pointwise ops, type conversion, activations
  * **SXM** (switch execution modules): permutation, rotation, distribution, transposition
* C2C: "96 links at 112 Gbps", about 2.5 TB/s aggregate bidirectional I/O per LPU.

**Scheduling and determinism (technical, but qualitative)**

* The compiler schedules computation, data movement and synchronisation. There are no dynamic hardware schedulers at runtime.
* A "plesiosynchronous" chip-to-chip protocol cancels natural clock drift and aligns hundreds of LPUs as one system.
* Periodic software synchronisation is used.
* The blog says it builds on Groq's spatial execution model.

**Rack and tray**

* 256 LP30 per LPX rack, in "16 liquid-cooled 2U compute trays" of 16 LP30 each.
* Per tray: 8 GB SRAM, 2.4 PB/s, 19.2 PFLOPS FP8, 40 TB/s scale-up. DRAM is "up to 512 GB via fabric expansion logic, up to 256 GB via host CPU".
* Per rack: 315 PFLOPS FP8, 128 GB SRAM, 40 PB/s SRAM bandwidth, 640 TB/s scale-up.

**Positioning (architecture-level)**

* LPX is not a standalone system. It sits beside Vera Rubin NVL72 GPUs.
* Attention–FFN disaggregation: the GPUs do prefill and decode attention over the KV cache, and LPX does sparse MoE expert FFNs and other pointwise work during decode. Activations are exchanged every token.
* LPX can also run the draft model for speculative decoding.
* NVIDIA Dynamo orchestrates the split.

**Marketing claims (vendor, unverified)**

* "Up to 35x higher inference throughput per megawatt" versus GB200 NVL72 at about 400 TPS/user, for a 2T-parameter MoE with 400K input context.
* "up to 5x more revenue per megawatt compared with the GB200 NVL72, and up to 10x by pairing Vera Rubin NVL72 with LPX"; elsewhere the post says "up to 10x more revenue opportunity for trillion-parameter models".
* Annual revenue illustration, per gigawatt, from a figure: $30B (Blackwell) / $150B (Rubin) / $300B (Rubin + LPX).

**Not stated:** process node, die size, clock, slice/superlane layout, instruction set. The blog also gives no explicit comparison to the original TSP; it only cites the ISCA 2020 "Think Fast" paper and the ISCA 2022 multiprocessor paper as references.

### 2.2 NVIDIA product page: "NVIDIA Groq 3 LPX"

* **URL:** https://www.nvidia.com/en-gb/data-center/lpx/ (undated product page)
* **Status:** Reachable. Primary source.
* Per chip: 500 MB SRAM, 150 TB/s SRAM bandwidth, 2.5 TB/s scale-up.
* Per rack: 256 chips, 128 GB SRAM, **12 TB DDR5** (for "large models and workloads"), 40 PB/s, 640 TB/s.
* "deterministic, low-latency token generation". No mechanism is given.
* The 35x throughput/MW claim is tied to Qwen-3 235B, Kimi K2.5 1T and a 2T GPT-MoE, with KV sizes from 32K to 400K. The page says the figures are "subject to change".

### 2.3 NVIDIA Technical Blog: "How NVIDIA Groq 3 LPX Unlocks Ultrafast Interactivity at Long Context on NVIDIA Vera Rubin"

* **URL:** https://developer.nvidia.com/blog/how-nvidia-groq-3-lpx-unlocks-ultrafast-interactivity-at-long-context-on-nvidia-vera-rubin
* **Date:** 2026-08-24
* **Authors:** Seth Weidman, Kirthi Devleker, **Andrew Ling** (Andrew Ling is also the senior author of the Groq SHIP paper)
* **Status:** Reachable. Primary source.

**Third-party result (run by Artificial Analysis on an endpoint NVIDIA set up)**

* Gemma 4 31B (dense), median output speed:
  * 3,431 tok/s at 100K input, versus 870 tok/s for the fastest public endpoint
  * 3,382 tok/s at 10K input, versus 1,402 tok/s
* Tokenizer: o200K_base.

**NVIDIA-run result:** SPEED-Bench (coding), median 4,767 tok/s, P80 5,520 tok/s.

**Architecture statements**

* The compiler sees compute units, memory and C2C links and can "produce a schedule, down-to-the-clock cycle of exactly how the workload will run before it begins".
* This "eliminates the need for real-time arbitration of transfers".
* Each LPU can act as a router.
* The compiler starts sending each 320-byte slice of a matmul result over C2C as soon as it is ready.
* The design makes tensor parallelism effective at small batch.

**Three serving modes:** prefill–decode disaggregation, attention–FFN disaggregation, and an external-drafter speculative decoding mode.

**Caveats the post itself gives**

* Holding this speed into hundreds of thousands of tokens of context is an expectation ("we expect"), not a measurement.
* The 2T GPT-OSS figures are projections.
* The post gives no rack count, power or per-chip FLOPS.

### 2.4 NVIDIA press release: "NVIDIA Groq 3 LPX Now in Full Production With World-Class Speed for Agentic AI"

* **URL:** https://nvidianews.nvidia.com/news/nvidia-groq-3-lpx-now-in-full-production-with-world-class-speed-for-agentic-ai
* **Date:** 2026-08-24
* **Status:** Reachable. Primary source, marketing.
* Claims "full production", the 3,400 tok/s figure on Gemma 4 31B at 100K, and "4x faster responsiveness ... than the nearest alternative platform".
* Nebius is the first cloud adopter.
* The release does **not** name Samsung or any process.

### 2.5 Groq blog: "Groq Among the First to Bring NVIDIA Groq 3 LPX and Vera Rubin NVL72 to Market"

* **URL:** https://groq.com/blog/groq-among-the-first-to-bring-nvidia-groq-3-lpx-and-vera-rubin-nvl72-to-market
* **Date:** 2026-08-24
* **Status:** Primary source, marketing.
* Repeats 3,400 tok/s on Gemma 4 31B at 100K context (Artificial Analysis) and "4x higher interactivity".
* Contains no LPU hardware generation details.

---

## 3. Hot Chips and other conference talks

### 3.1 Hot Chips 2026 (HC38): "Think Fast: LPU Accelerator for Heterogeneous Compute"

* **Speakers:** Igor Arsovski & Santosh Raghavan (NVIDIA)
* **Session:** AI 1, Tue 2026-08-25, 2:15–4:15 PM PDT
* **Source:** program listing at https://hotchips.org/ (read through the fetch tool; a direct curl got HTTP 406 from mod_security)
* **Slides: NOT publicly accessible.** The program links only to a paid "Slide and Video Access" registration page (https://hotchipssymposium.regfox.com/hot-chips-2026-video-and-presentation-access). I did not see the slides, and their content is reported here only second-hand, from the live blog below.

**ServeTheHome live blog**

* **URL:** https://www.servethehome.com/nvidias-groq-3-lpu-accelerators-for-heterogeneous-ai-compute-at-hot-chips-2026/
* **Date:** 2026-08-25
* **Author:** Ryan Smith
* **Status:** Independent reporting of primary slides. The blog warns it was "written live".
* Rack: "256 LPUs in a single LPX rack ... 128GB of SRAM", "40PB/second of aggregate SRAM bandwidth", "315 PFLOPS of FP8".
* "This is a fully deterministic chip. There is no branching or other sources of non-determinism." STH does not say whether "no branching" means no data-dependent control flow in the ISA, or only at the scheduling level.
* "Because the chip is deterministic, the instruction scheduling is handled in software". The compiler "schedules all resources, both processing and networking".
* Each chip "acts as both a processor and a router". "There is no hardware flow control or virtual channels here."
* Determinism is also used for power smoothing; STH reports it reduces voltage droop by 60%.
* An FPGA acts as an async bridge between the synchronous LPU domain and the GPUs / external KV cache.
* Benchmarks:
  * "a single rack can decode 11,000 tokens per second on a 31B model (Gemma 4)"
  * Artificial Analysis result: "4x higher token output rate than the next-closest public competitor"
* NVIDIA's own caveat, as STH reports it: GPUs "are still the king of efficiency when total throughput is all that matters".
* Slide titles "LPU Core SIMDs" and "LPU Core Schedule" appear only as captions, with no content transcribed.

**Tom's Hardware**

* **URL:** https://www.tomshardware.com/tech-industry/semiconductors/nvidia-presents-groq-3-lpx-architecture-and-unveils-its-first-third-party-inference-benchmark
* **Status:** Body **not retrievable**; only the headline was reachable.
* Headline: "LP30-based rack is already in production".
* A search snippet (not verified against the article) says the talk was given by "Groq's former chief architect" and reused the "Think Fast" title of the 2020 ISCA paper.

### 3.2 MLSys 2026: SHIP talk and slides (primary, Groq team)

* **URL:** https://mlsys.org/media/mlsys-2026/Slides/3834_VmkjzHq.pdf
* **Date:** 2026-05-21
* **Presenter:** Andrew Bitar, "LPU Team"
* **Status:** Reachable.
* The slides confirm the LPUv1 facts:
  * "GlobalFoundries 14nm (2016)", "230 MB SRAM, 235 GB/s C2C"
  * "Deterministic execution, no reactive hardware", "Statically-scheduled by LPU compiler"
  * "No dedicated router chips – LPUs act as both processor and router"
  * network diameter "8 LPUs: 1 hop · 72 LPUs: 3 hops · 136 LPUs: 5 hops", with "300 ns" per hop
* Details in §4.

### 3.3 Hot Chips 34 (2022): Groq talk by Dennis Abts

* **URL:** https://hc34.hotchips.org/assets/program/conference/day2/Machine%20Learning/HotChips34%20-%20Groq%20-%20Abts%20-%20final.pdf (found by search, not opened by me)
* This is the ISCA 2022 multiprocessor material, covered in `02_tsp_multiprocessor_isca2022.md`.
* Coverage: https://www.hpcwire.com/2022/08/25/groq-designs-chip-that-hands-over-controls-to-software/ (not opened).
* **I found no Groq talk at Hot Chips 2023 or 2024, and no Linley talk.**

---

## 4. Groq SHIP paper (MLSys 2026): the most detailed recent primary technical source

* **Paper:** "SHIP: SRAM-Based Huge Inference Pipelines for Fast LLM Serving"
* **Authors:** A. Bitar et al. (27 authors; senior author Andrew Ling), Groq
* **Venue:** MLSys 2026
* **URLs:**
  * https://proceedings.mlsys.org/paper_files/paper/2026/file/9c20f16b05f5e5e70fa07e2a4364b80e-Paper-Conference.pdf (PDF downloaded and read in full)
  * https://mlsys.org/virtual/2026/oral/3834
* **Type:** Primary (Groq-authored), peer-reviewed, and the most candid source on limitations.

### 4.1 Generations

* "At the time of publication, the next-gen LPU—fabricated on Samsung's 4 nm process—is in full production ... this work looks back on LPUv1, built on GlobalFoundries 14 nm."
* "LPUv1 (GlobalFoundries 14 nm) integrates 230 MB of SRAM and provides 235 GB/s of aggregate chip-to-chip I/O bandwidth across 11 logical ports."
  * **[derived]** 230 MB agrees with the "220 MiBytes" of the two ISCA papers: 220 × 2²⁰ bytes = 230.7 × 10⁶ bytes. So LPUv1 is the same chip as the TSP of `01_...` and `02_...`, not a revision with more memory.
  * 11 ports matches the 7 local + 4 global links of the ISCA 2022 paper (`02_...` §1.1). The 235 GB/s is not broken down; it is lower than the 480 GB/s (16 links × 4 lanes × 30 Gb/s × 2 directions) of the 2020 material, and SHIP does not say how it is counted.

### 4.2 Microarchitecture (matches the original TSP)

* "Tensors—physically represented as collections of vectors—stream across functional units (FUs) laid out horizontally across the chip."
* Each FU is "a SIMD unit operating on 320-element vectors, controlled by its own instruction dispatch unit".
* FU types are MXM, VXM and MEM. "Each FU is issued one instruction per cycle, enabling pipelined, stall-free, deterministic execution."
* Determinism rests on three properties:
  * "(i) all instruction latencies are statically known"
  * "(ii) on-chip SRAM accesses are deterministic and require no temperature-dependent refresh cycles"
  * "(iii) the interconnect consists of directional, arbitration-free buses that move data eastward and westward"
* For non-deterministic external components such as host memory over PCIe, "the LPU's ISA provides a lightweight synchronization instruction to re-align functional units to a common time domain."
* Multi-chip: clock drift is handled "using a combination of shallow FIFOs and statically scheduled 'deskew' instructions". "No dedicated router chips are used". Dynamic shapes are "mapped to static shapes with runtime-provided masks ... and dynamic data-access via the LPU's memory gather/scatter instructions."

### 4.3 System and topology (LPUv1)

* Node and rack:
  * 8 LPUs per node, as PCIe Gen4 x16 cards in a 4U chassis
  * dual-socket AMD host with 1 TB DDR4
  * 9 nodes per rack, giving 72 LPUs per rack
* "QuadFour" topology:
  * a node is a K8 clique, with seven intra-node copper connectors per card
  * each node has 32 external links, four to each of its 4 forward and 4 backward neighbour nodes
  * "853 GB/s bisection bandwidth" within a partition
* Hop latency is "300 ns per LPU-to-LPU hop", versus 1–10 µs typical for GPU collectives.
* A 72-LPU TP partition has 16.56 GB of SRAM and a 3-hop diameter. A 136-LPU partition has 31.28 GB and 5 hops.
* AllReduce reaches "50% bandwidth saturation at a tensor size of 32KiB, and 90% saturation at a tensor size of 80KiB". Typical collective tensors are 32–256 KiB.
* Inter-partition bandwidth when skipping failed nodes (Table 1): 427 / 256 / 128 / 43 GB/s for 0 / 1 / 2 / 3 skipped nodes.
* Power: "the provisioned power of the LPUv1 system is 388 W per LPU, compared with 1,788 W per GPU for a B200 DGX."
* Power model: "an instruction-level power model was derived from RTL simulations and calibrated against silicon"; "instruction traces can therefore be statically converted to cycle-accurate power profiles". The compiler reorders instructions or inserts "short NOP gaps" to reduce droop. This is a directly reusable idea for the simulator.

### 4.4 Limitations, in Groq's own words

* "the limiting factor shifts from bandwidth to capacity"
* Capacity "typically requires partitioning across hundreds to thousands of chips"
* LPUv1's "bandwidth and radix provisioning constrained the peak efficiency ... exposed communication costs that hurt FLOPs utilization"
* "peak FLOP/s efficiency of SHIP systems does not match NVIDIA GPU systems"
* There is a "bandwidth mismatch between compute FLOPs and C2C", which is "a key challenge to scaling regardless of batch size"
* "Memory capacity constraints in SHIP reduce system throughput with growing CL"
* For reasoning traffic, SHIP shows "a pronounced drop" in prefill throughput (it/s/u)
* Batch cap formula: "Bmax = ceil(num kv caches can fit / pipeline depth)"
* Each added pipeline stage needs another in-flight micro-batch's KV cache
* MoE: per-token expert execution means expert matmuls run "with an OI of 1"
* Deterministic power modelling needed "extensive calibration and conservative margining ... This created some deployment headaches"
* Example configuration: Qwen3-235B-A22B at TP=16, PP=95, with max concurrency 380. That is roughly 1,520 LPUs **[derived, assuming TP=16 means 16 LPUs per pipeline stage; the paper does not state the total]**. gpt-oss-120B was partitioned across 72 LPU nodes (576 LPUs) **[derived: 72×8]**.
* Paged attention uses page sizes of 128–512 tokens. In production, 92% / 97% of requests use fewer than 8Ki tokens.
* Dynamic chunked prefill works down to a chunk size of 1 token. Footnote: self-attention operational intensity is 8 for Llama3.3-70B, 16 for Qwen3-235B and 128 for DeepSeek-V3.

---

## 5. Press and analyst write-ups of LP30 / LPX (independent)

| Source | Date / author | Extracted claims |
|---|---|---|
| The Register, "Decoding Nvidia's Groq-powered LPX..." https://www.theregister.com/2026/03/19/nvidia_lpx_deep_dive/ | 2026-03-19, Tobias Mann | <ul><li>LP30 is fabbed by **Samsung** (no node given)</li><li>500 MB SRAM, 150 TB/s, "1.2 petaFLOPS of FP8"</li><li>**No FP4**: MX/NVFP4 is slated for "LP35" next year</li><li>96 SerDes × 112 Gbps = 2.5 TB/s</li><li>Based on "Groq's second-gen LPU tech", with last-minute tweaks before tape-out</li><li>**32 trays × 8 LPUs**, with an Oberon ETL256 copper backplane</li><li>A 1T-parameter model needs "between four and eight LPX racks, or 1,024 to 2,048 LPUs" (4- vs 8-bit weights)</li><li>At launch it lacks NVLink and CUDA compatibility</li><li>Long context or large batch needs more GPUs, because KV stays on the GPU</li></ul> |
| StorageReview, "NVIDIA Groq 3 LPX: everything we know" https://www.storagereview.com/news/nvidia-groq-3-lpx-everything-we-know | 2026-03-18, Divyansh Jain | <ul><li>"1.2 PFLOPS of FP8 compute per chip"</li><li>"1U compute tray contains exactly eight LP30 chips", 32 trays</li><li>Interconnect named "Groq RealScale C2C"</li><li>Model size is bounded by SRAM: "DeepSeek R1 at 623 GB would require roughly five LPX racks, while GLM 5 at 1.4 TB in BF16 would need over ten" (whole-model on-disk sizes, not the FFN alone)</li><li>Power efficiency "remains to be validated independently"</li></ul> |
| StorageReview, "NVIDIA Groq 3 LPX Enters Full Production" https://storagereview.com/news/nvidia-groq-3-lpx-enters-full-production-3400-tokens-per-second-at-100k-context-256-lp30s-per-rack | 2026-08-24, Harold Fritts | <ul><li>"Each 2U liquid-cooled compute tray carries sixteen Groq 3 LPUs", but its own image caption says 1U/8</li><li>NVIDIA's figure came from a "private pre-release endpoint", while competitors' came from "live serverless production endpoints"</li></ul> |
| The Decoder, "Nvidia says its Groq 3 LPX is four times faster than Cerebras but the math is more complicated" https://the-decoder.com/nvidia-says-its-groq-3-lpx-is-four-times-faster-than-cerebras-but-the-math-is-more-complicated/ | 2026-08-25, Maximilian Schreiner | <ul><li>Benchmark = 50 back-to-back requests</li><li>Gemma 4 31B is a "best-case scenario: a dense model that fits entirely in one rack"</li><li>Needs "at least 64 chips", versus 1–2 Cerebras accelerators</li><li>DeepSeek V3 would need 1,342 LPUs, about 5 racks</li><li>Scaling to large MoE is "an open question"</li></ul> |
| Rajesh Beri, "3,400 Tokens/s Was Batch 1. At 100K Context, It's Batch 12." https://www.beri.net/article/nvidia-groq-3-lpx-cerebras-cs4-batch-size-one-inference-capacity-sizing | 2026-08-29 | Analyst arithmetic for one standalone rack: <ul><li>~31 GB of 8-bit weights (~64 LPUs) leaves ~97 GB for KV</li><li>~8 GB KV per 100K-token sequence, so **max batch ≈ 12**</li><li>~150 sequences at 8K context</li></ul> This is the author's own estimate, not a measurement. |
| Asia Economy (asiae), Samsung mass production https://view.asiae.co.kr/en/article/2026082608011466535 | 2026-08-26 | <ul><li>Groq3 LPX is made on "Samsung Electronics' 4nm ... process" at the **Pyeongtaek** campus</li><li>"inference-only"</li></ul> |
| Asia Economy, 2023 https://www.asiae.co.kr/en/article/2023081810390400179 | 2023-08-21 (AI-translated) | <ul><li>Groq to produce "4-nanometer" chips at Samsung's **Taylor, Texas** fab</li><li>Older TSP claims of "1 POPS" and "18,900 IPS on ResNet-50 v2"</li></ul> |
| Groq/Samsung press release (2023) mirrored at Design & Reuse https://us.design-reuse.com/news/54650/groq-samsung-foundry-ai-accelerator.html | Aug 2023 | <ul><li>Next-gen silicon "manufactured by Samsung on its SF4X process (4nm)"</li><li>The next gen will "utilize the revolutionary first-gen Tensor Streaming architecture", meaning the same architecture family</li></ul> |
| More Than Moore (Ian Cutress) https://morethanmoore.substack.com/p/nvidia-introduces-groq-lp30-and-lpx | 2026-03-16 | **Paywalled**; only the intro was visible. It describes Groq's chip as "an SRAM based chip that relied on a very fixed VLIW pipeline", similar to a DSP. |

---

## 6. Independent evaluations and limitations of earlier LPU systems

### 6.1 "The xPU-athalon: Quantifying the Competition of AI Acceleration" (ISPASS 2026)

* **URL:** https://arxiv.org/abs/2604.10852 (PDF read in full)
* **Date:** submitted 2026-04-12
* **Authors:** Alicia Golden, Carole-Jean Wu, Gu-Yeon Wei, David Brooks (Harvard / Meta)
* **Type:** Independent academic. Physical access to **1 GroqRack (72 GroqChips, i.e. LPUv1)** using "Groqit and Groqflow 4.3.1", plus the GroqCloud API.

**Findings**

* "Groq sees roughly 10× lower peak throughput than H100s, yet is less memory bandwidth bound due to its on-chip SRAM."
* Area efficiency is 0.11× that of H100 (FLOPS per mm²).
* Operator latency versus H100 at small scale: 1.64× faster on sin, 14.42× on mm, 300.16× on rsqrt. Power was "up to 35× ... 51.44× ... 18.61×" more than the other platforms on those primitives. "Groq is the most power-hungry platform" for primitives.
* Groq "achieves pareto optimality on decode under zero-communication assumptions, yet loses that position when scale-out communication costs are incorporated".
* Llama-3.1-8B low-batch latency per token, via the API: Groq at 30.03% of H100.

**Programmability**

* "even simple batch size scaling is not supported with our physical CS-3 and Groq setup".
* "build times for Groq can be upwards of 4500 seconds, and scale linearly with the number of chips". Compilation and assembly take 40% and 59% of build time. Groq "requires highest build frequency".
* "only a few hundred" PyTorch operators are supported. The paper says Groq lacks "torch.mm and ... Scaled Dot Product Attention" on the physical hardware. This sits oddly with its own mm microbenchmark; I assume the mm benchmark went through an export or alternative path.
* Code needs ONNX export wrappers and an in-house template.
* "deploying a LLaMA model on nine Groq racks required approximately 1.5 years of coordination and repeated compiler issues, and ultimately only hand-compiled models from Groq engineers were executable".

### 6.2 SemiAnalysis, "Groq Inference Tokenomics: Speed, But At What Cost?"

* **URL:** https://newsletter.semianalysis.com/p/groq-inference-tokenomics-speed-but
* **Date:** 2024-02-21
* **Authors:** Dylan Patel, Daniel Nishball
* **Status:** **Paywalled**; I saw only the visible intro, as relayed by search.
* "8 racks of 9 servers each with 8 chips per server ... 576 chips" to serve Mixtral.
* A secondary summary gives per-server and total cost figures, which I did not verify (see §9).

### 6.3 The Next Platform, "The Battle Begins For AI Inference Compute In The Datacenter"

* **URL:** https://nextplatform.com/2024/09/10/the-battle-begins-for-ai-inference-compute-in-the-datacenter
* **Date:** 2024-09-10
* **Author:** Timothy Prickett Morgan
* 576 LPUs for Llama 2 70B, giving 315.06 tok/s.
* The author "strongly suspect[s]" Groq's 100× price/performance claim uses cloud API prices, not system cost.
* Cerebras says Groq used 8-bit precision for Llama 3.1 70B at 250 tok/s/user.

### 6.4 EE Times, "Groq Demonstrates Fast LLMs on 4-Year-Old Silicon"

* **URL:** read via the proxy reader https://hn.jakechampion.name/reader/https://www.eetimes.com/groq-demos-fast-llms-on-4-year-old-silicon/
* **Date:** 2023-09-12
* **Author:** Sally Ward-Foxton
* (Not re-verified on 2026-11-17: the proxy reader was not used and eetimes.com did not respond.)
* Llama 2 70B ran at 240 tok/s/user on a "64-chip" system. The article later says "640-chip", which contradicts itself.
* "design for batch equals one is critical".
* Llama 2 was ported in "a couple of days".

---

## 7. Groq's own explanations and tooling (primary)

### 7.1 "What is a Language Processing Unit?" / "The Groq LPU explained"

* **URLs:** https://groq.com/architecture and https://groq.com/blog/the-groq-lpu-explained (same content)
* **Date:** 2025-03-07
* **Type:** Marketing.
* Four principles: software-first, programmable assembly line, deterministic compute and networking, on-chip memory.
* "Groq on-chip SRAM has memory bandwidth upwards of 80 terabytes/second", versus about 8 TB/s HBM.
* "Our current chip set is built on a 14 nanometer process", with a move to 4 nm planned.
* "up to a 10X speed advantage" and "up to 10x more efficiently from an energy perspective" are unquantified marketing claims.
* The compiler is "generic, model-independent".

### 7.2 "From Speed to Scale: How Groq Is Optimized for MoE & Other Large Models"

* **URL:** https://groq.com/blog/from-speed-to-scale-how-groq-is-optimized-for-moe-other-large-models
* **Date:** 2025-05-27
* Marketing only: "RealScale™ chip-to-chip interconnect", "near-linear scalability", Llama 4 Maverick (400B MoE) on day one.

### 7.3 "Inside the LPU: Deconstructing Groq's Speed"

* **URL:** https://groq.com/blog/inside-the-lpu-deconstructing-groq-speed
* Search metadata says it is by Andrew Ling and dated 2025-08-01.
* **Now redirects to the blog index; content not retrievable.** Search snippets mention TruePoint numerics ("reduces precision only in areas that do not reduce accuracy"). StorageReview's paraphrase is "FP32-level accuracy from FP16 inputs via a 320-element fused dot product with a single rounding step". Unverified at source.

### 7.4 GroqFlow

* **URL:** https://github.com/groq/groqflow (README read)
* **Status:** "archived by the owner on Jul 31, 2025". It expects "8 LPUs (especially for larger models)" and "32GB RAM (or more) to build models".
* **User guide:** https://raw.githubusercontent.com/groq/groqflow/main/docs/user_guide.md (read). Static-shape evidence, verbatim:
  * The `inputs` argument "Dictates the maximum input size the model will support."
  * "Hint: At runtime, pad your inference inputs to this expected input size."
  * A build becomes stale when "The model, inputs, or arguments to `groqit()` have changed", which means a recompile.
* `num_chips`: "Number of GroqChip processors to be used"; by default "`groqit()` automatically selects a number of chips."
* Compile effort: "The higher the level, the lower the program cycle count and the longer the compile time."
* Pipeline stages include "5. Compile Model" and "6. Assemble Model" (Groq Compiler, then Groq Assembler).
* Numerics: parameters are converted "into type float16" by default. Optional "post-training quantization to int8" is available for PyTorch models only.
* Frameworks: PyTorch, Keras, TorchScript, ONNX, plus some scikit-learn and xgboost models.

### 7.5 GroqCloud model docs

* **URL:** https://console.groq.com/docs/models (undated, accessed 2026-11-14)
* Production models have a 131,072-token context window, e.g. llama-3.3-70b-versatile with 32,768 max completion tokens and gpt-oss-120b with 65,536.
* No training is offered on the page; it links to "LoRA Inference" only.
* These limits are service policies, not hardware limits. GroqCloud may now run partly on NVIDIA hardware (§1).

---

## 8. Contradictions between sources

1. **LPX tray configuration.**
   * NVIDIA's March blog: 16 trays × 16 LP30 (2U).
   * The Register and StorageReview (March): 32 trays × 8 LP30 (1U).
   * StorageReview (August) text says 2U/16, while its own caption says 1U/8.
   * All agree on **256 LPUs per rack**.
   * Per-tray scale-up bandwidth: NVIDIA says 40 TB/s for 16 chips; StorageReview cites 20 TB/s per tray for 8 chips. Both are consistent with about 2.5 TB/s per chip.
2. **SRAM per chip.** NVIDIA, The Register and StorageReview say 500 MB. A wiki and LinkedIn post say 512 MB (weak sources). 128 GB / 256 = 500 MB in decimal units **[derived]**.
3. **Generation naming.**
   * NVIDIA says "Groq 3".
   * The Register says it is based on "Groq's second-gen LPU tech".
   * SHIP calls it "the next-gen LPU" after LPUv1.
   * So LP30 is very likely the *second* Groq silicon design, marketed as "3".
4. **Fab location.** In 2023, Taylor, Texas was announced (asiae 2023, Design & Reuse). The 2026 reporting says Pyeongtaek, Korea (asiae 2026). NVIDIA names no foundry.
5. **"Process node not stated".** NVIDIA's blog, product page and press release give no node. The 4 nm figure comes from Groq's 2023 announcement, the SHIP paper ("Samsung's 4 nm") and Korean press.
6. **Gemma 4 31B throughput.**
   * 3,431 tok/s median single-stream (Artificial Analysis, concurrency 1).
   * "11,000 tokens per second" per rack (STH, Hot Chips). STH does not say whether this is aggregate throughput or another configuration; that it is aggregate is my guess. (An earlier version of this note also gave a "self-reported 10,996"; that number is in none of the sources fetched on 2026-11-17 and has been removed.)
   * These measure different things.
7. **Competitor baseline.** NVIDIA says 870 tok/s for the next-fastest endpoint; The Decoder says Cerebras at 882 tok/s.
8. **On-chip bandwidth.**
   * Groq's 2025 marketing: "upwards of 80 TB/s" (LPUv1).
   * The 2020 ISCA paper: see `01_tsp_isca2020.md`.
   * LP30: 150 TB/s.
   * Third-party explainers quote anywhere from 15 to 230 TB/s; disregard them.
9. **Llama 2 70B chip count.** EE Times (2023) says 64 chips, then 640 in the same article. Next Platform (2024) and SemiAnalysis (for Mixtral) say 576 = 8 racks × 9 nodes × 8.
10. **Compute versus efficiency framing.** NVIDIA claims 35× throughput/MW. SHIP admits "peak FLOP/s efficiency ... does not match NVIDIA GPU systems". xPU-athalon finds 10× lower peak throughput than H100 and high primitive power for LPUv1. The claims cover different generations and metrics, but they pull in opposite directions.

---

## 9. Not found / unverified

* **Hot Chips 2026 slides:** not public (paid registration). The speakers are known from the program; the content comes only from the STH live blog.
* **Tom's Hardware article bodies** (the Hot Chips piece and "first chip" piece): only headlines were retrievable.
* **SemiAnalysis Groq tokenomics:** paywalled. Unverified secondary figures: about $35k per 8-LPU server, about $2.52M for 576 chips, and holding cost about 10× H100 for Mixtral.
* **More Than Moore LP30 article:** paywalled.
* **Groq "Inside the LPU" blog (Aug 2025):** now redirects; TruePoint and RealScale details are unverified.
* **Groq "GroqThoughts_WhatIsALPU" PDF** (groq.com/wp-content/uploads/2024/07/...): HTTP 404.
* **SamMobile Samsung mass-production article:** HTTP 403.
* **LP30 die size, transistor count, clock frequency, slice/superlane counts, ISA changes:** **not published** in any source I could open. "~98 billion transistors" and "SF4 + AlphaWave SerDes" appear only in a wiki and a LinkedIn post (unverified).
* **LPUv1 clock "900 MHz" and die "25×29 mm":** these appear in search snippets from introl.com and aimresearch, which I did not open. They match the ISCA 2020 paper, which is covered by another note. From memory, unverified here.
* **"Nvidia pulled Rubin CPX to focus on the LPU":** appears only in a search-engine summary; I did not verify it in any article.
* **Hot Chips / Linley talks by Groq in 2023–2025:** none found.
* **Artificial Analysis' own Groq/LPX page:** not opened. The figures above come via NVIDIA's blog and press reports.
* **Any public compile-time figure for LP30** and **any LP30 batch-size limit from a primary source:** none found.
* From memory, unverified: GroqCloud historically limited context windows to about 8K for some models in early 2024, and LPUv1 numerics were INT8/FP16 with FP32 accumulation. The GroqChip product brief lists "INT8, INT16, INT32 & TruePoint™"; that is a search snippet from https://groq.com/wp-content/uploads/2024/08/GroqChip™-Processor-Product-Brief-v1.7.pdf, not opened.

---

## 10. Parameters for the simulator

Confidence levels:
* **H:** a primary source with an exact number
* **M:** a consistent number from several secondary sources, or primary but approximate
* **L:** derived or weakly sourced

| Parameter | Value | Source | Conf. |
|---|---|---|---|
| Vector width (lanes/elements) | 320 elements (LPUv1); "320-byte vectors" (LP30) | SHIP §2.1; NVIDIA blog 2026-03-16 | H |
| FU types | MXM, VXM, MEM (+ SXM on LP30 per NVIDIA; SXM also in the original TSP) | SHIP §2.1; NVIDIA blog | H |
| Instruction issue | 1 instruction / FU / cycle, own dispatch unit per FU | SHIP §2.1 | H |
| Stream direction | directional, arbitration-free buses moving "eastward and westward" | SHIP §2.1 | H |
| Hazards / arbitration | none at runtime; all latencies statically known; no HW flow control or virtual channels | SHIP §2.1; STH Hot Chips 2026 | H |
| Sync primitive | lightweight sync instruction to realign FUs after non-deterministic external I/O; "deskew" instructions + shallow FIFOs for C2C | SHIP §2.1 | H |
| LPUv1 SRAM / chip | 230 MB | SHIP §7.1; MLSys slides | H |
| LPUv1 C2C | 235 GB/s aggregate, 11 logical ports | SHIP §7.1 | H |
| LPUv1 on-chip BW | "upwards of 80 TB/s" | groq.com/architecture | M (marketing) |
| LPUv1 process | GlobalFoundries 14 nm | SHIP; groq.com/architecture | H |
| LP30 SRAM / chip | 500 MB | NVIDIA blog & product page | H |
| LP30 SRAM BW / chip | 150 TB/s | NVIDIA product page | H |
| LP30 compute / chip | 1.2 PFLOPS FP8 (no FP4) | The Register; StorageReview (consistent with 315 PF/256 ≈ 1.23 PF **[derived]**) | M |
| LP30 compute:bandwidth ratio | ≈ 8 FLOP/byte (1.2e15 / 150e12) | **[derived]** | L |
| LP30 C2C | 96 links × 112 Gbps ≈ 2.5 TB/s bidirectional | NVIDIA blog | H |
| LP30 process | Samsung 4 nm (SF4X per 2023 announcement) | SHIP; Design & Reuse 2023; asiae 2026 | M–H |
| C2C hop latency | 300 ns per LPU-to-LPU hop (LPUv1) | SHIP §4.2 | H |
| Node | 8 LPUs, fully connected (K8); host 1 TB DDR4 via PCIe Gen4 x16 | SHIP §2.1, §7.1.1 | H |
| Rack (LPUv1) | 9 nodes = 72 LPUs | SHIP §4.1, §7.1.1; xPU-athalon | H |
| Rack (LP30 LPX) | 256 LPUs; 128 GB SRAM; 12 TB DDR5; 640 TB/s scale-up | NVIDIA product page | H |
| Inter-node links | 32 external links per node, to 4 forward + 4 backward nodes ("QuadFour") | SHIP §4.1 | H |
| Network diameter | 8 LPUs: 1 hop; 72: 3 hops; 136: 5 hops | MLSys slides; SHIP | H |
| AllReduce saturation | 50% BW at 32 KiB, 90% at 80 KiB; typical tensors 32–256 KiB | SHIP Fig. 6 | H |
| Provisioned power (LPUv1) | 388 W per LPU (system-level) | SHIP §7.1.1 | H |
| Power model approach | instruction-level energy table → cycle-accurate power trace; compiler NOP insertion for droop | SHIP §7.1.2 | H (method) |
| Droop reduction from deterministic scheduling | 60% | STH Hot Chips 2026 (live-blog) | M |
| Build/compile time | up to >4500 s, linear in #chips (LPUv1, GroqFlow 4.3.1) | xPU-athalon §VI | H (independent) |
| KV page size | 128–512 tokens | SHIP §5.1 | H |
| Max batch rule | Bmax = ceil(#KV caches that fit / pipeline depth) | SHIP §6 fn. 2 | H |
| Default numerics (GroqFlow) | FP16 weights; optional INT8 PTQ | GroqFlow user guide | H |

---

## 11. Limitations worth modelling or documenting

1. **Static shapes, padded to a maximum.** A compiled program targets a fixed maximum input size. The runtime pads up to it, and any change of model, inputs or arguments forces a rebuild. Source: GroqFlow user guide. In production, variable context length and MoE routing are "mapped to static shapes with runtime-provided masks" plus gather/scatter (SHIP §7.2). *Simulator idea: compile per (shape bucket), feed masks at runtime, count wasted padded cycles.*
2. **Long compile and build times.** Over 4500 s, growing linearly with chip count, with compile and assemble dominating (xPU-athalon). Effort level trades cycle count against compile time (GroqFlow). *Toy compiler: report schedule-search time versus quality.*
3. **SRAM-only capacity drives the chip count.**
   * LPUv1 has 230 MB per chip; LP30 has 500 MB.
   * Models need "hundreds to thousands of chips" (SHIP).
   * 576 LPUv1 chips for Llama 2 70B (Next Platform) or Mixtral (SemiAnalysis).
   * 1,024–2,048 LP30 for a 1T model (The Register).
   * About 1,342 LP30 for DeepSeek V3 (The Decoder, Beri).
   * At least 64 LP30 for Gemma 4 31B at 8-bit (The Decoder).
4. **Batch is capped by KV cache, not compute.**
   * SHIP gives the formula Bmax = ceil(KV caches that fit / pipeline depth) and says pipeline parallelism needs a KV cache per in-flight micro-batch.
   * Beri estimates batch ≈ 12 at 100K context per standalone LPX rack.
   * xPU-athalon: "even simple batch size scaling is not supported" on its physical rack.
   * EE Times: design for batch = 1.
5. **Context length hurts throughput.** SHIP: "Memory capacity constraints in SHIP reduce system throughput with growing CL". KV stays on the GPU in LPX deployments, so long context means more GPUs (The Register).
6. **Communication-bound scaling.**
   * C2C bandwidth is far below compute (LPUv1: 235 GB/s versus 1,800 GB/s for B200 NVLink; SHIP).
   * Exposed C2C cycles remain even with overlap (SHIP §4.2).
   * Groq loses its Pareto position once communication is included (xPU-athalon).
   * *Simulator: model C2C bandwidth and 300 ns hop latency explicitly.*
7. **Lower peak FLOPs and area efficiency than GPUs.**
   * About 10× lower peak than H100 and 0.11× the area efficiency for LPUv1 (xPU-athalon).
   * "peak FLOP/s efficiency ... does not match NVIDIA GPU systems" (SHIP).
   * GPUs "are still the king of efficiency when total throughput is all that matters" (STH, quoting NVIDIA).
8. **MoE inefficiency at low batch.** Per-token expert execution means operational intensity is 1 for expert matmuls (SHIP §6).
9. **Narrow software surface.**
   * Only a few hundred PyTorch ops; no SDPA; ONNX export required; about 1.5 years to deploy Llama on 9 racks (xPU-athalon).
   * LP30 lacks CUDA compatibility and NVLink at launch (The Register).
10. **No FP4 on LP30** (The Register); FP16/INT8 in GroqFlow.
11. **Inference only.** "inference-only" (asiae 2026). NVIDIA positions training on GPUs. No training support appears in any LPU source; GroqCloud documents only inference and LoRA inference.
12. **Determinism stops at the chip boundary.**
    * Host DRAM over PCIe and prefix-cache transfers are non-deterministic and need resynchronisation (SHIP §7.2).
    * LPX uses an FPGA async bridge to the GPUs (STH).
    * Power-model margining caused "deployment headaches" (SHIP).
    * *Simulator: model a sync/realign instruction with a variable-latency external event.*
13. **Vendor benchmark caveats to note in any documentation.**
    * Single-stream (concurrency-1) results on a private pre-release endpoint, compared against public serverless endpoints (StorageReview, NVIDIA blog).
    * A dense model that fits in one rack (The Decoder).
    * 35×/MW and 10× revenue figures are projections (NVIDIA).
