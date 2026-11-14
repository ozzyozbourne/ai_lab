# 04 — VLIW, static scheduling, and compile-time resource-conflict resolution

Research note for the educational TSP simulator and toy compiler. Scope: background on VLIW / exposed-datapath machines, list scheduling, modulo scheduling, reservation tables, scheduling with explicit routing resources (CGRA / HLS), exact-arrival ("no-wait") constraints, and what Groq has published about its own scheduler. The last main section turns this into a concrete, deterministic scheduler design.

Conventions:
- "(read)" means I opened the source in this session and the claim comes from its text. Short verbatim quotes are in quotation marks.
- "(metadata only)" means I confirmed the bibliographic record (search-result abstract, DBLP/RePEc/INFORMS record) but not the body text.
- "(unverified recollection)" marks claims I could not confirm in this session. They are collected again in the last section.
- Text marked **Analysis** is my own reasoning, not a cited claim.

---

## 1. Sources consulted (with reachability status)

### Primary sources and papers

| # | Source | Status |
|---|--------|--------|
| S1 | J. A. Fisher, "Very Long Instruction Word Architectures and the ELI-512", *Proc. 10th ISCA*, 1983, pp. 140–150. PDF: https://www.csd.uoc.gr/~hy425/2002s/vliw-eli512.pdf | **Read** (OCR text layer of a scan; some OCR noise) |
| S2 | J. A. Fisher, "Trace Scheduling: A Technique for Global Microcode Compaction", *IEEE Trans. Computers* C-30(7):478–490, July 1981, DOI 10.1109/TC.1981.1675827 | Metadata only (search results / DBLP record). Its role is confirmed by S1, which cites "[Fisher 81]" |
| S3 | W. W. Hwu, S. A. Mahlke, et al., "The Superblock: An Effective Technique for VLIW and Superscalar Compilation", *J. Supercomputing* 7:229–248, 1993. https://web.eecs.umich.edu/~mahlke/courses/583w23/reading/hwu_jsuper93.pdf | **Read** (abstract and introduction) |
| S4 | S. A. Mahlke, D. C. Lin, W. Y. Chen, R. E. Hank, R. A. Bringmann, "Effective Compiler Support for Predicated Execution Using the Hyperblock", MICRO-25, 1992. https://web.eecs.umich.edu/~mahlke/courses/583w23/reading/mahlke_micro92.pdf | **Read** (abstract and introduction) |
| S5 | B. R. Rau, "Iterative Modulo Scheduling: An Algorithm for Software Pipelining Loops", MICRO-27, 1994, pp. 63–74, DOI 10.1145/192724.192731. Abstract page: https://american.cs.ucdavis.edu/Micro27/html/abst7.html | Abstract **read**. Full text **unreachable**: https://www.hpl.hp.com/techreports/94/HPL-94-115.pdf (connection reset with curl, 503 with WebFetch). Algorithm details come from S12/S13 |
| S6 | B. R. Rau, C. D. Glaeser, "Some scheduling techniques and an easily schedulable horizontal architecture for high performance scientific computing", MICRO-14 / ACM SIGMICRO Newsletter 12(4):183–198, 1981, DOI 10.1145/1014192.802449 | Metadata only (Scilit record via search) |
| S7 | B. Mei, S. Vernalde, D. Verkest, H. De Man, R. Lauwereins, "Exploiting Loop-Level Parallelism on Coarse-Grained Reconfigurable Architectures Using Modulo Scheduling", DATE 2003. https://past.date-conference.com/proceedings-archive/2003/DATE03/pdffiles/04b_2.pdf | **Read** (pdftotext) |
| S8 | H. Park, K. Fan, S. Mahlke, T. Oh, H. Kim, H. Kim, "Edge-centric Modulo Scheduling for Coarse-Grained Reconfigurable Architectures", PACT 2008. https://cccp.eecs.umich.edu/papers/parkhc-pact08.pdf | **Read** |
| S9 | P. G. Paulin, J. P. Knight, "Force-Directed Scheduling for the Behavioral Synthesis of ASICs", *IEEE TCAD* 8(6):661–679, 1989 | Metadata only. Characterized second-hand in S10 (read) |
| S10 | J. Cong, Z. Zhang, "An Efficient and Versatile Scheduling Algorithm Based on SDC Formulation", DAC 2006. https://www.csl.cornell.edu/~zhiruz/pdfs/sdc-dac2006.pdf | **Read** |
| S11 | C. E. Leiserson, J. B. Saxe, "Retiming Synchronous Circuitry", MIT/LCS/TM-309, May 1986 (journal version *Algorithmica* 6:5–35, 1991). DSpace: https://dspace.mit.edu/handle/1721.1/149118 | DSpace abstract **read**. PDF https://cseweb.ucsd.edu/classes/fa23/cse248-a/papers/retiming/Leiserson.pdf **unreachable** (TLS chain error with curl, 503 with WebFetch). The Algorithmica volume and pages come from search metadata only |
| S12 | U. Michigan EECS 583 (S. Mahlke), Class 13 "Software Pipelining", Oct 2021. https://web.eecs.umich.edu/~mahlke/courses/583f21/lectures/583L13.pdf | **Read** |
| S13 | U. Michigan EECS 583, Lecture 14 (Fall 2018), modulo scheduling II. https://web.eecs.umich.edu/~mahlke/courses/583f18/lectures/583L14.pdf | **Read** |
| S14 | U. Michigan EECS 583, Class 11 (Fall 2021), list scheduling. https://web.eecs.umich.edu/~mahlke/courses/583f21/lectures/583L11.pdf | **Read** |
| S15 | Cornell ECE 6775 (Z. Zhang), "Scheduling", lecture 10, Fall 2025. https://www.csl.cornell.edu/courses/ece6775/pdf/lecture10.pdf | **Read** |
| S16 | UW CSE 401/501m, "Instruction Scheduling", Spring 2025. https://courses.cs.washington.edu/courses/cse401/25sp/lectures/R-Instruction-Scheduling.pdf | **Read** (skimmed) |
| S17 | T. A. Proebsting, C. W. Fraser, "Detecting Pipeline Structural Hazards Quickly", POPL '94. https://cwf.github.io/pro/Proebsting%20and%20Fraser.%20Detecting%20pipeline%20structural%20hazards%20quickly.pdf | **Read** |
| S18 | J. Hoogerbrugge, H. Corporaal, "Comparing Software Pipelining for an Operation-Triggered and a Transport-Triggered Architecture", Springer LNCS, DOI 10.1007/3-540-55984-1_20. https://rd.springer.com/content/pdf/10.1007/3-540-55984-1_20.pdf | **Read** (§1–2) |
| S19 | Wikipedia, "Transport triggered architecture". https://en.wikipedia.org/wiki/Transport_triggered_architecture | Read (tertiary; used only for the "exposed datapath VLIW" framing) |
| S20 | W. Lee, R. Barua, M. Frank, D. Srikrishna, J. Babb, V. Sarkar, S. Amarasinghe, "Space-Time Scheduling of Instruction-Level Parallelism on a Raw Machine", ASPLOS-VIII, 1998, DOI 10.1145/291069.291018. https://groups.csail.mit.edu/cag/raw/documents/Lee:ASPLOS:1998.pdf | **Read** |
| S21 | M. Skutella, "An Introduction to Network Flows Over Time" (2008 manuscript; in *Research Trends in Combinatorial Optimization*, Springer 2009). https://www3.math.tu-berlin.de/Vorlesungen/SS08/NetOpt/flows_over_time.pdf | **Read** (Def. 4.3) |
| S22 | S. Friedman, A. Carroll, B. Van Essen, B. Ylvisaker, C. Ebeling, S. Hauck, "SPR: An Architecture-Adaptive CGRA Mapping Tool", FPGA '09. https://people.ece.uw.edu/hauck/publications/SPR.pdf | **Read** |
| S23 | J. Melchert et al., "Cascade: An Application Pipelining Toolkit for Coarse-Grained Reconfigurable Arrays", LATTE '24. https://capra.cs.cornell.edu/latte24/paper/11.pdf | **Read** |
| S24 | T. Nowatzki, N. Ardalani, K. Sankaralingam, J. Weng, "Hybrid Optimization/Heuristic Instruction Scheduling for Programmable Accelerator Codesign", PACT 2018, DOI 10.1145/3243176.3243212. https://polyarch.cs.ucla.edu/papers/pact2018-hybrid-sched.pdf | **Read** (§2–3) |
| S25 | N. G. Hall, C. Sriskandarajah, "A Survey of Machine Scheduling Problems with Blocking and No-Wait in Process", *Operations Research* 44(3):510–525, 1996, DOI 10.1287/opre.44.3.510 | Abstract **read** (RePEc) |
| S26 | T. C. Hu, "Parallel Sequencing and Assembly Line Problems", *Operations Research* 9(6):841–848, 1961, DOI 10.1287/opre.9.6.841 | Abstract read (RePEc) |
| S27 | E. G. Coffman, R. L. Graham, "Optimal Scheduling for Two-Processor Systems", *Acta Informatica* 1:200–213, 1972, DOI 10.1007/BF00288685 | Metadata only |
| S28 | J. D. Ullman, "NP-complete scheduling problems", *J. Computer and System Sciences* 10(3):384–393, 1975 | Metadata only. https://www.sciencedirect.com/science/article/pii/S0022000075800080 returned **403** |

