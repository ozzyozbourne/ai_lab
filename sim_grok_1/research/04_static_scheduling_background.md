# 04 — Background: VLIW, static scheduling, and compile-time resource-conflict resolution

Scope: background for an educational, cycle-level Python simulator of Groq's Tensor Streaming Processor (TSP) and a toy compiler that statically places data, binds ops to functional units, produces a cycle-exact timetable, and resolves conflicts over stream lanes and functional units.

Conventions:
- **[P]** primary source that I opened and read (the text was extracted from a PDF or page).
- **[P-bib]** primary source whose existence and bibliographic data I confirmed, but whose full text I could not open. Claims about its content are attributed to the secondary source that reports them.
- **[S]** secondary source (lecture notes, textbook slides, encyclopedia, a later paper describing an earlier one).
- Page numbers are the page numbers printed in the copy I read. Where the copy is a reprint with different pagination, I say so.
- Section 7 is **my synthesis**. It is not sourced fact.

---

## 0. Sources actually accessed

| Key | Source | Access |
|---|---|---|
| Fisher83 | J. A. Fisher, "Very Long Instruction Word Architectures and the ELI-512," ISCA 1983 (orig. pp. 140–150). Scanned copy: https://www.csd.uoc.gr/~hy425/2002s/vliw-eli512.pdf (reprint pagination 263–273) | [P], read pages 263–273 as images |
| Colwell87 | R. P. Colwell, R. P. Nix, J. J. O'Donnell, D. B. Papworth, P. K. Rodman (Multiflow), "A VLIW Architecture for a Trace Scheduling Compiler," ASPLOS-II 1987, pp. 180–192. https://www.eecg.utoronto.ca/~moshovos/ACA08/readings/trace.pdf | [P] |
| Abts20 | D. Abts et al. (Groq), "Think Fast: A Tensor Streaming Processor (TSP) for Accelerating Deep Learning Workloads," ISCA 2020, pp. 145–158. Groq's URL https://groq.com/wp-content/uploads/2024/02/2020-Isca.pdf now returns 404; I read the Wayback copy https://web.archive.org/web/2024/https://groq.com/wp-content/uploads/2024/02/2020-Isca.pdf. On 2026-11-20 the same 14-page PDF was fetched from https://cdn.sanity.io/files/chol0sk5/production/16e7e13197dfe5f52d3b0ed62e29620662c38743.pdf and used for the re-check below. | [P] |
| AbtsISC20 | D. Abts, "Groq's Tensor Streaming Processor (TSP)," ISC 2020 ML Hardware Workshop slides. https://mlhardware.github.io/2020/groq.pdf | [P] (slides) |
| GroqPat-894 | US 12,222,894 B2, "Compiler operations for tensor streaming processor" (Groq; Abts, Ross, Thompson, Thorson; priority 2017-09-15). https://patents.google.com/patent/US12222894 | [P], first ~100k characters only |
| GroqPat-339 | US 12,271,339 B2, "Instruction format and instruction set architecture for tensor streaming processor" (Groq; same inventors; priority 2017-09-15). https://patents.google.com/patent/US12271339B2/en | [P], first ~100k characters only |
| GroqPat-908 | US 11,868,908 B2, "Processor compiler for scheduling instructions to reduce execution delay due to dependencies" (Groq; Ross, Thorson; priority 2017-09-21). https://patents.google.com/patent/US11868908B2/en | [P], first ~100k characters only |
| Mahlke-L11/L12/L13 | S. Mahlke, EECS 583 (Univ. of Michigan) lectures: Class 11 "Instruction Scheduling" (Oct 6 2023), Class 12 "Superblock Scheduling, Intro to Modulo Scheduling" (Oct 9 2023), Class 13 "Software Pipelining" (Oct 18 2023). https://web.eecs.umich.edu/~mahlke/courses/583f23/lectures/583L11.pdf, …/583L12.pdf, …/583L13.pdf | [S], read |
| DeMicheli | G. De Micheli, "Scheduling II" slides (scheduling under resource constraints: Hu, list scheduling, force-directed), companion to *Synthesis and Optimization of Digital Circuits* (McGraw-Hill). https://si2.epfl.ch/demichel/publications/mcgraw/reductions/sch2.4.pdf | [S], read |
| Graham66 | R. L. Graham, "Bounds for Certain Multiprocessing Anomalies," Bell System Technical Journal 45(9), Nov. 1966, pp. 1563–1581. OCR text: https://ia801900.us.archive.org/27/items/bstj45-9-1563/bstj45-9-1563_text.pdf | [P] (OCR text, some equations garbled) |
| Lee98 | W. Lee, R. Barua, M. Frank, D. Srikrishna, J. Babb, V. Sarkar, S. Amarasinghe, "Space-Time Scheduling of Instruction-Level Parallelism on a Raw Machine," ASPLOS 1998. https://groups.csail.mit.edu/cag/raw/documents/Lee:ASPLOS:1998.pdf | [P] |
| Mei03 | B. Mei, S. Vernalde, D. Verkest, H. De Man, R. Lauwereins, "Exploiting Loop-Level Parallelism on Coarse-Grained Reconfigurable Architectures Using Modulo Scheduling," DATE 2003 (DRESC). https://past.date-conference.com/proceedings-archive/2003/DATE03/pdffiles/04b_2.pdf | [P] |
| Friedman09 | S. Friedman, A. Carroll, B. Van Essen, B. Ylvisaker, C. Ebeling, S. Hauck, "SPR: An Architecture-Adaptive CGRA Mapping Tool," FPGA 2009, pp. 191–200. https://people.ece.uw.edu/hauck/publications/SPR.pdf | [P] |
| McMurchie95 | L. McMurchie, C. Ebeling, "PathFinder: A Negotiation-Based Performance-Driven Router for FPGAs," FPGA 1995, pp. 111–117. Course copy: https://www.esa.informatik.tu-darmstadt.de/archive/twiki/pub/Lectures/AlgorithmenImChipEntwurfDe/router-pathfinder.pdf | [P] |
| Nowatzki13 | T. Nowatzki, M. Sartin-Tarm, L. De Carli, K. Sankaralingam, C. Estan, B. Robatmili, "A General Constraint-centric Scheduling Framework for Spatial Architectures," PLDI 2013, pp. 495–506. https://ldklab.github.io/assets/papers/pldi13-ilp-scheduler.pdf | [P] |
| Poletto99 | M. Poletto, V. Sarkar, "Linear Scan Register Allocation," ACM TOPLAS 21(5), Sept. 1999, pp. 895–913. https://www.cse.iitm.ac.in/~krishna/cs3300/linearscan.pdf | [P] |
| Isshiki | T. Isshiki, "VLSI System Design Part V: High-Level Synthesis (3)," Tokyo Institute of Technology lecture slides, 2006–07 (left-edge algorithm). https://www.vlsi.ict.e.titech.ac.jp/isshiki/VLSISystemDesign/pdf/VLSISystemX_06.pdf | [S], read |
| Mahlke92 | S. A. Mahlke, D. C. Lin, W. Y. Chen, R. E. Hank, R. A. Bringmann, "Effective Compiler Support for Predicated Execution Using the Hyperblock," MICRO-25, 1992. https://web.eecs.umich.edu/~mahlke/courses/583f18/reading/mahlke_micro92.pdf | [P] |
| Ruttenberg96 | J. Ruttenberg, G. R. Gao, A. Stoutchinin, W. Lichtenstein, "Software Pipelining Showdown: Optimal vs. Heuristic Methods in a Production Compiler," PLDI 1996. https://cs.utexas.edu/~less/reading/spring00/ruttenberg.pdf | [P] (poor OCR, used sparingly) |
| Proebsting94 | T. A. Proebsting, C. W. Fraser, "Detecting Pipeline Structural Hazards Quickly," POPL 1994. https://cwf.github.io/pro/Proebsting%20and%20Fraser.%20Detecting%20pipeline%20structural%20hazards%20quickly.pdf | [P] (poor OCR; used only for its citation of Davidson et al.) |
| PyDocs | Python documentation: data model (https://docs.python.org/3/reference/datamodel.html), stdtypes (https://docs.python.org/3/library/stdtypes.html), command line / `PYTHONHASHSEED` (https://docs.python.org/3/using/cmdline.html) | [P] |

**Re-check of 2026-11-17 (independent verifier).** All sources in the table were fetched again except Abts20 (Wayback unreachable from the checking machine, groq.com 404) and Isshiki (host did not respond). Quotations from Colwell87, the three patents, the Mahlke lectures, DeMicheli, Lee98, Mei03, Friedman09, McMurchie95, Nowatzki13, Poletto99, Mahlke92 and PyDocs matched the fetched text; patent titles, inventors and priority dates matched Google Patents. Fisher83 is a scan, so only the phrases that survive its embedded OCR were confirmed ("horrible task", "No arbitration is necessary, since the paths of the addresses will never cross"). **Abts20 quotations, page numbers and section labels in §1.4, §4.3, §5 and §6.1 were not re-verified**; see the caveat at the head of §6.1. Two attributions were corrected (§1.4 item 4, §4.3).

**Re-check of 2026-11-20 (second verifier).** Abts20 was obtained (URL in the table above; 14 pages, printed pages 145–158) and every Abts20 quotation, page number and section label in §1.4, §4.3, §5, §6.1 and §7 was compared with it. All quotations match the paper's words. Six locations were wrong and have been corrected in place; they are listed at the head of §6.1. The paper's Table I has no `Countdown`, `Step` or `Iterations` rows (§4.3). The 2026-11-17 statement that Abts20 was not re-verified no longer applies. Isshiki was not retried.

Not accessible: Rau's "Iterative Modulo Scheduling" full text, Paulin & Knight 1989, Llosa et al. 1996 (SMS), the Cydra 5 paper, Fisher 1981, Ullman 1975, Groq ISCA 2022, and Fisher's VLIW retrospective. The "Not found" section gives details.

---

## 1. VLIW architecture and philosophy

### 1.1 Fisher's definition (ELI-512, 1983)

- In Fisher's definition, a VLIW machine has one central control unit that issues a single long instruction per cycle. Each long instruction holds many tightly coupled independent operations, and "each operation requires a small, statically predictable number of cycles to execute." Operations can be pipelined. [Fisher83, "What is a VLIW?", reprint p. 263]
- Fisher says these properties set VLIWs apart from multiprocessors ("with large asynchronous tasks") and dataflow machines ("without a single flow of control"). [Fisher83, p. 263]
- The paper's motivation is that parallelism within basic blocks is limited to a factor of about 2–3. Trace scheduling was the enabling technique for compiling code with an order of magnitude more parallelism. [Fisher83, Abstract and pp. 263–264]
- Fisher calls hand-coding long-instruction-word machines "a horrible task," which is why the compiler must do the scheduling. [Fisher83, p. 264]
- **Exposed resources and no arbitration (memory banks):** Fisher describes how unpredictable references, routed through "some kind of global arbitration system," lead to bank conflicts and machine freezes. The proposed fix is to let "a combination of smart compiler and static code" predict the bank of each reference. "When we can predict the bank, we can use a dedicated address register to refer to it directly … No arbitration is necessary, since the paths of the addresses will never cross." [Fisher83, "VLIW Compilers Must Predict Memory Banks," p. 271] He adds a "pre-loop" so that loops start at an index value known modulo the number of banks. [Fisher83, p. 271 and figure p. 272]
- The ELI-512 design point: 16 clusters, a 500+-bit instruction word, 16 ALU operations, 8 pipelined memory references, 32 register accesses, and a multiway jump per cycle. [Fisher83, "A Machine to Run Trace-Scheduled Code," p. 267]

### 1.2 Multiflow TRACE: the hardware/compiler contract made explicit

- Colwell et al. state the contract directly: "the microarchitecture is exposed to the compiler, there is no microcode, and there is almost no hardware devoted to synchronization, arbitration, or interlocking of any kind (the compiler has sole responsibility for runtime resource usage)." [Colwell87, Abstract, p. 180]
- "All functional units run completely synchronized, directly controlled in each clock cycle by the compacting compiler. The true cost of every operation is exposed at the instruction set level, so that the compiler can optimize instruction scheduling." [Colwell87, p. 181]
- Why no interlocks: "The absence of pipeline interlock or conflict management hardware makes the machine simple and fast… given our large number of pipelined functional units, pipeline interlocking and conflict resolution would have been almost unimplementable." [Colwell87, p. 181]
- Static versus dynamic: they say scoreboards (CDC 6600, IBM 360/91) "perform the same scheduling task at runtime that Multiflow's Trace Scheduling compacting compiler performs at compile time." [Colwell87, p. 181]
- **Compiler-managed bank conflicts (closest Multiflow analogue to TSP stream/bank rules):** The TRACE memory restrictions include: at most one reference per controller per beat, no two references needing the same return bus, no two references to the same RAM bank within four beats, and limits on load/store buses and register-file write ports. [Colwell87, §6.4, p. 185] The disambiguator answers "can these conflict, modulo the number of memory banks?" with "no", "yes" or "maybe". On "yes" the operations are not scheduled together. On "maybe" the compiler treats them as conflicting for some resources and relies on a hardware "bank stall." [Colwell87, §6.4.2, p. 186] Unlike the TSP, TRACE kept a small dynamic safety valve for the unknown case.

### 1.3 Cydrome Cydra 5

- The Cydra 5 (Cydrome, 1987) was a heterogeneous "departmental supercomputer." Its numeric processor used a "directed-dataflow" architecture, described as a modified form of VLIW. [S: Wikipedia "Cydra-5", https://en.wikipedia.org/wiki/Cydra-5, citing Rau, Yen & Towle, "The Cydra 5 departmental supercomputer: design philosophies, decisions, and trade-offs," IEEE Computer 22(1):12–35, Jan. 1989, doi:10.1109/2.19820, and Schlansker, "Cydra 5," Encyclopedia of Parallel Computing, 2011]
- The primary paper was not accessible (a Rutgers course copy linked from Wikipedia returned 404). Its Cydra-specific hardware support for modulo scheduling (rotating registers, iteration control) is therefore under **Not found / unverified**.
- Indirect evidence of lineage: Rau, the Cydra 5 lead author, is the author of iterative modulo scheduling (§4). Rotating registers and kernel-only code with rotating predicates appear in modern modulo-scheduling teaching material. [S: Mahlke-L13, slides 4 and 19–20]

### 1.4 Why timing is exposed to the compiler (summary of the sources)

1. Hardware simplicity and clock speed: no interlocks, no conflict-management hardware. [Colwell87, p. 181]
2. The compiler sees a large window (whole traces), so it can find parallelism that runtime hardware limited to basic blocks cannot. [Colwell87, p. 181; Fisher83, pp. 263–264]
3. Static prediction removes the need for arbitration. [Fisher83, p. 271]
4. The Groq TSP takes this to the extreme. It pushes "the complexities associated with scheduling into the compiler… it falls on the compiler to precisely schedule instructions so as to use the hardware correctly and efficiently." Removing dynamic scheduling hardware keeps the ICU under 3% of area. [Abts20, §II, p. 147] Its determinism comes from "eliminating all reactive elements in the hardware (e.g. arbiters, and caches)." [Abts20 abstract, p. 145; checked against the paper on 2026-11-20. The phrase is not in the AbtsISC20 slides, which say only "Predictable performance through Determinism" (slides 4 and 22).] Groq's patents put the area figure as the ICU "accounting for less than 3% of the chip area" [GroqPat-339; GroqPat-894].

---

## 2. Trace, superblock and hyperblock scheduling (brief)

- **Trace scheduling** (Fisher, "Trace scheduling: A technique for global microcode compaction," IEEE Trans. Computers C-30(7):478–490, July 1981 [P-bib: citation as printed in Fisher83's reference list, p. 273]). Fisher83 summarizes it as follows. Pick the most frequently executed loop-free path (a "trace") using branch predictions. Schedule it as if it were one basic block, with extra precedence edges that forbid illegal motions. Then insert compensation code at splits and rejoins. Loops are handled by unrolling. [Fisher83, pp. 264–265] Multiflow's compiler uses the same scheme: pick the likely trace, schedule it as branch-free, and insert compensation code on off-trace edges. [Colwell87, p. 181]
- **Superblock:** "a block of instructions such that control may only enter from the top, but may exit from one or more locations." Instructions are not predicated, so a superblock contains one control path. [Mahlke92, §2, citing Hwu et al., "The superblock: An effective structure for VLIW and superscalar compilation," J. Supercomputing, 1993] Superblocks are list-scheduled like basic blocks. Priority is weighted by exit probabilities, and control dependences prevent illegal motion. [S: Mahlke-L12, slides 2–10]
- **Hyperblock:** predicated code that selectively merges basic blocks from several control paths (chosen by frequency, size and instruction characteristics) into one block for scheduling. [Mahlke92, Abstract and §2]
- **Relevance to the TSP toy compiler (inference from the above):** These techniques exist to move work across branch boundaries. A static tensor compute graph with no data-dependent control flow is a single basic block (a DAG), so trace, superblock and hyperblock machinery adds nothing. What carries over is the common core: a list scheduler over a dependence graph with a resource model. Unrolling loops into one large straight-line region, as Fisher does for loops (p. 265), is the right mental model for "unroll the tensor loop, then schedule the DAG."

---

## 3. Resource-constrained DAG scheduling

### 3.1 ASAP / ALAP / slack / critical path

From [S: Mahlke-L11, slides 6–9]:
- **Estart (ASAP):** Estart = 0 for nodes with no predecessors, otherwise Estart = max over predecessors of (Estart(pred) + latency). This is the schedule length with infinite resources.
- **Lstart (ALAP):** Lstart = Estart for nodes with no successors, otherwise Lstart = min over successors of (Lstart(succ) − latency).
- **Slack = Lstart − Estart**, also called mobility. Critical operations have slack 0, and a critical path is a chain of them.

De Micheli defines the force-directed "operation interval" as mobility plus one, the window [t^S, t^L] computed by ASAP and ALAP. [S: DeMicheli, "Force-directed scheduling definitions"]

### 3.2 Priority functions

Common priorities listed in [S: Mahlke-L11, slide 12]:
- **Height** (distance to the exit node; "the most common"): priority(op) = MaxLstart − Lstart(op) + 1 [slide 13].
- **Slackness** (inversely proportional to slack).
- Register use, "uncover" (many children), and original program order "when all else fails."

De Micheli lists "longest path to sink" and "longest path to timing constraint" as list-scheduling priorities. [S: DeMicheli, "List scheduling algorithms"] The RAW compiler uses a weighted sum of *level* (critical-path length to an exit node) and *average fertility* (number of descendants divided by number of processors). [Lee98, §5, "Event scheduler"]

### 3.3 The standard list (cycle) scheduling algorithm

Pseudocode as given in [S: Mahlke-L11, slide 14]:

```
build dependence graph, compute priority
UNSCHEDULED := all ops; time := -1
while UNSCHEDULED not empty:
    time++
    READY := ops in UNSCHEDULED whose incoming dependences are satisfied
    sort READY by priority
    for op in READY (highest to lowest):
        if resources free at `time` (check RU_map):
            op.issue_time := time
            mark resources busy in RU_map relative to issue time
            remove op from UNSCHEDULED/READY
```

The "RU_map" is a **resource usage map / reservation table**, indexed by (cycle, resource). A multi-cycle or partially pipelined unit marks several cells relative to its issue time (e.g. "Memory port = 2 cycles, pipelined" in the slide-15 example). [S: Mahlke-L11, slides 14–15]

Hu's algorithm is exact for in-trees (forests) with unit-delay operations of one type. List scheduling generalizes it greedily to arbitrary graphs. [S: DeMicheli, "Hu's algorithm", "Exactness of Hu's algorithm", "List scheduling algorithms"]

### 3.4 Complexity

- J. D. Ullman, "NP-complete scheduling problems," J. Computer and System Sciences 10(3):384–393, 1975, doi:10.1016/S0022-0000(75)80008-0. [P-bib. The publisher page (ScienceDirect) and dblp both returned 403 or bot protection. The bibliographic data and abstract summary come from search-engine index pages (datalearner.com, typeset.io). Per those summaries, the paper shows that optimal scheduling of precedence-constrained jobs is NP-complete even with unit-time jobs, and with one- or two-time-unit jobs on two processors. Not read first-hand.]
- Corroborating statements in sources I did read:
  - De Micheli: scheduling is an "intractable problem in general," handled with heuristics or ILP for small cases. [S: DeMicheli, "Summary"]
  - Lee et al.: "the space-time scheduling problem, as well as each of its subproblems, is NP complete," citing V. Sarkar, *Partitioning and Scheduling Parallel Programs for Multiprocessors*, MIT Press, 1989. [Lee98, §5 "Discussion"]
  - Nowatzki et al. call the spatial-architecture scheduling problem "typically NP-complete (depending on the hardware architecture)." [Nowatzki13, §1]

### 3.5 Graham's bounds

- Graham (1966) studies "timing anomalies" in list scheduling on identical processors. Adding processors, relaxing precedence, or shortening tasks can all *increase* the finishing time. [Graham66, abstract, p. 1563]
- Two lists L and L' on n processors give finishing times ω and ω'. The paper shows ω'/ω ≤ 2 − 1/n, so any list schedule is within a factor 2 − 1/n of optimal. [Graham66, p. 1568 proposition and closing discussion near p. 1580; OCR text "≤ 2 — (1/n), (where n is the number of processors)"]
- Graham also discusses the "longest chain" (critical-path) priority rule, choosing the ready task heading the longest chain of unexecuted tasks. He notes that its worst-case ratio cannot be shown to be "considerably closer to 1." The exact best-possible expression is garbled in the OCR and **unverified**. [Graham66, final section]
- Graham's model has no communication delays and no exact-arrival constraint. The bound is background on list-scheduling quality, not a guarantee for the TSP problem.

### 3.6 Force-directed scheduling (Paulin & Knight)

- Original: P. G. Paulin, J. P. Knight, "Force-Directed Scheduling for the Behavioral Synthesis of ASICs," IEEE TCAD 8(6):661–679, 1989 (the HAL system), with an earlier DAC 1987 version. [P-bib: the full text at ocw.snu.ac.kr was unreachable (connect failure), so the description below is from De Micheli's slides.]
- Method [S: DeMicheli, "Force-directed scheduling" slides]:
  - Each operation has a time frame [ASAP, ALAP] and a uniform probability of executing in each step of it.
  - A **distribution graph** per operation type sums these probabilities per control step.
  - The **self-force** of assigning op v_i to step l is Σ_{m ∈ frame} q_type(m) · (δ_lm − p_i(m)), where q_type is the distribution and the second factor is the change in probability ("Force = constant × displacement").
  - Predecessor and successor forces account for the frames of neighbours shrinking.
  - The algorithm (minimum resources under a latency bound) repeats: compute time frames, compute probabilities, compute forces, then "schedule the op. with least force, update time-frame," until every op is scheduled.
  - A variant, FDLS, uses force as the priority inside list scheduling to minimize latency under a resource bound.
- Relevance (inference): FDS balances unit usage under a fixed latency. That is useful if the toy compiler is given a cycle budget and wants to spread stream-lane pressure evenly, but it is O(n²)-ish and harder to make exact-arrival-aware than list scheduling.

---

## 4. Modulo scheduling (software pipelining)

### 4.1 Rau's iterative modulo scheduling (IMS)

- B. R. Rau, "Iterative Modulo Scheduling: An Algorithm For Software Pipelining Loops," MICRO-27, 1994, pp. 63–74. Also issued as HP Labs TR HPL-94-115. [P-bib. The abstract page https://american.cs.ucdavis.edu/Micro27/html/abst7.html describes modulo scheduling as a framework for software pipelining innermost loops, and IMS as "a practical algorithm… capable of dealing with realistic machine models." The HPL-94-115 PDF via the Wayback Machine was truncated (corrupt xref) and then rate-limited (HTTP 429). I could not read the full text.]
- Concepts, from teaching material [S: Mahlke-L13]:
  - **II (initiation interval):** cycles between the starts of successive iterations. The schedule repeats every II cycles. The stage count is the number of II-length stages in one iteration. [slide 2]
  - **Modulo constraint and MRT:** "No resource is used at 2 points in time that are separated by an interval which is a multiple of II." To schedule an op at time T needing resource R, "the entry for R at T mod II must be free," and that entry is then marked busy. This table is the **modulo reservation table**. [slide 3]
  - **MII = max(ResMII, RecMII).** ResMII = max over resources r of ⌈uses(r)/count(r)⌉. RecMII = max over dependence cycles c of ⌈delay(c)/distance(c)⌉. The driver starts at II = MII and increments II on failure. [slides 8–13]
  - **Priority:** HeightR(X) = max over successors Y of (HeightR(Y) + EffDelay(X,Y)), with EffDelay = Delay − II·Distance. This is computed iteratively because of cycles. [slides 15–17]
  - **Scheduling window:** E(Y) = max over scheduled predecessors of (SchedTime(X) + EffDelay(X,Y)). Only the window [E(Y), E(Y)+II−1] need be tried: "if the operation cannot be scheduled there, then it cannot be scheduled." [slide 18]
- **Conflict resolution by eviction (backtracking with a budget):** The search-engine summary of EECS 583 Class 14 (https://web.eecs.umich.edu/~mahlke/courses/583f18/lectures/583L14.pdf) says IMS picks a slot, schedules the op, "then unschedules previously scheduled ops that conflict with it," decrementing a budget proportional to the op count, and moves to II+1 when the budget runs out. **I could not open those slides** (repeated connection resets from web.eecs.umich.edu) or Rau's paper. Treat the exact eviction rule (which slot is chosen when none is free, and which ops are displaced) as **unverified**. The Not-found section gives my recollection, labelled as such.
- Related evidence of backtracking in production modulo schedulers: the SGI MIPSpro heuristic pipeliner. On failure for operation L_i, it finds the largest j < i whose legal range is not exhausted, unschedules L_j … L_{i−1}, and resumes; the whole attempt fails if no such j exists. [Ruttenberg96, §2.3 / Figure 1; OCR quality is poor]
- Earlier reference: M. S. Lam, "Software pipelining: an effective scheduling technique for VLIW machines," PLDI 1988, pp. 318–327. [P-bib, as cited by Mei03 ref. [11] as the source of the MRT concept]

### 4.2 Swing modulo scheduling (brief)

- J. Llosa, A. González, E. Ayguadé, M. Valero, "Swing Modulo Scheduling: A Lifetime-Sensitive Approach," PACT 1996, pp. 80–86, doi:10.1109/PACT.1996.554030. Extended version: "Lifetime-Sensitive Modulo Scheduling in a Production Environment," IEEE TC 50(3):234–249, 2001. [P-bib. The CORE PDF https://core.ac.uk/download/87638302.pdf returned 403. Per the search-index summary (scilit), it is a low-cost heuristic evaluated on the Perfect Club suite against other heuristics and ILP.] The algorithmic details (node ordering that "swings" between predecessors and successors to shorten lifetimes, no backtracking) are from memory and **unverified**.

### 4.3 When modulo scheduling matters for a streaming tensor chip

- The TSP ISA has `Repeat n,d` ("repeat the previous instruction n times, with d cycles between iterations") and MEM `Countdown d` ("Set the delay d in cycles between loop iterations"), `Step a` and `Iterations n` ("Set the loop bounds for address generation") for address-generation loops. [`Repeat`: AbtsISC20 slide 9 and Abts20 Table I. `Countdown`, `Step`, `Iterations`: AbtsISC20 slide 9 (and Hot Chips 34 slide 25) only. Abts20 Table I, checked on 2026-11-20, lists four MEM instructions (Read, Write, Gather, Scatter) and does not have these three rows; the paper's text does not mention them either.] A repeated instruction with a fixed inter-iteration delay d is a hardware-supported fixed-II pattern. (Inference: d plays the role of II.)
- Abts20 §IV (ResNet50, p. 153) and Fig. 11 ("Example instruction schedule for 3x3 max pool in ResNet50", p. 156) show steady-state, repetitive schedules. The paper does not describe a modulo-scheduling algorithm.
- Inference: when the graph is "do the same k-op chain on each of R rows/vectors," fully unrolling and list-scheduling R·k ops works for a toy. A modulo schedule is the compact and provably periodic alternative: schedule one iteration under an MRT whose resources are units, MEM ports and **stream-lane cells mod II**, then emit with `Repeat`. ResMII is set by the busiest resource per iteration, for example the number of vectors a single MEM slice must read. RecMII is set by loop-carried dependences, for example an accumulator.

---

## 5. Resource-conflict resolution techniques

### 5.1 Reservation tables (Davidson)

- The reservation-table and collision-vector approach to pipeline control is due to Davidson and colleagues. Proebsting & Fraser cite "Davidson, Shar, Thomas and Patel, 'Effective control for pipelined computers', COMPCON 75," which proposed "collision matrices, which record when instructions collide," compiled into an automaton. [Proebsting94, §1 and ref. [5]; P-bib for Davidson 1975, which I did not access] Modern compilers use the same idea as the RU_map in list scheduling (§3.3) and the MRT in modulo scheduling (§4.1).

### 5.2 Delaying operations (inserting slack / NOPs)

- In list scheduling, an op that finds its resources busy is simply tried in a later cycle. [S: Mahlke-L11, slide 14]
- Groq uses explicit delays. "The compiler uses explicit NOPs to provide temporal separation between two instructions in program order," with a 16-bit repeat count (NOP(N)). [Abts20, §III.A.1, p. 151; §II, p. 148: "OpA NOP(N) OpB"]
- Groq patent: delays are assigned "in relative terms (e.g., +5 clock cycles) rather than absolute terms," and in practice implemented as NOPs. [GroqPat-908, description]
- PLUG (Nowatzki): "Network contention is avoided by code-scheduling the send instructions with NOP padding to create appropriate delays and equalize all delay mismatch," with send-padding δ(e) and receive-padding γ(e) variables. [Nowatzki13, §5.3, eq. (26)]
- SPR's **latency padding**: when placement cannot meet the optimistic schedule because long wires need extra registers, "if there isn't enough slack, it needs to communicate this to the scheduler," which pads the schedule and reschedules. [Friedman09, §6.1]

### 5.3 Re-binding to an alternative unit

- ResMII becomes more complex "because operations can have multiple alternatives (different choices for resources it could be assigned to)." [S: Mahlke-L13, slide 9]
- In spatial schedulers, binding (placement) is a decision variable in its own right: Mvn(v,n) = 1 iff vertex v is mapped to hardware node n, and each v maps to exactly one compatible node. [Nowatzki13, §3, eqs. (1)–(2)] DRESC and SPR re-place ops during annealing, which is effectively re-binding. [Mei03, §3.3; Friedman09, §3]
- The TSP paper says the compiler may have to select "one of several means by which an algorithm or meta-operation may be realized on the hardware." [Abts20, §II, p. 147; same language in GroqPat-339]

### 5.4 Register/lane allocation as interval-graph colouring

- **Left-edge algorithm** (originally from channel routing; Hashimoto & Stevens 1971, **from memory, unverified**). As taught for HLS register binding [S: Isshiki, "Left-Edge Algorithm (1)–(5)", "Properties of Left-Edge Algorithm"]:
  - Sort lifetimes by start l_min. Repeatedly fill one register with a maximal chain of non-overlapping lifetimes, scanning left to right, then open a new register.
  - "Even though it is a greedy algorithm, left-edge algorithm produces an optimal solution in terms of number of registers." The minimum is "the maximum number of data lifetimes overlapping within the scheduling time set."
  - It applies only when the conflict graph is an interval graph. In general "task-to-agent problem may not be from an interval graph, in which case left-edge algorithm cannot be applied."
- **Linear scan** (Poletto & Sarkar 1999): live intervals are processed "in order of increasing start point," with an *active* list sorted by increasing end point. Expired intervals are freed. When registers run out, the interval with the furthest end point is spilled (Figure 1). It is a single linear-time greedy pass, in contrast to graph colouring. [Poletto99, §1 and §2 (Fig. 1)]

### 5.5 Routing-resource scheduling on CGRAs

**DRESC / MRRG (Mei et al., 2003)** [Mei03]:
- Modulo scheduling on a CGRA is "a combination of 3 subproblems: placement, routing and scheduling." [§3.1]
- The **modulo routing resource graph (MRRG)** "combines features of the modulo reservation table (MRT) for software pipelining and the routing resource graph used in FPGA P&R." It is "a time-space representation of the architecture" in which "every subgraph is replicated each cycle along the time axis." Each node is a (resource port, time) tuple. The graph is modulo (using a node at t implies its use at t mod II) and asymmetric (a route cannot go backwards in time). [§3.2]
- Algorithm: for each II starting from MII:
  1. Generate an initial schedule that respects dependences but may overuse resources.
  2. Iteratively rip up one op, re-place it randomly, and re-route its nets.
  3. Accept or reject with simulated annealing on a cost that "tak[es] into account overused resources. The penalty associated with them is increased every iteration… This idea is borrowed from the Pathfinder algorithm."
  4. On timeout, try II+1. [§3.3]

**SPR (Friedman et al., 2009)** [Friedman09]:
- Separates mapping into scheduling (IMS), placement (simulated annealing, VPR-style) and routing (PathFinder + QuickRoute). [§3, Fig. 3]
- Unrolling the datapath graph over II cycles "turns the CGRA's time dimension into a third space dimension from the point of view of the placer and router… registers actually route forward in time to the next cycle." [§5.1]
- Feedback loop: if placement fails, `padSchedule()` adds latency; if routing fails, minII++. [Fig. 3, §6.1]
- Extends PathFinder to negotiate both signal congestion and time-multiplexed static-mux configuration. [§7.1]

**PathFinder negotiated congestion (McMurchie & Ebeling, 1995)** [McMurchie95, §3.1]:
- The cost of node n is c_n = (b_n + h_n) · p_n, where b_n is the base cost (delay), h_n is the history of congestion over previous iterations, and p_n depends on how many signals currently share n.
- In the first iteration sharing is free (p_n = 1). In later iterations "this penalty is gradually increased… so that signals in effect negotiate for resources." Every net is ripped up and rerouted each iteration until no node is over-used.
- "If the increase is too abrupt, signals may be forced to take high cost routes that lead to other congestion."

### 5.6 Time-space scheduling for spatial architectures

**RAW (Lee et al., 1998)** [Lee98]:
- Instruction scheduling on Raw "becomes a spatial problem" as well as temporal: partitioning and placement are followed by event scheduling. [§1, §3]
- The static switch is programmed with explicit route instructions, so "all events to be scheduled are instructions."
- Key technique: **"treating a single-source, multiple-destination communication path as a single scheduling unit. When a communication path is scheduled, contiguous time slots are reserved for instructions in the path so that the path incurs no delay in the static schedule."** [§5, "Event scheduler"]
- A "single greedy list scheduler" handles both computation and communication tasks, with priority = weighted level + fertility. [§5]
- Difference from TSP: Raw relies on blocking near-neighbour flow control (the "static ordering property") to stay correct under dynamic delays, so it does not need NOPs. [§5] The TSP has no such flow control (§6 below), so timing must be exact.

**Nowatzki et al., PLDI 2013 — constraint-centric (ILP) scheduling** [Nowatzki13]:
- Five abstractions: (i) placement of computation, (ii) routing of data, (iii) managing timing of events, (iv) managing utilization, (v) optimization objective. These are encoded as 20 general ILP constraints, applied to TRIPS, DySER and PLUG. [Abstract, §1, §3]
- Placement: binary Mvn(V,N), with each vertex mapped to exactly one compatible node [eqs. (1)–(2)]. Routing: binary Mel(E,L) maps edges to link paths, with flow-conservation constraints [eqs. (3)–(6)].
- **Timing**, the core equation for our problem:
  T(v_src) + Δ(e) + Σ_l Mel(e,l) + X(e) = T(v_dst)   [eq. (8)]
  Here Δ(e) is the cycles from vertex start to data ready, Σ Mel is the routing delay in hops, and X(e) is extra buffering cycles ("Since the data carried by all input edges for a vertex might not all arrive at the same time, the variable X(E) describes this mismatch").
- Utilization: U(l) = Σ_e Mel(e,l), with per-resource caps [eqs. (10), (14)]. Link exclusivity is expressed by constraints such as Mel(e,l) + Mel(e,l′) ≤ 1 for incompatible links [eq. (7)].
- **PLUG is the closest published analogue to the TSP.** PLUG is "radically different… since all decisions are static." Contention is avoided by NOP padding, so equation (8) becomes
  T(v_src) + Σ_l Mel(e,l) + Δ(e) + δ(e) = T(v_dst) + Γ(e) + γ(e)   [eq. (26)]
  with δ, γ ≥ 0 (no negative NOPs) and equal send delay for all multicast edges carrying one message [eqs. (27)–(28)]. [§5.3]
- Results: the ILP approach "typically matches or outperforms specialized schedulers." Solver time is reported per benchmark. [Abstract, §6]

---

## 6. Published descriptions of Groq's compiler scheduling

### 6.1 ISCA 2020 ("Think Fast") — what is stated

**Citation locations checked against the paper (2026-11-20).** On 2026-11-17 the paper could not be opened, and a caveat here listed six places where this subsection and `01_tsp_isca2020.md` gave different locations for the same sentence. The paper has now been read (source table, section 0). In all six, `01_...` was right and this note was wrong; the citations below have been corrected: (1) the one-hop-per-cycle sentence is in Section V (Discussion), in the run-in paragraph headed "c) On-chip network", p. 155, not §IV.F; (2) Eq. 4 and the two-dimensional scheduling sentence are in the introduction of Section III (Instruction Set), p. 151, not §II.C; (3) the logical-program-time sentences and the 35-cycle barrier are in §III.A.2 on p. 152, not p. 151; (4) the instruction-dispatch slices are in the introduction of Section IV on p. 153, not p. 152; (5) the tensor-layout sentence is in Section V, paragraph "b) Matrix operations", p. 155, not §IV.F; (6) Fig. 11 is on p. 156, not p. 155 (§4.3). Section V has no lettered subsections; a), b) and c) are run-in paragraph headings printed in the right-hand column of p. 155 beside the Section V heading, which is why they are easy to attribute to §IV.F, the last lettered subsection before them. They are cited here as "§V para. a/b/c". The sentences this note quotes that `01_...` does not were also found in the paper with the wording given. Much of the content is also paraphrased in GroqPat-339 (144 queues, 35-cycle barrier, d_func and d_skew, 64 streams, pseudo-dual-port SRAM banks).

- **Streams:** "Streams are implemented in hardware by a chip-wide streaming register file (SR). They are architecturally-visible and transport operands and results between slices." Example: Z = X + Y is `Read S1,X`, `Read S2,Y` on two MEM slices "directed inward toward an INT slice to perform the Add S1,S2,S3," then `Write S3,Z`. [Abts20, §I.B, p. 147]
- There are 32 eastward and 32 westward logical streams per lane. Streams are named by id 0..31 plus direction, e.g. in(28) and out(24). [Abts20, §II, p. 147] Multi-byte types use aligned stream groups (int16 on a stream pair, int32 on a quad: SG4_0 = streams 0–3). "Data alignment is accomplished by the compiler." [§I.B, p. 146]
- **Movement:** "on each tick of the core clock, the TSP propagates stream values by one stream register hop in the direction of flow… The TSP hardware does not track the origin or destination slice, instead streams simply flow (propagate) Eastward or Westward until they fall off the edge of the chip or are overwritten by a functional slice." [§V para. c, p. 155] At time t_i the value at slice x_1 is available as an operand there. In cycle t_{i+1} it has either propagated to x_2 "or else it is overwritten with a result r_1 produced by the slice at x_1." [§II.A, p. 149] Each slice may choose the direction of its result stream, so streams can be "turned around." [§II.E, p. 151]
- **Space-time scheduling (the key statement):** "Conceptually, the compiler is solving a two-dimensional scheduling of instructions and data in both time and space (ie. stream register location on-chip…). The execution time of an instruction includes the instruction functional delay, and stream propagation (transit) delay to get from stream register location i (SR_i) to j (SR_j)." Eq. (4): T = N + d_func + δ(j,i), where N is the number of tiles in the slice (staggered SIMD issue across superlanes), d_func is the functional delay, and δ(j,i) is the transit distance in cycles. [§III introduction, p. 151]
- **Exposed timing parameters:** each instruction has d_func (cycles until its output appears on the stream registers) and d_skew ("the timing relationship between the instruction dispatch time relative to when its stream operands are required… informs the compiler how to schedule the operand arrival times with the instruction dispatch time in order to get them to properly intersect in time and space"). [§III, p. 151]
- **Program-time bookkeeping:** "the compiler keeps track of a logical program time… the compiler tracks the state of 144 independent program queues on a cycle-by-cycle basis. So at logical time t the compiler knows the state of each IQ on the chip." A single chip-wide Sync/Notify barrier at program start is needed (35 cycles), after which slices communicate "in a synchronization-free manner." [§III.A.2, p. 152]
- **Memory/data placement:** "To maximize stream concurrency, the compiler allocates memory for a tensor's concurrent stream operands into separate MEM slices — as streams propagate through the MEM system they 'pick up' operands from the MEM slices en route to the MXM." The ISA exposes the bank bit, so the compiler can "explicitly schedule individual banks in each MEM slice" (pseudo-dual-port: read one bank and write the other in the same cycle). [§IV.A, p. 153; §III.B, p. 152] The paper adds that "ideally the compiler will layout tensors in MEM slices so that data transit from memory slice MEM_i to MXM is minimized." [§V para. b, p. 155] As a matter of policy, the compiler reserves some MEM slices as instruction-dispatch slices. [§IV, p. 153]
- **Algorithm:** The paper does **not** name or describe the scheduling algorithm (no list, modulo or ILP description), nor how stream-lane conflicts are resolved.

### 6.2 Groq patents (partially read)

- US 12,222,894 / US 12,271,339 (priority 2017-09-15):
  - The compiler allocates "resources of the processor across an area of the processor" (functional slices, tiles, data transport lanes) for operations at defined time instants.
  - It schedules instruction and data flows "to intersect at a specific resource of the allocated resources," aiming for "precise matching (intersection) in time and space."
  - The compiler "maintains a high-fidelity (cycle accurate) model of a hardware state."
  - On conflicts: "The compiler may configure the program during a compile time to ensure that no conflict occurs." No algorithm is given in the portion I read (the first ~100k of ~250k characters). [GroqPat-894; GroqPat-339]
- US 11,868,908 (priority 2017-09-21):
  - The scheduler has three modules: instruction *placement* (ordering, so that "any delay… caused by dependencies between instructions is minimized"; the ordering may come from "a SAT instance solver" or "a greedy algorithm"); instruction *scheduling* (assigning relative delays, implemented as NOPs, so that operands are ready); and *memory allocating* (binding instructions to hardware units).
  - A constraint optimizer may reschedule greedily, starting with the constraint with "the largest deviation," or use SMT, SAT or ILP. [GroqPat-908]
  - This is the most concrete public statement of Groq's approach I found: **greedy or SAT ordering, then relative-delay (NOP) insertion, then binding**, with optional SAT/SMT/ILP re-optimization. The patent text is generic and may not reflect the production compiler.

---

## 7. Recommendation for the toy compiler — **MY SYNTHESIS (not sourced fact)**

This section builds on: list scheduling with a reservation table (Mahlke-L11), RAW's whole-path reservation (Lee98 §5), the Nowatzki/PLUG exact-timing equations (Nowatzki13 eqs. 8, 26), the space-time resource graph idea (Mei03 MRRG; Friedman09 time unrolling), PathFinder-style negotiation as a fallback (McMurchie95), left-edge optimality on interval graphs (Isshiki), and Groq's stated model (Abts20 eq. 4, d_func/d_skew, one hop per cycle, Read→op→Write pattern).

### 7.1 Problem model

- Slices have integer positions x. A stream lane is (dir ∈ {E,W}, id ∈ 0..L−1). A value on (dir,id) at position x in cycle t is at x+1 (E) or x−1 (W) in cycle t+1, unless a slice overwrites it there (Abts20 p. 149/155).
- Op v is bound to unit u(v) at position x_v, fires at cycle T(v), and has latency lat(v). Its result appears on a lane at x_v at cycle T(v) + lat(v).
- **Exact arrival (hard):** for each edge e = (p → c) carried directly on a stream,
  T(c) = T(p) + lat(p) + |x_c − x_p| (+ skew terms).
  This is Nowatzki eq. (8) with X(e) = 0, and Abts20 eq. (4) with N folded into lat. Direction is forced by sign(x_c − x_p).
- **Parking:** if T(c) is later than direct arrival allows, the value must go through memory: p → Write at MEM slice m (arrives at T(p)+lat(p)+|x_m−x_p|), then a Read at m issued at exactly T(c) − rd_lat − |x_c − x_m|, with Read ≥ Write + wr_lat. This is the Read/Add/Write pattern in Abts20 §I.B. **Key observation:** the MEM Read is itself a freely timed op, so "park in memory" is the general retiming mechanism. Direct producer→consumer chaining is an optimization used when the timings happen to line up.

### 7.2 The space-time reservation table (STRT)

Resources, each a cell keyed by an integer tuple:
- `("unit", unit_id, t)`: one op per cycle per unit (or lat cycles if not pipelined).
- `("mem_rd", slice, bank, t)` and `("mem_wr", slice, bank, t)`: per the bank exposure in Abts20 p. 152.
- `("lane", dir, id, x, t)`: a transfer launched at (x0, t0) eastward occupies cells (x0+k, t0+k) for k = 0..|Δ|. It is a diagonal in (x, t) space, which is the MRRG/time-unrolled-graph view of Mei03 and Friedman09 specialised to a 1-D line.

A transfer is reserved **atomically as a whole path** (Lee98: "contiguous time slots are reserved"). Partial reservations are never left behind.

**Useful structural fact (my derivation):** for an eastward transfer, every occupied cell satisfies t − x = t0 − x0 =: k, a constant "launch phase." For westward, t + x = const. Two same-direction transfers can collide only if they have the same phase k **and** overlapping x-intervals. So, for fixed times, lane assignment decomposes per (dir, k) into **interval-graph colouring over positions**. Left-edge is optimal there: lanes needed = max over (dir, k, x) of overlapping transfers (Isshiki's optimality statement). This lets you
1. check lane *capacity* during time scheduling with a cheap counter `occ[dir][k][x] ≤ L`, and
2. assign concrete lane ids afterwards with left-edge, with no backtracking.

This holds whether a transfer's interval stops at the consumer or is modelled as continuing to the chip edge (Abts20 p. 155 says values flow until overwritten or they fall off the edge). The second model is more conservative. Stream-group alignment for multi-byte types (Abts20 p. 146) breaks pure interval colouring. To handle it, allocate in aligned groups of 2 or 4, which is still greedy but may no longer be optimal.

### 7.3 Recommended algorithm: exact-arrival list scheduling with whole-path reservation

Phase 0 (placement, deterministic heuristic): put input/weight tensors in MEM slices near their consumer unit and spread concurrent operands across distinct slices (Abts20 §IV.A). Bind ops to units of the right type, preferring the nearest free unit. Ties go to the lowest position, then the lowest unit id.

Phase 1 (priorities): compute Estart and Lstart with edge weight lat(p) + |x_c − x_p| (Mahlke-L11). priority(v) = height = longest path to sink. Sort key: (−height, −num_descendants, op_index).

Phase 2 (forward list scheduling, earliest feasible fire time):

```
def schedule(dag, placement, L):
    strt = ReservationTable()          # dict keyed by int tuples; only membership tests
    T = {}                             # op -> fire cycle
    ready = sorted_ready(dag, T)       # ops whose producers are all scheduled
    while ready:
        v = min(ready, key=lambda o: (-height[o], -desc[o], o.index))
        t = earliest(v, T)             # max over operands of direct-arrival time; >= 0
        while True:                    # probe increasing t (bounded, see below)
            plan = try_fire(v, t, T, strt)   # returns list of cells+actions or None
            if plan is not None:
                strt.commit(plan)      # atomic: unit cell, every operand path, result path
                T[v] = t
                break
            t += 1
        ready = sorted_ready(dag, T)
    return T, strt

def try_fire(v, t, T, strt):
    cells = [("unit", unit(v), t)]
    for (p, operand) in operands(v):
        if p is a memory-resident tensor or already parked:
            # choose a Read time so that it arrives exactly at t
            src = mem_slice_of(operand)
            tr = t - skew(v) - rd_lat - abs(x(v) - x(src))
            if tr < 0: return None
            cells += [("mem_rd", src, bank(operand), tr)] + lane_path(src, x(v), tr + rd_lat)
        else:
            direct = T[p] + lat(p) + abs(x(v) - x(p))
            if direct == t - skew(v):
                cells += lane_path(x(p), x(v), T[p] + lat(p))   # chain directly
            else:
                # producer already fired; its result must have been parked when produced
                return None   # handled by always parking (see "rule P" below)
    if any(c in strt for c in cells) or lane_capacity_exceeded(cells): return None
    return cells
```

Rule P (simplest correct policy): **every produced value is written to a MEM slice when produced** (the result path to the chosen park slice is reserved in the same commit as the producer). Consumers always read from memory, except that chaining is used when `direct == t` and the lane path is free. This makes every consumer's search monotone. Raising t only moves the consumer's own Read later, never earlier than the Write, so a feasible t always exists once all resources at large t are free. The probe loop therefore terminates.

The schedule is valid by construction:
- every operand arrives exactly at t (equality enforced per operand);
- no cell is double-booked;
- lane ids are assigned afterwards by left-edge per (dir, phase), and capacity was already guaranteed by the counter check.

Phase 3 (optional improvement, IMS/PathFinder-flavoured): if the makespan is poor, run a bounded repair loop.
1. Pick the lowest-priority op on the critical path whose chained transfer forced a delay, unschedule it and its descendants, and reschedule with that lane's cells temporarily penalised.
2. Bound the loop by an iteration budget, as in IMS-style budgets (unverified detail, see §4.1), and keep the best schedule.
3. Use only integer, order-stable data structures, so the result is reproducible.

Phase 4 (codegen): per functional-slice instruction queue, emit ops in time order with `NOP(n)` gaps (Abts20 p. 151; GroqPat-908 relative delays). Emit `Repeat n,d` if the schedule came from a modulo pass.

**Loops / repeated rows:** start with full unrolling plus Phase 2. As an extension, apply IMS concepts with an MRT whose keys are taken mod II, including lane cells `("lane", dir, id, x, t mod II)`. ResMII comes from per-iteration MEM reads per slice, unit uses, and lane-phase occupancy. RecMII comes from accumulator recurrences (Mahlke-L13).

**Exact / reference solver:** for tiny graphs, encode Nowatzki-style constraints (eq. 8 with X(e) as a park-in-memory choice, eq. 26-style padding) in an ILP or CP model. Use it to measure the heuristic's optimality gap in tests, not as the main path, because NP-hardness (§3.4) makes solve time unpredictable.

### 7.4 Determinism of the compiler itself

1. **No iteration over `set` or `frozenset` of strings or other str-hashing objects** where order affects output. Sets are "unordered" (PyDocs datamodel §3.2.6), and str/bytes hashes are "salted with an unpredictable random value… not predictable between repeated invocations" unless `PYTHONHASHSEED` is fixed (PyDocs cmdline, `-R` / `PYTHONHASHSEED`). Inference: set iteration order can differ between runs. Use lists, or `sorted(s, key=...)`.
2. `dict` iteration is insertion-ordered ("Dictionaries preserve insertion order," PyDocs datamodel §3.2.7.1), so dicts are safe **only if** insertion order is itself deterministic.
3. Every selection uses a **total-order key ending in a unique integer id**, e.g. `(-height, -desc, op_index)`, `(position, unit_id)`, `(lane_id)`. `list.sort()` "is guaranteed to be stable" (PyDocs stdtypes, Lists). Never rely on `id()`, object addresses, or float ties.
4. Op indices come from a canonical topological numbering of the input graph (Kahn's algorithm with a min-heap on the original input index), not from Python object identity.
5. No randomness in the main path. If annealing or negotiation (DRESC/PathFinder-style) is added, use a seeded `random.Random(seed)` instance passed explicitly, and record the seed in the output.
6. Use integer cycles everywhere. If costs are floats (FDS forces, PathFinder costs), compare with a deterministic tie-break on ids.
7. Add a golden test: compile the same graph twice in separate processes with different `PYTHONHASHSEED` values and assert byte-identical schedules. Add a simulator cross-check that every operand arrives exactly on its consumer's fire cycle.

---

## 8. Not found / unverified

**Paywalled or unreachable (no full text read):**
- **Rau 1994, Iterative Modulo Scheduling (MICRO-27 / HPL-94-115).** The Wayback PDF was truncated or corrupt and then rate-limited (HTTP 429). The direct hpl.hp.com connection was reset. EECS 583 Class 14 slides (IMS pseudocode) failed with repeated connection resets. *From memory, unverified:* IMS schedules ops in priority order, each within [Estart, Estart+II−1]. If no conflict-free slot exists it chooses a slot (e.g. Estart, or one past the op's previous time) and **evicts** the ops that conflict with it in the MRT, as well as successors whose dependences are now violated. Evicted ops return to the unscheduled set. A budget (e.g. BudgetRatio × #ops scheduling steps) bounds the work before II is incremented.
- **Paulin & Knight 1989 (TCAD) / 1987 (DAC).** The ocw.snu.ac.kr copy was unreachable. The description is from De Micheli's slides.
- **Llosa et al. 1996, Swing Modulo Scheduling.** CORE returned 403. Algorithm details are from memory and unverified.
- **Rau, Yen & Towle 1989, Cydra 5 (IEEE Computer).** The Rutgers copy was 404. Rotating register files and iteration-control hardware as Cydra 5 features are from memory, unverified.
- **Fisher 1981, Trace Scheduling (IEEE TC).** Only the citation, from Fisher83's reference list, was verified. Content is summarized from Fisher83 and Colwell87.
- **Ullman 1975, NP-complete scheduling problems.** ScienceDirect and dblp were blocked. The bibliographic data and result summary come from search-index pages only.
- **Graham 1969 (SIAM J. Appl. Math 17(2):416–429, "Bounds on multiprocessing timing anomalies").** Not accessed. The 2 − 1/n result above is from the 1966 BSTJ paper. The exact critical-path bound in the 1966 paper is OCR-garbled.
- **Davidson et al. 1975 / Davidson 1971 (reservation tables).** Not accessed. Attribution is via Proebsting & Fraser 1994.
- **Hashimoto & Stevens 1971 (left-edge, channel routing)** and **Kurdahi & Parker 1987 (REAL, HLS register allocation by left-edge).** Not accessed; attributions are from memory.
- **Hwu et al. 1993 (Superblock, J. Supercomputing).** Only the citation, via Mahlke92 ref. [11], was verified.
- **Groq ISCA 2022 ("A Software-defined Tensor Streaming Multiprocessor…")** returned 404 on groq.com, an HTML page on Wayback, and 403 at the ACM DL. Not read here. `02_tsp_multiprocessor_isca2022.md` read it in full from another URL; its §4 records what that paper says about the compiler (a DAG of deadlines, link pacing, link count chosen from tensor size) and that it, too, gives no algorithm.
- **Fisher's VLIW retrospective** (UW course copy): login-walled.
- **Groq patents:** only the first ~100k characters of each Google Patents page were processed. Later sections may contain more algorithmic detail.

**Searched for but not found:**
- Any published description of the **specific algorithm** Groq's production compiler uses for stream-lane allocation or space-time scheduling (list, modulo, ILP, etc.). Abts20 states the two-dimensional time/space problem but not the algorithm. GroqPat-908 mentions greedy/SAT ordering and SMT/SAT/ILP optimizers only generically.
- A published proof or statement that stream-lane assignment on a 1-D one-hop-per-cycle line reduces to per-phase interval colouring. §7.2 is my own derivation and should be checked by test, e.g. by brute-force comparison on small random instances.
