# Groq TSP Multiprocessor: notes on Abts et al., ISCA 2022

**Paper:** D. Abts, G. Kimmell, A. Ling, J. Kim, M. Boyd, A. Bitar, S. Parmar, I. Ahmed, R. DiCecco, D. Han, J. Thompson, M. Bye, J. Hwang, J. Fowers, P. Lillian, A. Murthy, E. Mehtabuddin, C. Tekur, T. Sohmers, K. Kang, S. Maresh, J. Ross. "A Software-defined Tensor Streaming Multiprocessor for Large-scale Machine Learning." ISCA '22, June 18–22 2022, New York. pp. 567–580. DOI 10.1145/3470496.3527405.

## 0. Sources and how they were accessed

| Tag | Source | Status |
|---|---|---|
| **[P]** | Full paper PDF (14 pages), downloaded from `https://cdn.sanity.io/files/chol0sk5/production/81d0c45ed70a10f1804bbd82f2d0076af1186ff0.pdf` (a web search linked it as the paper). The PDF metadata gives the title above, "LaTeX with acmart 2022/04/09", and a creation date of 2022-05-23. The text has the ACM permission block, ISBN 978-1-4503-8610-4/22/06 and the DOI. I believe it is the camera-ready version, but I could not confirm who runs that CDN bucket. Sanity is a CMS, and Groq's site appears to use it, but this is unverified. | **Read in full** (text extracted with `pdftotext`) |
| **[HC]** | Abts, "The Groq Software-defined Scale-out Tensor Streaming Multiprocessor", Hot Chips 34 slides (2022), `https://hc34.hotchips.org/assets/program/conference/day2/Machine%20Learning/HotChips34%20-%20Groq%20-%20Abts%20-%20final.pdf` (69 slides) | Read. **SECONDARY.** Same author and same material, but it is a talk, not the paper. Slide numbers are the page numbers printed on each slide. |
| — | Groq-hosted PDFs `groq.com/wp-content/uploads/2024/02/GroqISCAPaper2022_...pdf` and `wow.groq.com/wp-content/uploads/2023/05/...-1.pdf` | **HTTP 404** (Nov 2026) |
| — | ACM DL `https://dl.acm.org/doi/pdf/10.1145/3470496.3527405` | **HTTP 403** to both curl and WebFetch. Semantic Scholar and OpenAlex list it as open access ("bronze"). |
| — | Wayback Machine copies | **HTTP 429** (blocked as bot traffic); not reachable |
| — | Patents US12277444B2 / US20230161621A1 (same title) | Found in search results only, **not read** |