### Groq sources

| # | Source | Status |
|---|--------|--------|
| G1 | D. Abts et al., "Think Fast: A Tensor Streaming Processor (TSP) for Accelerating Deep Learning Workloads", ISCA 2020, pp. 145–158, DOI 10.1109/ISCA45697.2020.00023 | **Unreachable** in this session: https://groq.com/wp-content/uploads/2024/02/2020-Isca.pdf (404), https://dl.acm.org/doi/pdf/10.1109/ISCA45697.2020.00023 (403), groq.humain.ai mirror (DNS/502). Claims attributed to it below are second-hand via G5/G6 |
| G2 | D. Abts, G. Kimmell, A. Ling, J. Kim, M. Boyd, A. Bitar, S. Parmar, I. Ahmed, et al., "A Software-defined Tensor Streaming Multiprocessor for Large-scale Machine Learning", ISCA '22, DOI 10.1145/3470496.3527405. Copy read: https://cdn.sanity.io/files/chol0sk5/production/81d0c45ed70a10f1804bbd82f2d0076af1186ff0.pdf | **Read** (groq.com copy 404'd; the Sanity CDN copy worked) |
| G3 | D. Abts, "Groq" slides, ISC 2020 ML Hardware Workshop. https://mlhardware.github.io/2020/groq.pdf | **Read** |
| G4 | D. Abts, "The Groq Software-defined Scale-out Tensor Streaming Multiprocessor", Hot Chips 34, 2022 slides. https://hc34.hotchips.org/assets/program/conference/day2/Machine%20Learning/HotChips34%20-%20Groq%20-%20Abts%20-%20final.pdf | **Read** |
| G5 | Groq patent US12222894B2, "Compiler operations for tensor streaming processor" (Abts, Ross, Thompson, Thorson; priority 2017-09-15). https://patents.google.com/patent/US12222894 | Read through WebFetch (first ~200k of 264k characters) |
| G6 | NCTU CAS Lab reading notes on G1 (HackMD). https://hackmd.io/@nctu-cas-lab/rJfwSx1ju | Read (secondary; quotes there may paraphrase G1) |

### Tried and failed

