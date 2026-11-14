# 02 — Abts et al., "A Software-defined Tensor Streaming Multiprocessor for Large-scale Machine Learning" (ISCA 2022)

Research note for the TSP educational simulator / toy static-scheduling compiler.
Legend used throughout:
- **[P]** = stated in the primary paper (full text read this session).
- **[S]** = stated in a secondary source (Groq Hot Chips 34 slides, 2022), read this session.
- **[I]** = my inference / arithmetic, not stated by any source.

Section numbers, figure and table numbers below refer to the paper. Page numbers are PDF pages (14 pages total).

---

## 1. Sources consulted (with reachability status)

| # | Source | URL | Status |
|---|--------|-----|--------|
| P1 | **Primary paper, full text** (ACM ISCA '22, pp. 567–580, DOI 10.1145/3470496.3527405). PDF metadata: title matches, 14 pages, created 2022-05-23 (camera-ready, LaTeX acmart). | https://groq.com/isca-2022-paper/ (also https://wow.groq.com/isca-2022-paper/) — this landing URL **directly serves the PDF** (2,514,601 bytes) | **READ IN FULL.** Text extracted with `pdftotext`; figures 2, 6, 7, 9, 15–20 viewed as rendered page images. |
| — | Groq-hosted PDF copy | https://groq.com/wp-content/uploads/2024/02/GroqISCAPaper2022_ASoftwareDefinedTensorStreamingMultiprocessorForLargeScaleMachineLearning.pdf | **Unreachable as PDF**: returns Groq's HTML 404/home page (HTTP 404 on wow.groq.com variant). |
| — | ACM DL PDF / landing | https://dl.acm.org/doi/pdf/10.1145/3470496.3527405 , https://dl.acm.org/doi/10.1145/3470496.3527405 | **HTTP 403** (both curl and WebFetch). Semantic Scholar API lists it as BRONZE open access at this URL. |
| — | Wayback Machine copy | web.archive.org/... | **Unreachable** (connection reset / tool refused domain). |
| — | Semantic Scholar API | https://api.semanticscholar.org/graph/v1/paper/DOI:10.1145/3470496.3527405 | Reachable; metadata only (CorpusId 249205420, DBLP conf/isca/AbtsKLKBBPADHTB22). |
| S1 | **Hot Chips 34 (2022) slides**, Abts, "The Groq Software-defined Scale-out Tensor Streaming Multiprocessor" (secondary) | https://hc34.hotchips.org/assets/program/conference/day2/Machine%20Learning/HotChips34%20-%20Groq%20-%20Abts%20-%20final.pdf | **Read (text layer only)**, 8-page PDF of multi-slide pages; slide numbers cited from footer "Public NN". Diagrams not inspected visually. |
| — | US patent 12,277,444 B2 "Software-defined tensor streaming multiprocessor for large-scale machine learning" | https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12277444 ; https://patents.google.com/patent/US12277444B2/en | USPTO PDF downloaded but is **image-only (no text layer)**; Google Patents HTML downloaded but **not read** (time). Not used. |
| — | cs.reviewer.ly entry | https://cs.reviewer.ly/app/publication/b1d192a3-53b6-481e-bb34-35360b8e49c6 | Unreachable (proxy 502). |
| — | aiwiki.ai "Groq hardware" | https://aiwiki.ai/wiki/groq_hardware | Seen only as a search snippet (claims "16 integrated C2C links per chip"); **not opened, not used** — and it conflicts with the paper (see §7). |

---

## 2. Findings: multi-chip scaling (topology, packaging, links)

### 2.1 Topology choice [P]
- Software-scheduled **Dragonfly** built as a **direct, "glueless"** network: each TSP is both endpoint and router (§2.1, Fig 4(c)). Abstract: "The TSP acts as both a processing element (endpoint) and network switch for moving tensors across the communication links."
- Rationale: indirect networks (fat-tree) "require intermediate switches or routers that introduce non-determinism from dynamic arbitration and queuing" (§2.1).
- A group of TSPs acts as a "virtual high-radix" router (§2.1, §2.2).

### 2.2 Packaging hierarchy [P, §2.2, Fig 5, Fig 6]
- Chip → PCIe card → **node = 4U chassis with 8 TSPs** → rack (Fig 5).
- Per-TSP link budget: "The pin-bandwidth from each TSP is partitioned into **7 'local' links and 4 'global' links**." (§2.2)
- Intra-node: the 7 local links give **full connectivity among the 8 TSPs** of a node (Fig 6(a): "TSPs within the node with all-to-all connections").
- Alternative intra-node configuration (Fig 6(b) caption text): "TSPs within the node configured as a radix-8 torus with three physical links per direction"; §4.4: "With a radix-8 local group topology, we triple-connect physical links within the torus to increase the nearest-neighbor throughput." (used for pipelined model parallelism) [P]. Fig 6 also labels a "training node" and an "inference node" (8 TSPs + spare in centre) — exact semantics not explained in text.
- Node as Dragonfly group: "All of the global links for each TSP within a node can be combined to create a **32 'virtual' port high-radix router**" (§2.2). (8 TSPs × 4 global = 32 [I, consistent].)
- Lanes: "Each C2C link consist of four (4) lanes and thus in theory, the radix can be increased to 11 × 4 = 44 ports. However, the packaging constraints of a PCIe card limits the number of links that can be exposed for inter-node communication." (§2.2)
- **Small system (single global hop):** "the TSP system can scale out up to **33 nodes for total of 33×8 = 264 TSPs** by providing full connectivity between all of the nodes that results in a **three hop topology with minimal routing**" ... "combined **56 GiBytes** of global SRAM" (§2.2).
- **Rack:** "the rack, consisting of **nine (9) nodes**, each with eight (8) TSPs, interconnected via the four (4) 'global' links per TSP for a total of 32 × 9 = **288 ports** of global bandwidth." (§2.2)
- **Large system:** rack becomes the local group; "partition half of the 288-ports to doubly-connect the set of nine (9) nodes within each rack using half (144) of the ports so that we have the proper **2× 'internal speedup'** ... The remaining 144 ports are used to connect to other racks ... up to **145 racks** ... 145 (racks) ×72 (TSPs per rack) for a total of **10,440 TSPs** in the largest system with **at-most 5 hop diameter** using minimal routing (two in the source-rack, one global hop, and two in the destination-rack)." (§2.2)
- Spare: "N+1 redundancy by provisioning a hot spare node (Fig 6) in every deployed rack" (§4.5). So 9 nodes/rack with one spare → 8 working nodes; also "a 33 node system with four racks would have 1 of 33 nodes as the spare (reducing the overhead from 11% to 3%, leaving 32 nodes (256 TSPs)" (§4.5). Note: 72 TSPs/rack in the 10,440 count includes the spare node [I].
- Abstract: "up to 10,440 TSPs and more than 2 TeraBytes of global memory accessible in less than 3 microseconds of end-to-end system latency." Each TSP contributes 220 MiB to global memory (Abstract).
- **No mention found** of the product names GroqCard/GroqNode/GroqRack in the paper except "GroqNode" in §5.4 (BERT on "four TSPs within a GroqNode"). S1 slide 35 names "GroqChip, GroqCard, GroqNode, GroqRack" [S]; S1 slide 36/38: "A single GroqRack ... Any node can be the 'spare' node" [S]; slide 37: "Multi-TSP system uses a 32-port 'group' as a building block—scale up to 33 groups in a single global hop" [S].

### 2.3 Global bandwidth profile [P, Fig 2, §1]
- Text (§1): "small systems with fewer than 16 TSPs can take advantage of abundant wire density within the node, and larger systems up to several hundred TSPs can take advantage of about **50 GB/sec** of global (bisection) bandwidth per TSP. As system size grows beyond 264 TSPs, the available global bandwidth flattens to about **14 GB/sec** of global bandwidth per TSP endpoint."
- Fig 2 annotations (read from figure): **~138 GB/sec** (system sizes ~2–8), **~88 GB/sec** (falling toward 16), **50 GB/sec** (16–264), **~14 GB/sec** (264–10,440).
- [I] 138 GB/s ≈ 11 links × 12.5 GB/s; 50 GB/s = 4 global links × 12.5 GB/s. These matches are my arithmetic; the paper does not derive them, and it does not say whether the GB/s are per-direction.

### 2.4 C2C link physical layer [P, §2.3 + footnote 2]
- "The C2C links use low-swing differential signaling operating **up to 30 Gbps** over 34 AWG cables, with the longest cable being **0.75 meter** within the node."
- Footnote 2: "in general we operate all the links at the same data rate of **25 Gbps** for both electrical cables within racks and active-optical transceivers between racks, with a combined bandwidth of **100 Gbps across the four lanes** in a link."
- In-rack cables "relatively short (<2m)" low-cost QSFP electrical; active optical cables for rack-to-rack.
- "Each node has **28 internal C2C cables** to fully-connect the eight (8) TSPs ... keep **73% of the cables (44 of 60 cables used by each node)** short and inexpensive using electrical signaling."
- [I] 28 = C(8,2); 60 − 28 = 32 = 8 TSPs × 4 global links; 44 − 28 = 16 = in-rack global cables, consistent with half of a node's 32 global ports being used intra-rack. 100 Gbps/link = 12.5 GB/s per link (direction not stated).
- **No cable propagation delay, SerDes latency, or FEC latency number is given.** Only the HAC-measured link latency (Table 2) and the 722 ns/hop all-reduce figure (§5.6).

---

## 3. Findings: deterministic C2C across plesiochronous chips (§3)

### 3.1 Overview [P, §3]
- "A multi-TSP system relies on three mechanisms to establish and maintain synchrony: i) a per-TSP collection of **hardware-aligned counters** that are continuously (**every 256 cycles**) exchanged to maintain a global consensus time; ii) a procedure for **initial program alignment** that utilizes the links to ensure every TSP begins executing its instructions simultaneously; iii) a **runtime resynchronization** process to account for individual TSP clock drift during long-running computations."
- Communication uses "explicit send or receive instructions at specific times"; dependencies expressed as a DAG with "temporal deadlines on the operand arrival times" (§3).

### 3.2 ISA support — Table 1 [P] (verbatim descriptions)
| Name | Description (Table 1) |
|---|---|
| HAC | hardware aligned counter |
| SAC | software aligned counter (typo "couner" in paper) |
| SYNC | intra-chip pause instruction |
| NOTIFY | intra-chip global signal to functional units to restart execution |
| DESKEW | pause instruction until HAC overflows |
| TRANSMIT | instruction to send notification to child through C2C link |
| RUNTIME_DESKEW t | delay TSP for t ± δt |

Also used in Fig 7(b)/text: **RECV** (receive), Gather, IFetch, "Xmit", NOP. S1 slide 25 [S] lists C2C-unit instructions: "Deskew — Manage skew across plesiochronous links"; "Send — Send a 320-byte vector"; "Receive — Receive a 320-byte vector, emplacing it in main memory". S1 slide 41 [S] repeats Table 1 (SYNC described as "Chip-wide synchronization to align all instruction queues (ICUs) on-chip").

### 3.3 Hardware Aligned Counter (HAC) [P, §3.1, Fig 7(a)]
- "Each TSP maintains a free-running internal hardware aligned counter (HAC) with a low (**< 256 cycle**) overflow period." Footnote 3: "The HAC period is also referred to as an **epoch**."
- Footnote 4: "the period is the epoch length or **252 clock cycles**. The HAC is an **8-bit counter, but 4 values are reserved for special control codes**." (Note: §3 also says "every 256 cycles" — the paper is internally loose; 252 is the precise figure.)
- **Latency characterisation:** a TSP transmits its HAC value, the peer reflects it back; "it is compared with the internal free-running HAC, with the difference being the link latency (modulo a multiple of the HAC period)". Fig 7(a) annotation: **L = [HAC0(t2) − HAC0(t1)] / 2** (i.e., one-way latency = half the round trip). "This procedure is repeated until we have an acceptable confidence in the estimate of mean latency and variance within the system tolerance."
- **Table 2** (HAC latency characterisation of 7 intra-node C2C links, 100K iterations; units not printed, presumably clock cycles [I]):

| link | min | mean | max | std |
|---|---|---|---|---|
| A | 209 | 216.87 | 228 | 2.93 |
| B | 210 | 216.87 | 227 | 2.88 |
| C | 209 | 216.41 | 226 | 2.66 |
| D | 210 | 216.47 | 226 | 2.71 |
| E | 209 | 216.27 | 226 | 2.78 |
| F | 209 | 216.48 | 225 | 2.63 |
| G | 211 | 217.35 | 228 | 2.84 |

  Not stated whether these are one-way (L) or round-trip values [gap]. [I] At 900 MHz, 217 cycles ≈ 241 ns. Spread min–max ≈ 16–19 cycles; σ ≈ 2.6–2.9 cycles.
- **Pairwise alignment:** parent T0 periodically sends HAC0 to child T1; "its value plus the latency L is compared to HAC1. The difference represents initial misalignment from continual clock drift. The value of HAC1 is adjusted to reduce the difference (**the maximum adjustment rate is configurable**). After a sufficient number of iterations of this process (approximately bounded by the period of the HAC counters), the two counters HAC0 and HAC1 will converge within a neighborhood determined by the jitter of the link latency." Fig 7(a): misalignment = HAC1(t4) − [HAC0(t3) + L].
- **Multi-hop:** "a **spanning tree** of parent/child HAC relationships is established to maintain a common HAC reference time distributed across the network."
- No numeric value is given for the max adjustment rate, convergence time, clock ppm tolerance, or residual skew [gap].

### 3.4 Initial program alignment [P, §3.2, Fig 7(b)]
- SYNC/NOTIFY are chip-wide only (shared clock + deterministic control path); multi-TSP needs the HAC.
- **DESKEW**: "When a functional unit executes a DESKEW, it will pause issuing subsequent instructions on that functional unit until the next time the HAC overflows or the epoch boundary."
- Procedure: at t1 the child sits in a polling loop (Fig 7(b): Recv, Gather, IFetch, Deskew repeated as a "sync loop"); "at each epoch boundary (shown as HAC=0), the child device will wait to receive a vector from the parent." At t2 parent does **DESKEW then TRANSMIT** ("Xmit", then NOP); the TRANSMIT "happens at an epoch boundary and the vector arrives at the child at some time t3. This vector will be consumed by the RECV instruction that will issue following the next epoch boundary following t3. This will cause the child device to exit the synchronization loop at **⌊L/period⌋ + 1 clock epochs** following the transmit ... at time t4. Finally, both the parent and child device will issue a (chip-local) NOTIFY instruction at time t4 to begin synchronized computation."
- Multi-hop overhead: "**(⌊L/period⌋ + 1) ∗ h total cycles**, where L the maximum single-link latency and h the height of the spanning tree." (Units as printed say "cycles" though the expression counts epochs — likely means epochs × period [I].) "this overhead occurs only at the start of a distributed inference."
- [I] With L ≈ 217 < 252, ⌊L/period⌋+1 = 1 epoch per hop.

### 3.5 Runtime deskew / SAC [P, §3.3]
- "The SAC is a free-running counter with the same period as the HAC. However, unlike the HAC, it is not updated to correspond with upstream HAC peers ... The delta between a TSP's SAC and HAC, thus represents the accumulated drift of the 'local' view of time (i.e. SAC) since the last synchronization and the 'global' view of time (i.e., HAC)."
- **RUNTIME_DESKEW t**: "takes a single parameter: a target number of clock cycles to stall. When executed, the TSP will delay for the target number of cycles plus or minus δt, the signed difference of the HAC and SAC. In the event that δt is positive, the 'local' time is faster than the 'global' time ... the TSP will stall for the target number of cycles plus δt, and vice-versa if the difference is negative." After it, "the accumulated global error is reduced to the link jitter."
- "This RUNTIME_DESKEW instruction is scheduled to be executed on each TSP within the network at the same time. While it is executing, the other functional units on each TSP are quiesced by performing a SYNC instruction to park each ICUs, until it is subsequently awakened via a NOTIFY instruction."
- Cost: "A lighter-weight (approximately **1 epoch**) runtime resynchronization process" (§3.2).
- **Not stated:** how often RUNTIME_DESKEW must be inserted, oscillator ppm, allowed drift tolerance [gap].

### 3.6 "Global clock" concept [P]
- §1: "ISA 'runtime deskew' instruction support to maintain the **illusion of a synchronous, lock-step system**"; §3.2: "common (periodic) HAC reference can be combined to provide the illusion of a shared clock across the entire system"; §7: "the illusion of a globally synchronous distributed system." S1 slide 40 [S]: "No globally synchronized clock across the TSPs → need a 'global' clock"; slide 42 [S] illustrates HACs initially independent and drifting "due to different reference clocks".

---

## 4. Findings: software-scheduled networking (SSN) (§2.3, §4)

### 4.1 Principles [P, §4]
- "The exact timing (in cycles) to inject a vector at the source TSP, as well as the exact cycles data will arrive at a destination TSP, can all be resolved at compile time." "all contention for both functional units and network links are resolved at compile-time."
- Five design elements (§4 list): (A) deterministic traffic pattern from static graph analysis; (B) scheduling of communication, not routing; (C) deterministic routing incl. non-minimal routes; (D) no hardware arbitration, explicit software flow control; (E) FEC to avoid reactive link-layer replay.

### 4.2 Flow control [P, §2.3, §4.4]
- "the hardware is disallowed from asserting **back pressure** ... software explicitly schedules vectors on each physical link in the system taking into account the channel bandwidth and latency of each channel to ensure we never **overflow** the transmitter or **underflow** the receiver." (§2.3)
- "we use the local SRAM storage on each TSP to provide intermediate buffering of the tensor's individual vectors and in this way, a **vector is the flow control unit (flit)**. Since the network path is fully deterministic, a tensor consisting of one or more vector flits can be scheduled using **virtual cut through** flow control since the receiving TSP can immediately begin sending vectors to the next-hop." (§2.3)
- "no conventional 'queuing' or buffers ... aside from **very shallow buffers at the interface between the C2C logic and TSP core clock boundaries**." (§4.4) — depth not given.
- **No virtual channels**: packets are scheduled in advance, "do not hold on to the resource while requesting another resource and routing deadlock cannot occur – and VCs are not needed." (§4.4)
- S1 slide 41 [S]: "Links are 'paced' using software to avoid overflow / underflow".

### 4.3 Routing: "scheduled, not routed" [P, §4.2, §4.3, Fig 8, Fig 10]
- No hardware lookup tables: "the multi-TSP system explicitly controls and schedules the hop-by-hop path through the network by orchestrating a sequence of **send and receive instructions** on the source and destination nodes" (§4.2). Conclusion calls it "source-based, software-scheduled routing" (§7).
- Push model: Fig 9(b) — remote reads become one-way pushes; "eliminating the 'request' leg of the protocol traffic" (§4.2).
- **Deterministic load balancing:** spreading "the 320-byte vectors of a larger tensor across the C2C links in the path"; non-minimal routing used to spread offered traffic across multiple injection links (§4.3). "We use the tensor's physical data volume (i.e., the product of a tensor's dimensions H×W×C) ... and based on the tensor size we select the number of links to spread the traffic across." (§4.3)
- Fig 10 analysis (8 fully connected TSPs: 1 minimal + 7 non-minimal paths per pair): "for a message size smaller than **8kB**, there is no benefit of non-minimal routing"; crossover depends on message size, number of non-minimal paths, and per-hop latency (§4.3). No explicit algorithm or cost function is given.

### 4.4 Vector/packet format [P, Fig 11, §4.4]
- "Packet format of a 320-byte vector has an encoding efficiency of **97.5% (320/328 bytes)**." (Fig 11 caption); "only **2.5% encoding overhead**" (§4.4).
- Fig 11 layout (8-byte flits): header flit = Start, Sync, Type (data, CSR, Sync, Ctrl), DATA[4:0]; body flits DATA[12:5], DATA[20:13], ...; tail flit = DATA[319:317], IDLE, IDLE, IDLE, End.
- [I] 5 + 39×8 + 3 = 320 data bytes → 41 flits × 8 B = 328 B. No destination address in the packet ("eliminates packet headers/footers", §1; S1 slide 45 [S]: "No hardware flow control, no virtual channel information").
- [I] At 12.5 GB/s per link, 328 B ≈ 26.2 ns ≈ 23.6 cycles at 900 MHz per vector per link (direction/duplex not stated).

### 4.5 Error handling: FEC, not retry [P, §4.5]
- Link-layer retry "introduces non-deterministic behavior since it changes the expected arrival time of the retransmitted packets". Instead: "**forward error correction (FEC)** on every link to correct simple transmission errors and detect uncorrectable burst errors." Critical errors are flagged so "the runtime system [can] 'replay' the inference (i.e. a software replay)".
- SECDED on memory, datapaths, instruction buffers; single-bit errors corrected in situ, multi-bit detected (§4.5). FEC code type/latency not given.

### 4.6 Per-hop latency [P, §5.6]
- "The worst-case latency in a 256-TSP Dragonfly uses only three (3) hops and thus an all-reduce across all TSPs has a pipelined network latency of **722 ns per hop ×3 hops = 2,166 ns, or ≈2.1 µsec**."
- Abstract: global memory "accessible in **less than 3 microseconds** of end-to-end system latency" (for up to 10,440 TSPs).
- [I] 722 ns ≈ 650 cycles @ 900 MHz — much larger than the ~217-unit Table 2 value; the paper does not reconcile these (722 ns may include SRAM/stream-path traversal on the intermediate TSP).

---

## 5. Findings: compiler's role in global scheduling [P]
- Model decomposition "is automated by the compiler to auto-scale the workload across a desired number of TSP elements. The compiler partitions the workload into smaller sub-tasks and maps them to individual TSPs ... This mapping process induces the traffic pattern" (§4.1). Supports model (pipelined) parallelism and data parallelism.
- Pipelined model parallelism: "we compute the precise execution time of each pipe stage's sub-task" — no dynamic profiling (§4.1). "The compiler will overlap as much compute and communication to effectively hide the C2C link latency." (§4.1)
- Compiler "orchestrates data movement based on global information across time and space to eliminate conflicts for shared output ports" (§4.2).
- Software stack (§5.1, Fig 12): entry via PyTorch/TensorFlow or a **bare-metal programming interface**; both share the **assembler and runtime**. "When targeting multiple TSPs, the input model is either automatically partitioned by the compiler or manually by the programmer, and an **individual TSP binary is compiled and prepared for each TSP**." The runtime emplaces program collateral and synchronizes (per §3) "so that we launch the inference simultaneously across all cooperating TSPs." S1 slide 56 [S] stack: CoreML/PyTorch/TensorFlow/Keras/... → Model Converters → ONNX → MLIR → Parallelizing Compiler → Assembler → Runtime; Bare-metal Programming Interface alongside.
- Matmul decomposition (§5.2): column-wise weight splits (concatenate) vs row-wise splits (reduce partial products); "try to cluster row-wise splits in a single node"; reduction within node then across neighbour nodes.
- Load balancing lesson (§5.6, Fig 20): initial compiler partitioned "by balancing only FLOPs"; optimized compiler "carefully considers data movements" → "approximately **26%** improvement in realized throughput" for BERT-Large on 4 TSPs.
- Hierarchical all-reduce (§5.6): three stages — 8-way intra-node full connection; the four global links between nodes; 8-way intra-node again.
- **No** algorithmic detail (ILP, list scheduling, heuristics), no named compiler pass or API names other than "bare-metal API" [gap].

---

## 6. Findings: reported results [P, §5]
- **Clock assumption in eval:** "each TSP operating at **900MHz** with PCIe Gen4 ×16 host CPU interface" (§5.2, for Fig 14).
- **Single-chip matmul (Fig 13):** [2304×4096]×[4096×N], N = 1376..3500; "at least **80% utilization** consistently" vs A100.
- **Distributed matmul (Fig 14):** [800×32576]×[32576×8192]; 8 column splits × N=1..13 row splits; latency decreases with more TSPs (numbers only in figure, not extracted).
- **Large matmul (Fig 15):** FP16 TFLOPs for 100/200/300 TSPs; read from figure ≈ 12k, ≈ 23–29k, ≈ 23–43k TFLOPs across N = 200k–650k [figure-read, approximate]. Text: ">100× more FP16 throughput compared to the peak performance on 432 GPUs achieving approximately 2800 (fp64) TFlops on matrix sizes of 650000×650000" (V100 cluster, ref [17]).
- Input bandwidth example: [100000×100000] weight matrix, column-major tile loading needs ≈ **570 GB/s**, row-major only **3.7 GB/s** (§5.2).
- **AllReduce (Fig 16):** 8-way AllReduce, TSP outperforms A100 at small tensors; matches pin-bandwidth-normalized A100 at large sizes (§5.3). A100 baseline: 8× A100, 300 GB/s NVLink per GPU, nccl-tests bus bw (footnote 5).
- **BERT-Large latency distribution (Fig 17, §5.4):** 4 TSPs in a GroqNode, **24,240 runs**, SQuAD1.1 dev, including PCIe I/O; 5 µs bins; "**99% of inferences return in under 1225 µs, with all of them returning by 1300 µs**". Compiler estimate "within **2%** of the actual measured latency in the majority of cases"; deviation attributed to PCIe transfer invocation time. BERT-Base on 1 TSP: also within 2%. (Fig 17 zoom shows mass in ~1185–1215 µs bins [figure-read].)
- **BERT scaling (Fig 18):** 6/24/48/96 encoders on 1/4/8/16 TSPs; "4 TSPs ... 4× more throughput". (16-TSP bar reads ≈17× normalized [figure-read].)
- **Cholesky (Fig 19, §5.5):** block-cyclic distribution of 320 rows per TSP; speedup **1.2×, 1.4×, 1.5×** for 2, 4, 8 TSPs; **14.9 FP16 TFLOPs on 4 TSPs → 22.4 on 8**; "3× realized throughput compared to the best known results [16]". MXM consumes matrices "at most 160×320" and outputs AB^T; rsqrt is a custom approximation on the VXM.

---

## 7. Single-chip TSP facts restated in this paper (cross-check vs ISCA 2020)
[P]:
- 220 MiB local SRAM per TSP "for parameters and instruction text" (§2, Abstract).
- "functional units are organized as **320-element SIMD** ... into functional slices consisting of a group of **20 tiles**, each of which perform a **16-way SIMD** computation" (§2).
- Vector = 320 bytes (§4.1, Fig 11).
- Matmul sub-ops: "[1×K]×[K×320] sub-operations, where K=[160,320] i.e. the vector lengths of the hardware for FP16 and int8 respectively. Additionally, a TSP can run **two FP16 or four int8 sub-operations each cycle**." (§5.2)
- MXM inputs read from stream registers flowing outward from the central VXM; outputs written to streams flowing inward (§5.5).
- SYNC parks ICU issue; NOTIFY delivers a global control signal "(with known latency)" to restart all paused units "on the same clock cycle" (§3.1).
- 900 MHz (eval assumption, §5.2).

[S] (Hot Chips 34 slides):
- Slide 14: "The vector unit (VXM) has 16 PEs per lane **5,120 total**"; "144 Instruction queues"; MXM "320 lanes x 320 features", "Each MXM plane stores 102,400 'weights' 409,600 MACCs"; "Peak of ~750 Tops (Int8Acc32) peak (900 MHz)".
- Slide 30: "**88 independent MEM slices with 8192 addresses (220MB)**"; "A read from a single MEM slice creates a 320Byte stream"; "Can read and write one physical stream (vector) per cycle, from 2 banks".
- Slide 23: "Stream register = one-cycle hop".
- Slide 25: ICU instructions NOP N, Ifetch, Sync, Notify, Config, Repeat n,d; C2C instructions Deskew, Send, Receive (320-byte vectors).
- Slide 54: "**21 superlanes** on-chip" with one spare hidden from the compiler.

---

## 8. Parameters useful for a simulator

| Parameter | Value | Source | Confidence |
|---|---|---|---|
| TSPs per node | 8 | [P] §2.2, Fig 5 | High |
| Links per TSP | 11 = 7 local + 4 global | [P] §2.2 | High |
| Lanes per link | 4 | [P] §2.2 | High |
| Lane rate (operating) | 25 Gbps (capable up to 30 Gbps) | [P] §2.3 + fn 2 | High |
| Link bandwidth | 100 Gbps (= 12.5 GB/s [I]); duplexity not stated | [P] fn 2 | High (value) / Med (per-direction) |
| Intra-node topology | fully connected (K8) via 28 cables; alt: radix-8 torus, 3 physical links/direction | [P] §2.2, §2.3, §4.4, Fig 6 | High |
| Node-as-group virtual router radix | 32 ports | [P] §2.2 | High |
| Max single-global-hop system | 33 nodes = 264 TSPs, 3-hop diameter (minimal) | [P] §2.2 | High |
| Nodes per rack | 9 (incl. 1 hot spare) → 72 TSPs | [P] §2.2, §4.5 | High |
| Rack port split | 288 global ports: 144 intra-rack (double-connect), 144 inter-rack | [P] §2.2 | High |
| Max system | 145 racks, 10,440 TSPs, ≤5-hop diameter | [P] §2.2 | High |
| Global BW per TSP | ~138 GB/s (≤8), ~88 (→16), 50 (16–264), ~14 (>264) | [P] Fig 2, §1 | High (figure annotations) |
| Cable lengths | ≤0.75 m in node (34 AWG); <2 m in rack (QSFP electrical); optical between racks | [P] §2.3 | High |
| Flit / flow-control unit | one 320-byte vector | [P] §2.3, §4.1 | High |
| Wire format | 328 B per vector (41 × 8-byte flits), 97.5% efficiency | [P] Fig 11; flit count [I] | High / Med |
| Flow control | none in HW: no back-pressure, no arbitration, no VCs; virtual cut-through; SW-paced | [P] §2.3, §4.4 | High |
| Buffering | only shallow clock-crossing buffers at C2C/core boundary; SRAM for intermediate hop buffering | [P] §2.3, §4.4 | High (depth unknown) |
| Error handling | FEC per link; no link-layer retry; software replay of inference on uncorrectable error | [P] §4.5 | High |
| HAC | 8-bit, 4 codes reserved → epoch = 252 cycles | [P] fn 4 | High |
| HAC exchange interval | "every 256 cycles" (likely = 1 epoch) | [P] §3 | Med (inconsistent w/ 252) |
| Measured intra-node link latency | mean 216.3–217.4, min 209–211, max 225–228, σ 2.6–2.9 (units presumably cycles) | [P] Table 2 | High (values) / Low (units, one-way vs RTT) |
| Latency estimator | L = (HAC0(t2) − HAC0(t1)) / 2 (half round trip), mod epoch | [P] Fig 7(a), §3.1 | High |
| HAC adjustment | HAC1 nudged by misalignment HAC1 − (HAC0 + L); rate configurable; converges ~1 HAC period | [P] §3.1 | High (mechanism) / Low (rate) |
| Sync topology | spanning tree of parent/child HAC links | [P] §3.1 | High |
| Initial alignment cost | (⌊L/period⌋+1) epochs per tree level × h | [P] §3.2 | High |
| Runtime deskew cost | ≈ 1 epoch; stall = t ± (HAC − SAC) | [P] §3.2, §3.3 | High |
| Per-hop network latency (all-reduce, pipelined) | 722 ns | [P] §5.6 | High (value) / Low (what it includes) |
| End-to-end global memory latency | < 3 µs at full scale; ≈2.1 µs 3-hop in 256-TSP | [P] Abstract, §5.6 | High |
| Non-minimal routing break-even | ~8 kB message (in 8-TSP fully connected node) | [P] §4.3, Fig 10 | Med |
| Clock frequency | 900 MHz (eval assumption) | [P] §5.2; [S] slide 14 | High |
| Per-TSP SRAM | 220 MiB | [P] Abstract, §2 | High |
| MEM slices | 88 × 8192 addresses | [S] slide 30 | Med |
| SIMD organisation | 320 lanes = 20 superlanes × 16; 21 physical superlanes incl. 1 spare | [P] §2; [S] slide 54 | High |
| MXM sub-op | [1×K]×[K×320], K=160 FP16 / 320 int8; 2 FP16 or 4 int8 sub-ops per cycle | [P] §5.2 | High |
| BERT-Large 4-TSP latency | p99 < 1225 µs, max ≤ 1300 µs over 24,240 runs; compiler estimate within 2% | [P] §5.4, Fig 17 | High |
| Cholesky scaling | 1.2/1.4/1.5× at 2/4/8 TSPs; 14.9 → 22.4 FP16 TFLOPs (4→8) | [P] §5.5 | High |
| Compiler data-movement-aware partitioning gain | ~26% (BERT-Large, 4 TSPs) | [P] §5.6 | High |

---

## 9. Not found / unverified

Not stated in the primary paper (searched full text):
- **Units of Table 2** (cycles assumed) and whether values are one-way L or round-trip.
- Breakdown of the 722 ns per-hop latency (SerDes, FEC, cable flight time, clock-domain crossing, SRAM staging); no cable propagation delay figures.
- Whether link bandwidth (100 Gbps) and Fig 2 GB/s figures are per direction or bidirectional; whether links are full duplex (presumably yes, unverified).
- Clock oscillator tolerance (ppm), allowed drift budget, how frequently RUNTIME_DESKEW is inserted, the HAC max adjustment rate, residual post-alignment skew in cycles.
- Depth of the C2C/core clock-boundary buffers; number of C2C send/receive streams or how many links can be driven concurrently per cycle.
- FEC code type, FEC latency, post-FEC error rates.
- Compiler scheduling algorithm details (no ILP/heuristic description), cost model for choosing number of non-minimal paths, how link schedules are represented in the binary.
- Exact Dragonfly global-link wiring pattern between racks/nodes (which node port connects to which); Fig 6 shows inter-node links only for Node 0.
- Numeric values behind Figs 13–16 curves (only approximate figure readings given above).
- Deployment status: the paper describes a design scaling to 10,440 TSPs; it does not claim a 10,440-TSP system was built or measured. Largest measured runs in the paper: 300-TSP matmul (Fig 15), 16-TSP BERT (Fig 18), 8-TSP Cholesky/AllReduce.

Unverified / conflicting claims:
- aiwiki.ai search snippet claims "16 integrated C2C links per chip". **Not opened; unverified.** It conflicts with the paper's 7 local + 4 global = 11 links per TSP in this system (§2.2). It is possible that the chip has more C2C ports than the card exposes ("packaging constraints of a PCIe card limits the number of links that can be exposed", §2.2) — that would be my recollection-level speculation, not verified this session.
- The HC34 slide claim "Interfaces the full 64 stream bandwidth @ 80TBps" (slide 30) was read in text form only and not cross-checked.
- Patent US 12,277,444 B2 (same title) likely contains more detail (e.g. HAC/SAC, counters), but its text was not read this session.