The paper is not on arXiv (no arXiv ID in Semantic Scholar's externalIds).

**Re-check of 2026-11-17 (independent verifier).** [P] and [HC] were downloaded again from the two URLs above and every quotation, table value, section number and slide number below was compared with the extracted text. The corrections made are: the wording of design item (E) in §3.1, a dropped citation marker in the §3.2 quotation, the slide number for the C2C instruction list in §2.1 (25, not 26), the wording of the AllReduce row in §5, and the three "from memory" items in §7, which other notes in this folder now source. Everything else matched.

Citation convention: "§x.y" is a paper section, "Fig n" or "Tab n" is a paper figure or table, "fn n" is a paper footnote. All of these refer to [P] unless marked [HC].

---

## 1. Multi-chip scaling: topology and packaging

### 1.1 Topology
- The topology is a "software-defined Dragonfly". The TSP is both endpoint and switch: "The TSP acts as both a processing element (endpoint) and network switch for moving tensors across the communication links." (Abstract)
- It is a direct, "glueless" network with no external routers. "the direct network is extended to create a 'glueless' multiprocessor by combining the processing endpoints and the routers (Fig 4(c)) – thus, directly connect TSPs" (§2.1). Because of this, "the router node bandwidth effectively becomes processing endpoint injection bandwidth" (§2.1).
- Dragonfly was chosen because "by using a collection of routers as a group, a virtual high-radix network can be created" without the intermediate switches a fat-tree needs (§2.1). The paper names Flattened Butterfly and HyperX as alternatives and says their scalability is limited when node radix is small (§2.1).
- **Links per TSP:** "The pin-bandwidth from each TSP is partitioned into 7 'local' links and 4 'global' links" (§2.2). That is 11 links, each of 4 lanes: "Each C2C link consist of four (4) lanes and thus in theory, the radix can be increased to 11 × 4 = 44 ports" (§2.2). PCIe-card packaging limits how many links can leave the node (§2.2).
  - *Discrepancy (secondary):* [HC] slide 65 mentions "the 16 directly connected links on each TSP". The paper describes 11 links in use (7+4). Neither of these two sources explains the difference. The ISCA 2020 paper, as recorded in `01_tsp_isca2020.md` §11, gives the chip "sixteen (16) ×4 links", and the 2026 SHIP paper says LPUv1 has "11 logical ports" (`03_recent_lpu.md` §4.1). So the likely reading is 16 physical ×4 links on the chip, of which this topology uses 11. That is an inference from combining sources, not a statement in any one of them.
  - *Later deployments differ (cross-reference):* SHIP (MLSys 2026) describes the production LPUv1 network as "QuadFour", a linear sequence of 8-LPU nodes each linked to its four nearest nodes forward and backward, with "300 ns per LPU-to-LPU hop" (`03_recent_lpu.md` §4.3). It does not use the word Dragonfly. The topology in this note is what the 2022 paper proposes and partly evaluates, not necessarily what was deployed.
- **Node as a group:** the 7 local links fully connect 8 TSPs, which are "within the same SMP coherence domain and can communicate synchronously" (§2.2, Fig 6). Combining the global links of the 8 TSPs (8×4) gives a "32 'virtual' port high-radix router" that acts as a Dragonfly "group" (§2.2).
- **Up to 264 TSPs (33 nodes):** "the TSP system can scale out up to 33 nodes for total of 33×8 = 264 TSPs by providing full connectivity between all of the nodes that results in a three hop topology with minimal routing", with "combined 56 GiBytes of global SRAM" (§2.2, Fig 3). [HC] slide 37 says the same: "32-port 'group' as a building block—scale up to 33 groups in a single global hop".
- **Rack as the group (large systems):** a rack is "nine (9) nodes, each with eight (8) TSPs, interconnected via the four (4) 'global' links per TSP for a total of 32 × 9 = 288 ports". "half (144) of the ports" doubly-connect the 9 nodes in the rack, giving "the proper 2× 'internal speedup' within the local group". "The remaining 144 ports are used to connect to other racks", which gives "up to 145 racks in the maximally configured system or 145 (racks) ×72 (TSPs per rack) for a total of 10,440 TSPs in the largest system with at-most 5 hop diameter using minimal routing (two in the source-rack, one global hop, and two in the destination-rack)." (§2.2)
- **Maximum system:** "up to 10,440 TSPs and more than 2 TeraBytes of global memory accessible in less than 3 microseconds of end-to-end system latency" (Abstract). "maximum system configuration of 145 cabinets for a total of 10,440 TSPs" (§1).
- **Local group as a torus (Fig 6b):** "The local group radix-8 torus topology enables efficient nearest-neighbor communication with adjacent TSPs for inference using pipelined model parallelism. With a radix-8 local group topology, we triple-connect physical links within the torus to increase the nearest-neighbor throughput." (§4.4). *Note:* this is hard to square with the fully-connected 8-TSP node described in §2.2. It may describe an alternative wiring or a logical view. The paper does not explain further.

### 1.2 Bandwidth profile (Fig 2, §1)
- Fewer than 16 TSPs can use the "abundant wire density within the node".
- "systems up to several hundred TSPs can take advantage of about 50 GB/sec of global (bisection) bandwidth per TSP."
- "As system size grows beyond 264 TSPs, the available global bandwidth flattens to about 14 GB/sec of global bandwidth per TSP endpoint." It stays flat up to 10,440 TSPs (§1).
- *Consistency check (derived, not stated):* 4 global links × 100 Gb/s = 400 Gb/s = 50 GB/s, which matches the ~50 GB/s figure.

### 1.3 Packaging hierarchy
- "Four levels of packaging hierarchy, where each chip (a) is fitted with a heat-sink and packaged on a PCIe card (b) and eight TSP cards are co-located within the a shared memory node (c) occupying four rack units (4RU) in the rack (d)." (Fig 5 caption)
- "The basic building block of the system packaging is a 4U chassis enclosure which houses eight TSPs ... referred to as a 'node.'" (§2.2)
- Product names: the paper uses "GroqNode" once: "BERT-Large running on four TSPs within a GroqNode" (§5.4). The names **GroqChip™ → GroqCard™ → GroqNode™ → GroqRack™ → Cloud** appear in [HC] slides 33 and 35 (**secondary**).
- Rack: 9 nodes = 72 TSPs (§2.2). It includes a hot-spare node: "N+1 redundancy by provisioning a hot spare node (Fig 6) in every deployed rack" (§4.5). [HC] slide 36 adds: "Any node can be the 'spare' node".
- Host interface: "each TSP operating at 900MHz with PCIe Gen4 ×16 host CPU interface" (§5.2). This is stated as the assumption for the matmul evaluation.

### 1.4 C2C links: electrical and cabling (§2.3)
- "low-swing differential signaling operating up to 30 Gbps over 34 AWG cables, with the longest cable being 0.75 meter within the node." Intra-node cables "lay flat underneath the shroud used on the 4U enclosure."
- fn 2: "The C2C links support a variety of operating speeds, however, in general we operate all the links at the same data rate of 25 Gbps for both electrical cables within racks and active-optical transceivers between racks, with a combined bandwidth of 100 Gbps across the four lanes in a link."
- Cables within the rack are short (<2 m), "low-cost QSFP (quad-small form package) electrical cables". **Active optical cables** are used for longer rack-to-rack links.
- "Each node has 28 internal C2C cables to fully-connect the eight (8) TSPs with their 7 peers within the node. This allows us to keep 73% of the cables (44 of 60 cables used by each node) short and inexpensive using electrical signaling."
  - *Derived:* 28 internal plus 32 global gives the 60 cables per node. 28 = C(8,2), so there is one cable per TSP pair.

---

## 2. Deterministic C2C links: synchronisation

Source for this whole section: §3 (Table 1, Table 2, Fig 7, fn 3–4).

- **Problem statement:** each TSP "has an independent clock source" (§3.2). The intro calls the links "a set of plesiochronous links" that are deskewed and aligned "to enable a synchronous distributed programming model" (§1). [HC] slide 40 lists the issues: "Link latency variation", "No globally synchronized clock across the TSPs", and "Clock drift".
- **Three mechanisms** (§3): "i) a per-TSP collection of hardware-aligned counters that are continuously (every 256 cycles) exchanged to maintain a global consensus time; ii) a procedure for initial program alignment ...; iii) a runtime resynchronization process to account for individual TSP clock drift".
- Communication uses explicit timed instructions: "we communicate with explicit send or receive instructions at specific times so we can reason about program correctness from this total ordering" (§3). No mutexes are needed for global SRAM.

### 2.1 ISA support (Table 1, verbatim)
| Name | Description |
|---|---|
| HAC | hardware aligned counter |
| SAC | software aligned counter (paper typo: "couner") |
| SYNC | intra-chip pause instruction |
| NOTIFY | intra-chip global signal to functional units to restart execution |
| DESKEW | pause instruction until HAC overflows |
| TRANSMIT | instruction to send notification to child through C2C link |
| RUNTIME_DESKEW t | delay TSP for t ± δt |

The text also uses a **RECV** instruction in the alignment procedure (§3.2). [HC] slide 25 (secondary; the same instruction table as the ISCA 2020 paper's Table I) lists the C2C functional-unit instructions as: "Deskew — Manage skew across plesiochronous links", "Send — Send a 320-byte vector", and "Receive — Receive a 320-byte vector, emplacing it in main memory".

### 2.2 Hardware Aligned Counter (HAC), §3.1
- "Each TSP maintains a free-running internal hardware aligned counter (HAC) with a low (< 256 cycle) overflow period." fn 3: "The HAC period is also referred to as an epoch."
- **Period:** fn 4: "the period is the epoch length or 252 clock cycles. The HAC is an 8-bit counter, but 4 values are reserved for special control codes." *Note:* §3 says the counters are exchanged "every 256 cycles". Use **252 cycles** as the precise epoch.
- **Latency characterisation:** each TSP sends its HAC to its peer, and the peer reflects it back. "it is compared with the internal free-running HAC, with the difference being the link latency (modulo a multiple of the HAC period) (Fig 7(a)). This procedure is repeated until we have an acceptable confidence in the estimate of mean latency and variance."
- **Measured link latency, Table 2** (100K iterations, 7 intra-node links, units are cycles; the clock domain is not stated, but HAC counts clock cycles):

| link | min | mean | max | std |
|---|---|---|---|---|
| A | 209 | 216.87 | 228 | 2.93 |
| B | 210 | 216.87 | 227 | 2.88 |
| C | 209 | 216.41 | 226 | 2.66 |
| D | 210 | 216.47 | 226 | 2.71 |
| E | 209 | 216.27 | 226 | 2.78 |
| F | 209 | 216.48 | 225 | 2.63 |
| G | 211 | 217.35 | 228 | 2.84 |

  Summary: min 209, mean about 216–217, max 228, std about 2.6–2.9 cycles. The observed spread is about 19 cycles (min to max).
- **Alignment (parent/child):** after characterisation, T0 and T1 with mean latency L are set up as parent and child. "When the instantaneous value of HAC0 is received by T1, its value plus the latency L is compared to HAC1. The difference represents initial misalignment from continual clock drift. The value of HAC1 is adjusted to reduce the difference (the maximum adjustment rate is configurable). After a sufficient number of iterations of this process (approximately bounded by the period of the HAC counters), the two counters HAC0 and HAC1 will converge within a neighborhood determined by the jitter of the link latency."
- **Multi-hop:** "a spanning tree of parent/child HAC relationships is established to maintain a common HAC reference time distributed across the network."
- **Single-chip SYNC/NOTIFY recap:** SYNC pauses issue on the independent instruction streams. One unit then issues NOTIFY, which is "a global control signal (with known latency)" that restarts all paused units "on the same clock cycle". This "serves as the software-controlled time reference" (§3.1).

### 2.3 Initial program alignment, §3.2 (Fig 7b)
- "When a functional unit executes a DESKEW, it will pause issuing subsequent instructions on that functional unit until the next time the HAC overflows or the epoch boundary."
- Procedure:
  - At t1 the child enters a polling loop. At each epoch boundary (HAC=0) it waits for a vector from the parent.
  - At t2 the parent runs DESKEW then TRANSMIT, so the TRANSMIT happens on an epoch boundary.
  - The vector arrives at t3 and "will be consumed by the RECV instruction that will issue following the next epoch boundary following t3."
  - The child leaves the loop "at ⌊L/period⌋ +1 clock epochs following the transmit".
  - At t4 both parent and child issue a chip-local NOTIFY "to begin synchronized computation".
- **Multi-hop overhead:** "(⌊L/period⌋ + 1) ∗ h total cycles, where L the maximum single-link latency and h the height of the spanning tree. Note that this overhead occurs only at the start of a distributed inference." *Note:* the formula is written as "cycles", but each factor of (⌊L/period⌋+1) counts epochs, so it is presumably ×252 cycles. With L ≈ 228 < 252 this gives 1 epoch per hop (derived).
- After alignment, "A lighter-weight (approximately 1 epoch) runtime resynchronization process" handles skew during execution.

### 2.4 Runtime deskew: SAC, §3.3
- "The SAC is a free-running counter with the same period as the HAC. However, unlike the HAC, it is not updated to correspond with upstream HAC peers, but rather continues to freely count local clock cycles. The delta between a TSP's SAC and HAC, thus represents the accumulated drift".
- "RUNTIME_DESKEW ... takes a single parameter: a target number of clock cycles to stall. When executed, the TSP will delay for the target number of cycles plus or minus δt, the signed difference of the HAC and SAC." If δt > 0 (local time is faster), the TSP stalls for target + δt, and vice versa. The result: "the accumulated global error is reduced to the link jitter".
- "This RUNTIME_DESKEW instruction is scheduled to be executed on each TSP within the network at the same time. While it is executing, the other functional units on each TSP are quiesced by performing a SYNC instruction to park each ICUs, until it is subsequently awakened via a NOTIFY instruction."
- **Not stated:** how often RUNTIME_DESKEW must be scheduled, and the clock ppm tolerance.

---

## 3. Flow control, routing, packet format, errors

### 3.1 Software-scheduled networking (SSN), §4
- "Execution latency of all instructions is known statically (at compile time) and therefore exposed to the compiler via the ISA". "The exact timing (in cycles) to inject a vector at the source TSP, as well as the exact cycles data will arrive at a destination TSP, can all be resolved at compile time." "all contention for both functional units and network links are resolved at compile-time." (§4)
- Design list, verbatim (§4):
  - (A) Deterministic traffic pattern from static graph analysis
  - (B) Scheduling of communication, not routing
  - (C) Deterministic routing, including non-minimal routes
  - (D) No hardware arbitration and explicit (software) flow control
  - (E) Forward-error-correction (FEC) to avoid reactive link-layer replay
- **Scheduled, not routed (§4.2):** there are no hardware routing lookup tables. The system "explicitly controls and schedules the hop-by-hop path through the network by orchestrating a sequence of send and receive instructions on the source and destination nodes". Fig 8 contrasts this with backpressure and re-routing in a conventional network. The conclusion (§7) calls it "source-based, software-scheduled routing".
- **Push model (§4.2, Fig 9):** SSN removes the request leg of a remote read. "data is 'pushed' toward the TSP that will be consuming it". From the program's point of view, local versus remote memory does not matter.

### 3.2 Flow control (§2.3, §4.4)
- "the hardware is disallowed from asserting back pressure ... Instead, software explicitly schedules vectors on each physical link in the system taking into account the channel bandwidth and latency of each channel to ensure we never overflow the transmitter or underflow the receiver." (§2.3)
- "we use the local SRAM storage on each TSP to provide intermediate buffering of the tensor's individual vectors and in this way, a vector is the flow control unit (flit). Since the network path is fully deterministic, a tensor consisting of one or more vector flits can be scheduled using virtual cut through [23] flow control since the receiving TSP can immediately begin sending vectors to the next-hop" (§2.3). So forwarding happens per hop through software, with buffering in SRAM.
- "the interconnection disallows dynamic arbitration ... There is also no conventional 'queuing' or buffers ..., aside from very shallow buffers at the interface between the C2C logic and TSP core clock boundaries." (§4.4)
- **No virtual channels:** "packets or messages are scheduled in advance; thus, the packets do not hold on to the resource while requesting another resource and routing deadlock cannot occur – and VCs are not needed." (§4.4)
- [HC] slide 41 (secondary): links are "'paced' using software to avoid overflow / underflow".

### 3.3 Packet / vector format (Fig 11; §4.1, §4.4)
- The flit is one 320-byte vector: "fine-grained (320 byte) communications between TSPs" (§4.1).
- Fig 11 caption: "Packet format of a 320-byte vector has an encoding efficiency of 97.5% (320/328 bytes)." §4.4: "only 2.5% encoding overhead (Fig 11) of each vector". No other packet headers: "a tensor-based communication protocol that eliminates packet headers/footers" (§1).
- Fig 11 contents, as extracted (the same figure is on [HC] slide 45):
  - header flit (8B): `DATA[4:0]`, `Type (data, CSR, Sync, Ctrl)`, `Sync`, `Start`
  - body flits (8B): `DATA[12:5]`, `DATA[20:13]`, …
  - tail flit (8B): `DATA[319:317]`, `IDLE, IDLE, IDLE`, `End`
  - *Derived, not stated:* a vector is 41 eight-byte link words (41×8 = 328 B). The header carries 5 data bytes plus 3 bytes of start, sync and type. 39 body words carry bytes 5–316. The tail carries 3 data bytes, 3 IDLE bytes and an End byte (7 of its 8 bytes are labelled). So 5 + 39×8 + 3 = 320.
- [HC] slide 45: "No hardware flow control, no virtual channel information, etc."
- **Not stated:** the PHY line code (e.g. 64b/66b), FEC overhead, and whether the 328 B includes FEC parity.

### 3.4 Non-minimal routing and deterministic load balancing (§4.3, Fig 10)
- "we are spreading the 320-byte vectors of a larger tensor across the C2C links in the path between the source and destination TSP ... using 'non-minimal' routing to spread the offered traffic across multiple injection links". This "avoids any end-to-end reordering of hardware-based adaptive routing".
- Unlike hardware Dragonfly, SSN uses non-minimal routing even for a single source-destination pair, to gain bandwidth. The paper says this "requires non-minimal routing to be bandwidth-aware" (§4.3).
- **The decision rule:** "We use the tensor's physical data volume (i.e., the product of a tensor's dimensions H×W×C) as the data volume being communicated, and based on the tensor size we select the number of links to spread the traffic across." (§4.3)
- Fig 10 analysis: 8 fully connected TSPs, so each pair has 1 minimal and 7 non-minimal paths. "for a message size smaller than 8kB, there is no benefit of non-minimal routing". The benefit grows with message size and with path count. "The actual crossover point ... is a function of the message size, the number of non-minimal paths, and per-hop latency (not shown)."
- Collectives (§5.6): "We use non-minimal routing and per-device compute capacity to efficiently distribute and accumulate partial reductions bidirectionally."

### 3.5 Error handling (§4.5)
- There is no link-layer retry, because it "changes the expected arrival time of the retransmitted packets". Instead, "we use forward error correction (FEC) on every link to correct simple transmission errors and detect uncorrectable burst errors."
- "We route packets hop by hop through the network, correcting any transmission errors in situ, and flag any critical errors that require the runtime system to 'replay' the inference (i.e. a software replay) to determine if the fault is transient ... or persists after a retry and requires physical intervention (e.g., to replace a marginal cable, power supply unit, or TSP card)".
- "error correction of all single-bit errors (SBEs) ... and detect all multi-bit errors (MBEs) so that the runtime software can replay the inference on a set of known good hardware". SECDED is used "extensively throughout the TSP's memory system, data paths, and instruction buffers".
- **N+1 redundancy:** one hot-spare node per rack (11% overhead). Alternatively, one spare per system, e.g. "a 33 node system with four racks would have 1 of 33 nodes as the spare (reducing the overhead from 11% to 3%, leaving 32 nodes (256 TSPs)". The Dragonfly is "both edge and node symmetric", so the network stays fully connected when a node is swapped out.
- [HC] slides 54, 60 (secondary): "21 superlanes on-chip", one of them a spare hidden from the compiler. "One-shot replay on an error". The ISA has ADD/SUB/MUL `_SAT` and `_MOD` variants, so arithmetic exceptions are decided at compile time.

---

## 4. The compiler's role in global scheduling

- **Static graph:** "the static computation graph can be expressed as a series of dependencies that impose temporal deadlines on the operand arrival times of tensors being communicated. We express these dependencies as a DAG (directed acyclic graph) to explicitly schedule the communication traffic." (§3)
- **What is known at compile time:** "For most of the workloads that multi-TSP targets, the communication pattern, both in space and in time, are known a-priori" (§4.1). All instruction latencies are known, and so are link latencies after characterisation (§4, §3.1).
- **Partitioning:** "Model decomposition is automated by the compiler to auto-scale the workload across a desired number of TSP elements. The compiler partitions the workload into smaller sub-tasks and maps them to individual TSPs ... This mapping process induces the traffic pattern" (§4.1). Both model parallelism ("distributing different layers across TSPs") and data (mini-batch) parallelism are supported (§4.1).
- **Pipeline parallelism:** "we compute the precise execution time of each pipe stage's sub-task and exchange activations between the layers of each stage ... we know the exact execution time of each stage (to the clock cycle) and therefore do not require dynamic profiling" (§4.1).
- **Overlap:** "The compiler will overlap as much compute and communication to effectively hide the C2C link latency." The scheduler can trade compute against communication to control "the surface-to-volume characteristics" (§4.1).
- **Alignment with packaging:** the intro says "the parallel decomposition strategy is aligned with the system packaging hierarchy in terms of racks, nodes, and eventually the PEs" (§1). For matmul, "we try to cluster row-wise splits in a single node to leverage the Dragonfly topology" (§5.2).
- **Software stack (§5.1, Fig 12):** entry points are PyTorch, TensorFlow or a bare-metal API. The compiler and the bare-metal API share the assembler and runtime. "When targeting multiple TSPs, the input model is either automatically partitioned by the compiler or manually by the programmer, and an individual TSP binary is compiled and prepared for each TSP". The runtime loads all binaries and synchronises them (§3) "so that we launch the inference simultaneously". [HC] slide 56 (secondary) shows Model Converters → ONNX → MLIR → Parallelizing Compiler → Assembler → Runtime. **The paper itself names no IR.**
- **Load-balancing lesson (§5.6, Fig 20):** the "initial (unoptimized) compiler implementation ... partitioned the workload by balancing only FLOPs". The optimised compiler "carefully considers data movements to exploit the spatial organization of the TSP", for "approximately 26% improvement in realized throughput" on BERT-Large over 4 TSPs.
- **Scheduling algorithm:** the paper never describes it beyond the statements above (the DAG, link pacing by bandwidth and latency, link count chosen from tensor size). There is no pseudo-code.
- [HC] slide 65 (secondary): "Only a handful of cycles to Read(vector)->Send(vector)".

### 4.1 Single-chip recap as stated in this paper (useful cross-check)
- "220 MiBytes of local storage for parameters and instruction text" (§2, Abstract). Global memory is "logically shared, but physically distributed SRAM" (Abstract).
- "functional units are organized as 320-element SIMD ... into functional slices consisting of a group of 20 tiles, each of which perform a 16-way SIMD computation" (§2). So 20 × 16 = 320.
- The collection of functional units "act as a single logical core which is scheduled statically" (§3). ICUs are "parked" by SYNC (§3.3).
- Matmul decomposition: "[1× K]×[K × 320] sub-operations, where K=[160,320] i.e. the vector lengths of the hardware for FP16 and int8 respectively. Additionally, a TSP can run two FP16 or four int8 sub-operations each cycle." (§5.2)
- Matmul unit: "consumes two matrices A and B ... with dimensions at most 160×320, and generates the output ABᵀ. The inputs are read from stream registers flowing outward, away from the vector processing unit in the center of the chip, and the output is written to stream registers flowing inward" (§5.5).
- Clock: "each TSP operating at 900MHz" (§5.2).
- **Secondary single-chip numbers ([HC], not in the paper):**
  - VXM "16 PEs per lane 5,120 total" (slide 14).
  - MXM "320 lanes x 320 features", 409,600 MACCs; "~750 Tops (Int8Acc32) peak (900 MHz)" (slide 14).
  - "144 Instruction queues" (slides 14, 68).
  - "88 independent MEM slices with 8192 addresses (220MB)"; "80TBps" across "the full 64 stream bandwidth" (slide 30).
  - SRFs "(32 x138-bit) east and west for a total of 64 320-byte stream registers on-chip", with "45 SRF stations across the superlane" (slide 57). *Note:* 138 bits differs from the "9-bit ECC, 137-bits in total" that `01_tsp_isca2020.md` §6 records from the 2020 paper (128 data bits + 9 check bits = 137). Neither source explains the extra bit.
  - MEM: "A read from a single MEM slice creates a 320Byte stream; a write terminates a stream" (slide 30). This is the only statement in any source read for this folder that a MEM Write ends the stream it stores.
  - "Stream register = one-cycle hop" (slide 24).
  - MXM "Loads 320B x16 in 20 cycles", "20 cycle execution" (slide 28).
  - Networking "480 GB/s bandwidth" (slide 16; 16 links × 4 lanes × 30 Gb/s = 240 GB/s per direction, so this is presumably bidirectional at 30 Gb/s. This is my inference, not stated).

---

## 5. Benchmarks and headline results (§5)

| Workload | Result | Location |
|---|---|---|
| Single-chip GEMM `[2304×4096]×[4096×N]`, N=1376..3500 | "at least 80% utilization consistently at different matrix sizes", compared with A100 | §5.2, Fig 13 |
| Distributed GEMM `[800×32576]×[32576×8192]` | 8 column-wise splits, then row-wise splits N=1..13. Reductions within a node, then between neighbouring nodes. Latency falls as TSPs are added (900 MHz, PCIe Gen4 ×16 assumed) | §5.2, Fig 14 |
| Large GEMM, 100/200/300 TSPs (column-wise splits) | "over 100× more FP16 throughput compared to the peak performance on 432 GPUs achieving approximately 2800 (fp64) TFlops on matrix sizes of 650000×650000" (the comparison mixes FP16 and FP64, which the paper acknowledges) | §5.2, Fig 15 |
| Input bandwidth sensitivity | 100000×100000 weight matrix: column-major tile order needs ~570 GB/s in, row-major needs 3.7 GB/s ("well within ... 16-lane PCIe Gen4") | §5.2 |
| 8-way AllReduce | Saturates network quickly. Outperforms 8×A100 (NVLink 300 GB/s per GPU, nccl-tests) on fine-grained (small-tensor) communication "despite the A100 having more pin bandwidth". With the A100 result normalised to the TSP's pin bandwidth, the TSP "matches A100 at large tensor size while significantly outperforming A100 at smaller tensor size" | §5.3, Fig 16, fn 5 |
| BERT-Large on 4 TSPs in a GroqNode, 24,240 runs (SQuAD1.1) | "99% of inferences return in under 1225 μs, with all of them returning by 1300μs". Compiler estimate is "within 2% of the actual measured latency in the majority of cases". Deviation attributed to PCIe I/O. BERT-Base on 1 TSP is also within 2% | §5.4, Fig 17 |
| BERT scaling: 6/24/48/96 encoders on 1/4/8/16 TSPs | "linear scaling"; 4 TSPs give 4× realized TOPs | §5.4, Fig 18 |
| Cholesky (block-cyclic, 320 rows per TSP) | Speedup 1.2×, 1.4×, 1.5× on 2, 4, 8 TSPs; "14.9 FP16 TFlops on 4 TSPs to 22.4 FP16 TFlops on 8 TSPs, with 3× realized throughput compared to the best known results" | §5.5, Fig 19 |
| All-reduce latency, 256-TSP Dragonfly | "only three (3) hops ... pipelined network latency of 722 ns per hop ×3 hops = 2,166 ns, or ≈2.1 μsec". Hierarchical 3-stage: intra-node 8-way, then 4 global links, then intra-node | §5.6 |
| BERT-Large 4 TSPs, compiler optimisation | ~26% throughput gain from data-movement-aware partitioning | §5.6, Fig 20 |

**Limitations stated or implied by the paper:**
- SSN needs the traffic pattern known a-priori "for most of the workloads" (§4.1). The paper does not discuss dynamic or data-dependent traffic.
- Global bandwidth per TSP drops from ~50 to ~14 GB/s beyond 264 TSPs (§1, Fig 2).
- Uncorrectable errors are handled only by replaying the whole inference in software (§4.5).
- Reliability limits scale (§4.5: "The scale of a parallel computer ... is in a very practical sense limited by the reliability of the system").
- Measured BERT latency differs from the compiler estimate because of PCIe transfers (§5.4).
- Non-minimal routing gives no benefit below 8 kB (§4.3).
- Many of the large-system results (Fig 14/15 assume "a Dragonfly topology described previously") read as modelled or projected rather than measured on 10,440 TSPs. The paper does not clearly say which results are measured and which are projected.

---

## 6. Timing parameters usable in a simulator (raw)

- Core clock: 900 MHz (§5.2).
- Vector: 320 B (320 elements int8), 20 tiles × 16 lanes (§2).
- Flit = vector. On the wire it is 328 B, of which 320 B is payload (Fig 11).
- Link: 4 lanes × 25 Gb/s = 100 Gb/s operating speed, up to 30 Gb/s per lane (§2.3, fn 2).
  - *Derived:* 328 B × 8 / 100 Gb/s = 26.24 ns per vector, about **23.6 core cycles at 900 MHz** per vector per link. This assumes no further PHY/FEC overhead, which is unknown.
- HAC epoch: 252 cycles (fn 4). HAC is 8-bit with 4 reserved codes.
- Intra-node link latency (HAC round-trip derived, one-way): min 209, mean ≈216.3–217.4, max 228, std ≈2.6–2.9 cycles (Tab 2).
  - *Derived:* at 900 MHz, 217 cycles ≈ 241 ns. *Discrepancy:* §5.6 uses "722 ns per hop" for the pipelined all-reduce latency. That figure probably includes SRAM buffering, the receive-and-forward instruction path, and/or optical inter-node cables, but the paper does not break it down.
- Initial sync overhead: (⌊L/252⌋+1) epochs per spanning-tree level (§3.2).
- Runtime resync: ≈1 epoch (§3.2).
- Diameter: 3 hops for ≤264 TSPs (§2.2, §5.6); 5 hops for up to 10,440 TSPs (§2.2).
- End-to-end system latency: <3 μs at max scale (Abstract).

---

## 7. Not found / unverified

**Searched for in [P] and not found:**
- Numeric clock-drift tolerance (ppm), the HAC maximum adjustment rate ("configurable", no value), and the convergence time in cycles (only "approximately bounded by the period of the HAC counters").
- Required frequency of RUNTIME_DESKEW, and the target stall value used in practice.
- Instruction-level latencies of SEND/TRANSMIT/RECV on the C2C unit. There is no per-hop breakdown of the 722 ns (SerDes, FEC, SRAM write/read, re-transmit).
- Latency of inter-node (QSFP or optical) links. Table 2 covers only intra-node links.
- Buffer depth of the "very shallow buffers" at the C2C/core clock boundary.
- FEC code type, overhead, correction strength and added latency. PHY line coding.
- The compiler's scheduling algorithm (no pseudo-code, no complexity, no heuristics beyond tensor-size-based link count). The IR is not named in the paper (ONNX/MLIR appear only in [HC]).
- Exact Dragonfly global-link arrangement between racks and between nodes (which port goes to which group), beyond the port counts.
- Clarification of the "radix-8 torus, triple-connected" local group (§4.4) versus the fully connected node (§2.2).
- Single-chip stream counts, slice counts and per-unit latencies. These are not in the ISCA 2022 paper; they appear only in [HC] (secondary) and in the ISCA 2020 paper [1], which I did not read here.
- Packaging details for GroqCard and GroqRack beyond "PCIe card" and "rack". Physical numbers (power, CPUs per node) are not given.
- Whether the C2C link is full duplex, and the per-direction bandwidth. "100 Gbps across the four lanes" is not qualified.

**Unreachable sources:** Groq-hosted paper PDFs (404), ACM DL PDF (403), Wayback Machine (429). Patents US12277444B2 / US20230161621A1 were not read.

**Originally written from memory; now sourced by other notes in this folder (updated 2026-11-17). None of the three is in [P]:**
- The GroqChip has 16 C2C links: the ISCA 2020 paper gives "sixteen (16) ×4 links" (`01_tsp_isca2020.md` §11), and [HC] slide 65 says "16 directly connected links on each TSP". Why only 11 are used in this paper's topology is not stated anywhere (see the inference in §1.1).
- A node has a two-socket x86 host beside the 8 cards: SHIP §7.1.1 says "a dual-socket AMD CPU host" (`03_recent_lpu.md` §4.3), and the ISC 2020 slides say "DP AMD 'Rome' server" (slide 19 of `https://mlhardware.github.io/2020/groq.pdf`).
- The chip is 14 nm and 25×29 mm: `01_tsp_isca2020.md` §1. The area of about 725 mm² is derived (25 × 29).

---

## 8. Parameters for the simulator

| Parameter | Value | Exact source location | Confidence |
|---|---|---|---|
| Core clock | 900 MHz | [P] §5.2 ("each TSP operating at 900MHz"); also [HC] slide 14 | High |
| Vector width | 320 bytes / 320 elements | [P] §2, §4.1, §4.3, Fig 11 | High |
| SIMD organisation | slice = 20 tiles × 16-way SIMD | [P] §2 | High |
| Local SRAM per TSP | 220 MiB | [P] Abstract, §2 | High |
| Flit | 1 vector (320 B payload, 328 B on wire, 97.5% efficiency) | [P] §2.3, Fig 11 caption | High |
| Flit internal layout | 41 × 8-byte words (5 B data in header, 3 B in tail) | Derived from [P] Fig 11 | Medium |
| Links per TSP (used) | 7 local + 4 global = 11 | [P] §2.2 | High |
| Lanes per link | 4 | [P] §2.2 | High |
| Lane rate | 25 Gb/s operating (30 Gb/s max) | [P] §2.3 and fn 2 | High |
| Link bandwidth | 100 Gb/s (12.5 GB/s) | [P] fn 2 | High (direction unspecified) |
| Serialization time per vector per link | ≈26.2 ns ≈ 23.6 cycles | Derived from [P] fn 2 + Fig 11 + §5.2 | Medium (ignores FEC/PHY overhead) |
| TSPs per node | 8 (fully connected, 28 cables) | [P] §2.2, §2.3 | High |
| Nodes per rack | 9 (72 TSPs), 1 hot spare | [P] §2.2, §4.5 | High |
| Max single-global-hop system | 33 nodes = 264 TSPs, 3-hop diameter | [P] §2.2 | High |
| Max system | 145 racks = 10,440 TSPs, 5-hop diameter | [P] §2.2, Abstract | High |
| Global BW per TSP | ~50 GB/s (≤ several hundred TSPs); ~14 GB/s (>264) | [P] §1, Fig 2 | High |
| HAC epoch | 252 cycles (8-bit counter, 4 reserved codes) | [P] fn 4 (§3.2) | High |
| HAC exchange interval | "every 256 cycles" | [P] §3 intro (conflicts slightly with fn 4) | Medium |
| Intra-node link latency | min 209 / mean ≈216–217 / max 228 cycles, std ≈2.6–2.9 | [P] Table 2 | High (intra-node electrical only) |
| Pipelined per-hop latency (system level) | 722 ns per hop | [P] §5.6 | Medium (composition unstated) |
| Initial sync cost | (⌊L/period⌋+1) × h epochs | [P] §3.2 | High (units slightly ambiguous) |
| Runtime resync cost | ≈1 epoch | [P] §3.2 | Medium |
| End-to-end latency, max system | < 3 μs | [P] Abstract | Medium (headline claim) |
| Non-minimal routing break-even | ≈8 kB message (8-TSP node, 7 non-minimal paths) | [P] §4.3, Fig 10 | Medium |
| Hardware backpressure / arbitration / VCs / link retry | none (software pacing, FEC, software replay) | [P] §2.3, §4.4, §4.5 | High |
| Flow-control mode | virtual cut-through, SRAM-buffered per hop | [P] §2.3 | High |
| MXM sub-op | [1×K]×[K×320], K=160 (FP16) / 320 (int8); 2 FP16 or 4 int8 sub-ops per cycle | [P] §5.2 | High |
| Compiler estimate accuracy | within 2% of measured (BERT) | [P] §5.4 | High |
| Stream registers | 64 × 320 B (32 east + 32 west) | [HC] slide 57 (SECONDARY) | Medium |
| MEM slices | 88 × 8192 addresses | [HC] slide 30 (SECONDARY) | Medium |
| ICUs | 144 | [HC] slides 14, 68 (SECONDARY) | Medium |
| Stream register hop | 1 cycle | [HC] slide 24 (SECONDARY) | Medium |
| MXM weight load / execute | 320B×16 in 20 cycles; 20-cycle execution | [HC] slide 28 (SECONDARY) | Medium |