- https://www.hpl.hp.com/techreports/94/HPL-94-115.pdf (Rau IMS tech report): connection reset / 503
- https://cseweb.ucsd.edu/classes/fa23/cse248-a/papers/retiming/Leiserson.pdf: TLS error / 503
- https://courses.cs.washington.edu/courses/cse548/05wi/files/Fisher-VLIW-Retrospective.pdf: redirects to a UW login page
- https://www.es.ele.tue.nl/~heco/documents/TTAbook/TTAbook.html (Corporaal TTA book page): 503 / 404
- https://ocw.snu.ac.kr/sites/default/files/MATERIAL/2494.pdf (force-directed scheduling notes): proxy 502
- https://www.inf.ed.ac.uk/teaching/courses/copt/lecture-6.pdf: 410 Gone
- https://cgi.cse.unsw.edu.au/~cs4211/04s1/seminars/lec16.pdf: 403
- Groq ISCA 2020 / 2022 PDFs on groq.com: 404 (see G1, G2)

---

## 2. Findings by topic

### 2.1 VLIW: the idea and what the compiler must guarantee

- **Definition (S1, read).** Fisher describes VLIW machines as ones where "many statically scheduled, tightly coupled, fine-grained operations execute in parallel within a single instruction stream". He lists their properties: "There is one central control unit issuing a single long instruction per cycle"; "Each long instruction consists of many tightly coupled independent operations"; "Each operation requires a small, statically predictable number of cycles to execute"; "Operations can be pipelined." He also notes that "VLIW looks like very parallel horizontal microcode."
- **The compiler is the enabler (S1, read).** Fisher argues that earlier wide machines got only 2–3× from parallelism because "until trace scheduling we didn't know how to generate code for them". He calls hand-coding long-instruction-word machines "a horrible task".
- **No runtime arbitration, because the compiler predicts conflicts (S1, read).** The section "VLIW compilers must predict memory banks" is the clearest early statement of compile-time conflict resolution. Fisher writes that with many references per cycle, "Getting the addresses through some kind of global arbitration system will take a long time" and the probability of bank conflict approaches 1. The fix is to have the compiler predict the bank: "When we can predict the bank, we can use a dedicated address register to refer to it directly... No arbitration is necessary, since the paths of the addresses will never cross." The compiler unrolls loops "so that the array subscripts increase by a multiple of the number of banks every iteration", and adds a "pre-loop" to bring unknown starting indices to a known value modulo the number of banks. Unpredictable references take a slower, separate path that can freeze the machine.
  - *Relevance:* the TSP's MEM slices and banks (G3: tensors are addressed as `[device, hemisphere, memory slice, bank, address offset]`, with 2 banks per slice) are the same kind of problem: the compiler places data so that accesses in the same cycle never collide.
- **What the compiler must guarantee (synthesis of S1, G2, G4).** On a statically scheduled machine with no arbiters, the compiler must ensure that: (i) every dependence is met, counting exact latencies; (ii) no two operations claim the same resource (unit issue slot, bank port, bus or stream slot) in the same cycle; (iii) every value is present where and when it is consumed. G2 (read) states this for the TSP: "all contention for both functional units and network links are resolved at compile-time".
- **Exposed datapath / transport-triggered architectures (S18 read, S19 read).** Hoogerbrugge and Corporaal: TTAs "are programmed by specifying the data-transports, or moves, directly"; an operation starts when a move writes the FU's trigger register, and "the compiler can perform extra optimizations and has far better control over hardware usage" (S18). Wikipedia calls TTAs "'exposed datapath' VLIW architectures" (S19). The TSP is similar: the compiler explicitly schedules data transport (stream reads, writes and hops) and the instructions that consume it. G4 (read): "the compiler is orchestrating the arrival of operands and the instructions which use them."

### 2.2 Trace scheduling, superblocks, hyperblocks (brief) and why ML graphs mostly don't need them

- **Trace scheduling (S2 metadata; S1 read).** A global compaction technique that schedules a likely path (trace) across basic-block boundaries, with compensation code on side paths. S1: experiments showed "only a factor of 2 to 3 speedup from parallelism was available within basic blocks", and trace scheduling "can find large degrees of parallelism beyond basic-block boundaries".
- **Superblock (S3, read).** A single-entry, multi-exit region formed from profiled traces. It lets the scheduler extract ILP "along the important execution paths by systematically removing constraints due to the unimportant paths". S14 (read): superblocks are scheduled "just like a BB", but Lstart becomes a vector, one per exit.
- **Hyperblock (S4, read).** A region of predicated basic blocks formed by if-conversion, used for both optimization and scheduling.
- **Why this mostly doesn't apply (Analysis, supported by G2/G4).** All three techniques exist to schedule across conditional branches. G4 (read) says ML "Nodes" fire "only when all their input operands are available" and that "Machine learning models are a good fit for this static analysis and deterministic execution". G2 (read) says the TSP compiler expresses "the static computation graph ... as a series of dependencies that impose temporal deadlines on the operand arrival times", "as a DAG". A forward pass is one big basic block, a DAG with no control flow, so plain DAG list scheduling (§2.3) suffices. The only control structure in a decode loop is the outer per-token repetition (§2.4).

### 2.3 List scheduling for resource-constrained DAGs

- **Problem and complexity.**
  - S15 (read): constrained scheduling is "General case NP-hard". The resource-constrained (RCS) variant minimizes latency under resource limits; the time-constrained (TCS) variant minimizes resources under a latency bound. Exact methods are ILP and "Hu's algorithm for a very restricted problem". Heuristics are list scheduling, force-directed scheduling and SDC-based scheduling.
  - Ullman 1975 (S28, metadata only): per a search-result abstract excerpt, optimal scheduling is NP-complete even when all jobs take unit time, or when jobs take one or two units on two processors.
  - Hu 1961 (S26, abstract read): sequencing n jobs with ordering restrictions on "men of equal ability". The result that Hu's algorithm is optimal for unit-time jobs with tree ("assembly forest") precedence, by scheduling highest level first, is a (unverified recollection); a secondary search snippet states it but I did not open a source.
  - Coffman–Graham 1972 (S27, metadata only): an efficient algorithm for optimal non-preemptive schedules on **two** processors (unit execution times, arbitrary precedence, per a search snippet).
  - *Relevance:* none of these optimality results covers heterogeneous units with spatial routing like the TSP. They justify using a heuristic, and they suggest height/level priority as the natural choice.
- **ASAP / ALAP / slack (S14, S15, read).** `Estart` (ASAP) = max over predecessors of `Estart(pred) + latency`. `Lstart` (ALAP) = min over successors of `Lstart(succ) − latency`. `Slack = Lstart − Estart`, and "Larger slack means more mobility". Critical operations have slack 0 (S14).
- **Priority functions (S14, read).** Height ("Distance from exit node", which gives priority to the amount of work left); slackness (inversely proportional to slack); register use; uncover (ops with many children); and "Original order – when all else fails". "Height-based is the most common": `priority(op) = MaxLstart − Lstart(op) + 1`. S16 also lists critical-path priority and forward vs. backward scheduling.
- **Two variants (S14, read; pseudocode summarized).**
  - *Cycle-driven* ("List Scheduling (aka Cycle Scheduler)"): advance `time` by one. `READY` = unscheduled ops whose incoming dependences are satisfied. Sort `READY` by priority. For each op from highest to lowest priority, schedule it if its resources are free, and "Mark resources busy in RU_map relative to issue time".
  - *Operation-driven* ("List Scheduling (Operation Scheduler)"): take the highest-priority unscheduled op and try `time = estart` up to some deadline. If no slot is found by the deadline, "unplace all conflicting ops at op.estart, add them to UNSCHEDULED", then schedule the op at estart.
- **HLS view (S10, read).** S10 describes list scheduling as the most popular heuristic for resource-constrained scheduling: ready operations are "sorted in a list according to certain priority function and are scheduled in order into the control state with available resources". It describes force-directed scheduling (S9) as a constructive heuristic for time-constrained scheduling that "minimizes the 'force' on the operations to balance computations over the available time steps so that the resource usage can be reduced".
- **Determinism / tie-breaking.** The sources list "original order" as the final tie-breaker (S14). Beyond that, determinism is an engineering requirement for a reproducible educational tool, not a literature result (see §3).

### 2.4 Modulo scheduling and whether it matters for a token-decode loop

- **Origin.** Rau & Glaeser 1981 (S6, metadata only): the "polycyclic" horizontal architecture and a scheduling algorithm that yields optimal or near-optimal schedules for iterative computations (paraphrase of the indexed abstract). Rau 1994 (S5, abstract read): "Modulo scheduling is a framework within which a wide variety of algorithms and heuristics may be defined for software pipelining innermost loops"; IMS is "a practical algorithm ... capable of dealing with realistic machine models".
- **Definitions (S12, read).**
  - II is the fixed delay between the starts of successive iterations.
  - `MII = Max(ResMII, RecMII)`.
  - `ResMII = MAX over r (uses(r)/count(r))`. S12 notes it is "more complex than this because operations can have multiple alternatives".
  - `RecMII = MAX over cycles c (delay(c)/distance(c))`.
  - Modulo constraint: "No resource is used at 2 points in time that are separated by an interval which is a multiple of II". The **Modulo reservation table** enforces it: to schedule an op at time T on resource R, "The entry for R at T mod II must be free".
  - Height priority with loop-carried edges uses `EffDelay(X,Y) = Delay(X,Y) − II*Distance(X,Y)`.
- **Iterative displacement (S13, read; course rendering of Rau's algorithm).**
  - Driver: compute MII; set `II = MII`; set `budget = BUDGET_RATIO * number of ops`; loop `iterative_schedule(II, budget); II++` until a schedule is found.
  - `iterative_schedule`: pick the highest-priority unscheduled op; `min = E(Y)`; `max = min + II − 1`; `t = find_slot(op, min, max)`; schedule the op at t; "Unschedule all previously scheduled ops that conflict with op"; `budget--`.
  - `find_slot` returns the first t in [min, max] with no MRT conflict. If there is none, it returns `min` if the op was never scheduled or `min` is greater than its previous time, else `MIN(1 + prev scheduled time of op, max)`. The bump past the previous time prevents ping-ponging.
  - A window of size II suffices: "if the operation cannot be scheduled there, then it cannot be scheduled."
- **Relevance to repeated token decode (Analysis).**
  - In autoregressive decode, token k+1's input depends on token k's output, so the dependence cycle runs through the whole forward pass with distance 1. RecMII is therefore about the full per-token latency, and overlapping iterations of a *single* sequence buys little.
  - Modulo scheduling would matter if (a) several independent sequences or batch rows are interleaved (distance > 1 or no recurrence), or (b) loop-invariant work, such as streaming the next layer's weights, is overlapped with compute. G2 (read) notes a related difficulty for Cholesky, which "is difficult to efficiently parallelize due to a loop-carried dependence".
  - Recommendation: schedule one decode step acyclically and replay it with period = makespan. Keep the MRT idea as an optional extension. The MRT is a modular wrap of the same reservation table (key `cycle mod II`), so designing the table with a pluggable "cycle key" makes the extension cheap.

### 2.5 Reservation tables and structural-hazard detection

- **Reservation tables / resource vectors (S17, read).** Proebsting & Fraser describe the standard compile-time check. Each instruction class has a resource vector "indexed by a cycle number, and each element records the resources needed during that cycle". To schedule, "the scheduler compares its resource vector with the composite vector for the instructions already in the pipe. If both vectors show a need for the same resource at the same time, a structural hazard is reported. Otherwise, the resources from the instruction's vector are incorporated into the composite."
- **Collision matrices / automata (S17, read).** S17 credits Davidson, Shar, Thomas and Patel (Spring COMPCON 1975, "Effective control for pipelined computers", pp. 181–184; cited in S17 as ref [5]) with using resource vectors to compute an automaton whose states are built from "collision matrices, which record when instructions collide". S17 turns this into a minimal FSM with one table lookup per instruction.
- **Collision vectors / forbidden latencies.** Search-result excerpts from course notes define a forbidden latency as a latency that results in a collision in a pipeline's reservation table, and the collision vector as the binary encoding of the forbidden-latency set. I did not open an authoritative text for this. Attribution of the original theory to Davidson (1971) and its textbook treatment in Kogge, *The Architecture of Pipelined Computers* (1981), is (unverified recollection). The Chulalongkorn course page (read) only says "A reservation table shows a timing diagram of a flow of data through the functional unit" and "A collision vector represents the collision information."
- **Ways to resolve a conflict (synthesized from S13, S14, S7, S8, S24, G5).**
  1. **Delay**: move the op later. S14's cycle scheduler simply moves on to the next cycle; G5 (read): the compiler can insert explicit NOPs to "provide temporal separation between two instructions in the program order".
  2. **Alternative resource**: S12 notes ops can have "multiple alternatives (different choices for resources it could be assigned to)". DRESC's cost function penalizes overuse so that the "placer and router will try to find alternatives to avoid congestion" (S7). G2 load-balances tensors across multiple links, including non-minimal routes.
  3. **Buffering the value**: hold it in a register file or memory. In DRESC, a register file "has abundant routing resources to route signals along the time axis" (S7). In S24 the options are delay FIFOs, pass-through PEs, or longer routes. On the TSP, the only storage off the stream is MEM.
  4. **Re-placement / backtracking**: unschedule conflicting ops and retry (S13, S14), or rip up and re-place (S7).

### 2.6 Scheduling with explicit communication / routing resources

- **Time-expanded (time-space) graphs (S21, read).** Def. 4.3: for a network with integral transit times τ and horizon T, make T copies v_0 … v_{T−1} of every node. Each arc e=(v,w) gets copies e_θ connecting v_θ to w_{θ+τ_e}, plus **holdover arcs** (v_θ, v_{θ+1}) that model waiting at a node. Its size is "linear in T and therefore only pseudo-polynomial".
  - *Relevance (Analysis):* a TSP stream lane is a time-expanded path graph whose arcs have τ = 1 hop per cycle and **no holdover arcs** (a stream value cannot wait). Holdover exists only at MEM slices (write, then later read). This is the formal version of the exact-arrival constraint.
- **DRESC and the MRRG (S7, read).**
  - The modulo routing resource graph "combines features of the modulo reservation table (MRT) ... and the routing resource graph used in FPGA P&R".
  - "Because the MRRG is a time-space representation of the architecture, every subgraph is replicated each cycle along the time axis." Each node is a tuple (port of resource, time stamp).
  - The scheduler solves "placement, scheduling and routing ... in a modulo-constrained 3D space". For each II, it builds an initial schedule that may overuse resources. It then repeatedly rips up one op, places it randomly, reroutes its nets, and accepts or rejects the move by simulated annealing.
  - The overuse penalty "is increased every iteration", an idea "borrowed from the Pathfinder algorithm". When the time budget runs out, it moves to the next II.
  - Priority goes to critical-path operations.
- **Edge-centric modulo scheduling, EMS (S8, read).**
  - EMS argues that node-centric schedulers, which place first and then route, are a poor fit when operands "must be explicitly routed between producing and consuming operations".
  - "With edge-centric modulo scheduling (EMS), placement is a by-product of the routing process, and the schedule is developed by routing each edge in the dataflow graph."
  - Routing is maze routing: neighbouring slots go into a priority queue ordered by a routing cost. The cost has two goals: "Minimize the number of routing resources used" and "Proactively avoid routing failure". High-fanout edges get low priority and are routed through register files.
  - S8 reports a 25% throughput gain over IMS and 98% of simulated annealing's throughput at much lower compile time.
- **SPR (S22, read).** SPR combines a VLIW-style scheduler (IMS) with FPGA-style placement (annealing) and PathFinder/QuickRoute pipelined routing. "Unrolling the graph turns the CGRA's time dimension into a third space dimension ... registers actually route forward in time to the next cycle." **Latency padding** is its feedback loop: when the placer cannot meet the optimistic schedule because long wires have forced register latency, it computes the minimum extra latency needed and adds "padding that looks like extra delay dependencies to the scheduler".
- **Raw space-time scheduling (S20, read).** This is the closest analogue to "schedule data transport explicitly on a static network".
  - RAWCC does "spatial and temporal instruction scheduling, as well as data partitioning".
  - Routing is explicit switch instructions, so "the scheduling problem is a generalization of the traditional instruction scheduling problem".
  - Communication edges are replaced by chains of communication instructions, and the graph "is then presented to a vanilla greedy list scheduler, modified to treat each communication path as a single scheduling unit".
  - It uses dimension-ordered routing because contention is low.
- **HLS: ASAP/ALAP, force-directed, SDC (S15, S10, read).**
  - S10 converts scheduling constraints into a **system of difference constraints** `x − y ≤ b`. Consistency can be checked "by solving a single-source shortest path problem". The constraint matrix "guarantees integral solution", so an LP gives a valid schedule.
  - Dependency and timing constraints are modelled exactly. Resource constraints are modelled heuristically, by adding ordering edges between operations that compete for a resource.
  - Key for this project: "combining equations (3) and (4) allows us to specify the **exact latency distance** between two operations". A minimum constraint `s(vi) − s(vj) ≤ −l` combined with a maximum constraint `s(vj) − s(vi) ≤ u`, with l = u, pins the distance.
- **What a simple educational compiler can borrow (Analysis).**
  - From Raw: list scheduling where each operand route is reserved atomically with its consumer.
  - From EMS: routing cost (fewest slots used; avoid blocking scarce resources) as the tie-breaker among candidate placements.
  - From DRESC/MRRG: a time-space resource model.
  - From SDC: an exact-distance timing pre-check, run before the resource search.
  - Simulated annealing (DRESC, SPR) is too nondeterministic and opaque for teaching unless seeded. Prefer the greedy, deterministic EMS/Raw style.

### 2.7 Exact-arrival ("no-wait", delay-matching) constraints

- **No-wait in classical scheduling (S25, abstract read).** In a no-wait environment "a job must be processed from start to completion, without any interruption either on or between machines". *Blocking* is the variant where a finished job stays on its machine until the next one is free. These constraints arise from the technology or "a lack of storage". The survey covers the complexity of no-wait flowshop, jobshop and openshop problems.
  - *Relevance (Analysis):* a TSP stream is a no-wait conveyor. MEM provides the only intermediate buffer.
- **Delay matching on CGRAs (S24, read).** Nowatzki et al. name "delay mismatch" as the bottleneck when scheduling dedicated-PE CGRAs: an instruction's operands arrive at different relative times, either because its producers were mapped at different distances or because they sit at different graph depths. Three techniques: "Technique 1 is to use a longer route ...; Technique 2 uses a PE as a no-op, which we refer to as pass-through ...; Schedule 3 balances timing by using the delay-FIFO". Also: "In general, all three techniques are required to balance delay". Their ILP has explicit timing equations `Te = Tv + LATv + Σ routing latency + Xe` and a mismatch variable. Their heuristic builds schedules in topological order, choosing locations that minimize routing resources and mismatch.
- **Branch delay matching (S23, read).** "Branch delay matching matches the cycle arrival times of every piece of data arriving at every functional element in the application by adding registers on branches with shorter delay." Cascade then absorbs registers into memory tiles to save interconnect registers. This is close to "park in MEM" on the TSP.
- **Latency padding (S22, read).** When a route is forced to be longer, SPR feeds the extra latency back to the scheduler as a padded dependence and reschedules downstream ops.
- **Retiming (S11, abstract read).** Leiserson & Saxe show how retiming can turn a synchronous circuit into a more efficient one. It finds the minimum clock period in O(|V||E| log |V|) and minimizes register count in polynomial time, "an optimal way to pipeline combinational circuitry with minimal register cost" (paraphrased from the DSpace abstract). *Relevance:* retiming is the theory of moving delays (registers) along edges so that all paths into a node carry consistent delay. A toy compiler can borrow the *idea*: when a consumer's operands disagree on arrival time, shift the producer of the early operand later if it has slack, instead of adding a buffer.
- **Groq's own framing (G2, G5, G6).** G2 (read): dependencies "impose temporal deadlines on the operand arrival times". G5 (read via WebFetch): the compiler schedules each instruction flow and its data flows "to intersect at a specific resource of the allocated resources at a defined time instant", and "provides for precise matching (intersection) in time and space of specific data flows". G6 (secondary): d_skew "informs the compiler how to schedule the operand arrival times with the instruction dispatch time".

### 2.8 What Groq has published about its scheduler

Verified in this session:
- **Static, deterministic, compile-time scheduling.** "The programming model of the TSP is based upon a statically scheduled, deterministic execution" (G2). "The collection of functional units on each TSP act as a single logical core which is scheduled statically (at compile-time)" (G2). "Execution latency of all instructions is known statically (at compile time) and therefore exposed to the compiler via the ISA" (G2).
- **No reactive hardware.** Design-for-determinism rules include "No 'reactive components' like arbiters, crossbars, replay mechanisms, caches, etc" (G4). The network "disallows dynamic arbitration" (G2), and "the hardware is disallowed from asserting back pressure" (G2).
- **VLIW framing.** "Functional units execute in lockstep"; "One instruction issued per cycle at each dispatch path"; "Can be viewed as fully-pipelined 144-wide VLIW instructions" (G4). There are "144 independent instructions queues (ICUs)" and "64 logical streams - 32 Eastward, and 32 Westward" (G3).
- **Stream timing.** "Stream register = one-cycle hop"; "No arbiters / queues = software can easily reason about exact data movement without simulation"; "Travel time calculation as simple as a single subtract" (G4).
- **Synchronization primitives.** NOP ("No-operation, can be repeated N times to delay by N cycles"), Sync, Notify, and "Repeat n,d" (G3). SYNC parks issue and a single NOTIFY restarts the paused units "on the same clock cycle"; "This NOTIFY thus serves as the software-controlled time reference upon which all other static scheduling is derived" (G2).
- **Explicit tensor placement.** "Explicitly allocate tensors in space and time" (G3, G4). The address is a 5-tuple `[device, hem, memory slice, bank, address offset]` with "Bank within the slice (0 or 1) -- each slice has two internal banks for concurrency" (G3). A MEM slice "Can read and write one physical stream (vector) per cycle" (G4 slide text; the layout extraction was noisy, so treat it as approximate).
- **Software-scheduled networking.** "Scheduled, Not Routed": "the compiler orchestrates data movement based on global information across time and space to eliminate conflicts for shared output ports" (G2). It load-balances across links, including non-minimal routes, by tensor size (G2).
- **Patent (G5).** The compiler "performs resource allocations in both time and space"; it allocates "functional slices, tiles, data transport lanes, etc." and then schedules flows to intersect. When loading from MEM, "a stream identifier (e.g., 0, 1, . . . , 31) and a direction of flow (e.g., eastward, or westward) is assigned to the vector". The compiler "may configure the program during a compile time to ensure that no conflict occurs" on stream registers. It "maintains a high-fidelity (cycle accurate) model of a hardware state".

Not verified (G1 unreachable): the exact definitions of `d_func` and `d_skew`, and the phrase "two-dimensional scheduling of instructions and data in both time and space". These come only from G6 (secondary notes) and from G5's paraphrase, which uses the same language ("two-dimensional (i.e., time-space) scheduling"). **No source found describes the actual algorithm Groq's compiler uses** (list scheduling vs. ILP vs. anything else). Any claim about it would be speculation.

---

## 3. Recommendations for a toy TSP compiler

The goal is a deterministic, explainable, greedy scheduler. Everything here is a design proposal (Analysis), tied to the sources above.

### 3.1 Machine and resource model

1. **Positions.** Model each hemisphere's functional slices (MEM slices, VXM, MXM, SXM) as integer positions on a 1-D east–west axis, following G3/G4's "one-dimensional interconnect". A stream value moving east from position p at cycle t is at position p+k at cycle t+k. Westward values decrease. Transit = |p_dst − p_src| (G4: "a single subtract").
2. **Reservation tables.** Use three sparse tables, all keyed with a pluggable cycle key so modulo scheduling can be added later (§2.4):
   - **Unit table** `U[(unit_id, cycle)] -> op_id`. Units are fully pipelined with one issue per cycle per dispatch path (G4), so an op reserves only its issue cycle. If a unit has a non-trivial occupancy pattern, store a per-op-class resource vector (list of (sub-resource, offset)) and check every entry, as in Proebsting & Fraser's resource-vector check (S17).
   - **Stream table** `S[(hem, dir, lane, position, cycle)] -> value_id`. A route from (p0, t0) to (p1, t1) on lane L reserves the whole diagonal {(L, p0+k·dir, t0+k) : k = 0..|p1−p0|}. This is the time-expanded network (S21) restricted to transit arcs, with no holdover. Checking costs O(distance) lookups.
   - **Memory table** `M[(slice, bank, port, cycle)] -> op_id` for read and write ports, plus an address allocator over lifetime intervals per (slice, bank). This is the only place where values may wait, i.e. holdover arcs (S21). ELI-512-style bank prediction applies here (S1).
3. **Fan-out (design choice to confirm against the simulator).** If the simulator lets several consumers along a stream's path read the same passing value, a route is one diagonal shared by all of them. It is reserved once, by the farthest consumer. Whether real TSP slices can all read a passing stream without consuming it is (unverified recollection) and should be checked against 01/02 dossier notes.

### 3.2 Timing pre-pass (deterministic, before any resource is touched)

1. Build the DAG. For each op, record latency `d_func(op)` and operand skew `skew(op, i)`, i.e. how many cycles after dispatch operand i must be at the unit; G5/G6 name these parameters.
2. Compute `Estart` (ASAP) and `Lstart` (ALAP) with edge weight = producer latency + **minimum** transit distance for the cheapest legal placement (S14, S15). Compute `slack = Lstart − Estart` and `height = longest latency-plus-transit path to any sink`.
3. Optional (shows SDC, S10): express "operand i must arrive exactly at fire − skew" as paired difference constraints (`x_c − x_p ≤ k` and `x_p − x_c ≤ −k`). Run Bellman–Ford to detect infeasible exact-distance chains early, before resource search.

### 3.3 Priority order and tie-breaking (total and deterministic)

Sort the ready ops by this tuple, lexicographically:
1. **height, descending**: the critical path comes first, which is the most common priority (S14).
2. **slack, ascending**: less mobile ops first (S14 "Slackness"; zero slack = critical).
3. **fan-out, descending**: frees up more successors ("Uncover", S14). Note that EMS deliberately routes high-fanout *edges* late (S8). Here it is used only as a tie-break on ops.
4. **stable op id, ascending**: the topological index from the input graph ("Original order – when all else fails", S14).

Engineering rules for determinism (not from the literature): never iterate over Python `set`s of strings, since hash randomization varies their order; sort every candidate list explicitly; no RNG, or a fixed seed if annealing is ever added.

### 3.4 Core algorithm: operation-driven list scheduling with atomic operand routing

Use the operation-driven variant (S14) rather than cycle-driven. A TSP op is only feasible together with its operand routes, so the scheduler places "op + all incoming routes" as one unit. This mirrors Raw treating "each communication path as a single scheduling unit" (S20) and EMS, where placement falls out of routing (S8).

```
for op in priority order (3.3), re-evaluated as ops become ready:
    for fire in range(Estart(op), Estart(op) + WINDOW):     # WINDOW bounds search, cf. II-window in S13
        for unit in candidate_units(op), ordered by (routing_cost, unit_id):
            plan = []
            for each operand i (in operand order):
                need_at = fire + skew(op, i)               # exact arrival time at unit position
                plan_i = route_operand(producer(i), unit.pos, need_at)   # see ladder 3.5
                if plan_i is None: break
                plan.append(plan_i)
            else:
                if U[(unit, fire)] free and all plan reservations free:
                    commit op, plan; break out to next op
    if not committed: conflict-resolution ladder (3.5) from rung 4 upward
```

`routing_cost` follows EMS (S8): count the stream slots plus MEM port reservations consumed, plus a penalty for using a scarce resource (for example the last free lane at a position or cycle, or a MEM port that another ready op will need). Lower is better. Ties are broken by unit id.

### 3.5 Conflict-resolution ladder (try rungs in order; the first success wins)

Each rung cites the literature it borrows from. Rungs 1–3 resolve stream and unit conflicts without changing any already-committed op.

1. **Direct chain, same lane set, alternative lane.** The producer's output emerges at exactly `t_out = t_prod + d_func`. If `t_out + transit == need_at`, take the lowest-numbered free lane in the needed direction whose whole diagonal is free. *Alternative-resource resolution* (S12 "multiple alternatives"; DRESC "find alternatives to avoid congestion", S7; G2 multi-link balancing; G5 stream id + direction assignment).
2. **Alternative unit instance / direction.** Try other units of the required class, for example the mirrored hemisphere or another slice of the same type. This changes transit, and therefore which fire cycle chains directly. Ordered by routing cost (S8).
3. **Park in MEM (delay matching through memory).** If the operand arrives early (`t_out + transit < need_at`) or no direct diagonal is free, write it to a MEM slice and re-read it later: a write route from producer to slice s, a write-port reservation at the arrival cycle, an address lifetime interval, a read-port reservation at `need_at − transit(s → unit)`, and a read route from s to unit. Pick slices in order of (total slots used, slice id). This is the TSP version of the delay-FIFO/register technique (S24 "Technique 3"; S23 registers absorbed into memory tiles; DRESC register files routing "along the time axis", S7; the holdover arcs of S21). It is always legal if ports and capacity exist, so it is the main fallback.
4. **Delay the consumer.** Increment `fire`, which is the outer loop in 3.4. The only legal way to "wait" is rung 3, since streams cannot stall, so a later fire implies parking. On the instruction side, idle issue cycles become NOP/`NOP N` (G3, G5). *Delay resolution* (S14 cycle scheduler; S5/S13 window search).
5. **Retime the producer (optional, small graphs).** If one operand is early and its producer has slack, move the producer later so that the chain becomes direct and no MEM is needed. This is the retiming idea of moving delay onto the other edge (S11), applied greedily. Commit it only if the producer's new placement passes rungs 1–2 and none of its own consumers break. Otherwise skip.
6. **Re-place the source tensor.** For operands that are graph inputs or weights, try a different MEM slice or bank so the read route changes length or avoids a busy diagonal or bank. This is integrated placement as in DRESC/EMS (S7, S8) and ELI-512 bank assignment (S1).
7. **Backtrack with a budget.** Unschedule the lowest-priority committed ops that hold the blocking reservations, requeue them, place the current op, and decrement a global `budget = BUDGET_RATIO × |ops|`. To avoid ping-pong, a displaced op may not return to its previous (unit, cycle) until all other candidates fail. This is the `find_slot` "1 + prev scheduled time" rule (S13; Rau IMS, S5; S14 "unplace all conflicting ops").
8. **Fail loudly.** If the budget is exhausted, report the op, the blocking reservations and the rung reached. For a teaching tool, an explained failure beats a silent bad schedule.

### 3.6 Validation (cheap and strongly recommended)

After scheduling, replay the timetable in the simulator and assert, cycle by cycle: no double-booked `U`, `S` or `M` key; every operand's value is at `(unit.pos, fire + skew)`; every parked value's address is not overwritten before its read. This independent checker is the software analogue of the guarantee G2 says the compiler provides: "all contention ... resolved at compile-time".

### 3.7 Loops / decode

Schedule one decode step as a DAG and replay it with period = makespan, synchronized via a SYNC/NOTIFY-style time base (G2). Revisit modulo scheduling (MRT = same tables keyed by `cycle mod II`; IMS driver from S13) only if you model several independent sequences or overlap weight streaming across steps (§2.4).

---

## 4. Not found / unverified

- **Groq ISCA 2020 "Think Fast" paper (G1) full text.** Unreachable (URLs in §1). Definitions of `d_func` and `d_skew`, and the "two-dimensional scheduling ... in time and space" wording, are sourced only from secondary notes (G6) and the patent paraphrase (G5).
- **Groq's actual scheduling algorithm.** No source found describes it (list vs. ILP vs. other). Do not claim one.
- **Whether multiple TSP slices can read one passing stream value** (stream fan-out without re-emission): (unverified recollection). Check against dossier files 01/02.
- **Rau 1994 IMS full text.** Not read. The algorithm details come from Michigan EECS 583 slides (S12, S13), which present it as a course rendering of Rau's algorithm. The exact identifiers (`HeightR`, `MaxTime`, `BudgetRatio`, etc.) as written in Rau's paper are unverified.
- **Rau & Glaeser 1981 (S6), Fisher 1981 (S2), Paulin & Knight 1989 (S9), Coffman–Graham 1972 (S27), Ullman 1975 (S28).** Bibliographic metadata only; bodies not opened. Ullman's exact precedence conditions are unverified. S28's ScienceDirect page returned 403.
- **Hu's algorithm = "highest level first", optimal for unit-time tree precedence:** (unverified recollection). Only a secondary search snippet supports it. S15 confirms only that Hu's algorithm solves "a very restricted problem".
- **Davidson 1971 collision-vector theory and Kogge 1981 textbook:** (unverified recollection). Only Davidson, Shar, Thomas and Patel 1975 is confirmed, via S17's reference list. Collision-vector / forbidden-latency definitions come from search-result excerpts of course notes that I did not open.
- **Leiserson & Saxe journal version (Algorithmica 6:5–35, 1991).** Volume and pages from search metadata; content from the 1986 MIT TM-309 abstract only.
- **Corporaal, *Microprocessor Architectures: From VLIW to TTA* (Wiley, 1997/1998).** Book page unreachable. Search snippets conflict on 1997 vs. 1998. TTA claims rest on S18 (read) and S19 (tertiary).
- **Fisher's VLIW retrospective (1998).** URL redirected to a login page; not read.
- **A paper that treats exactly "operands on non-stallable pipelined wires must meet at the consumer on one cycle, with memory as the only buffer"** as a general scheduling problem: not found. The closest are S24 (delay mismatch, three remedies), S23 (branch delay matching), S22 (latency padding), S25 (no-wait scheduling theory) and Groq's own G2/G5 statements.
- **MEM slice port count.** The "one read and one write per cycle per slice" reading of G4 comes from noisy layout text extraction. Confirm before encoding it in the memory table.
