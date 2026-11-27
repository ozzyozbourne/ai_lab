export const meta = {
  name: 'dpdk-course',
  description: 'Research DPDK, plan a multi-chapter HTML course, gap-review the plan twice, build chapters in parallel with runnable code, review/verify/fix twice, final check',
  phases: [
    { title: 'Research', detail: 'parallel deep-research agents per DPDK area' },
    { title: 'Plan', detail: 'synthesize chapter plan' },
    { title: 'Gap Review 1', detail: 'find gaps in plan, then fix' },
    { title: 'Gap Review 2', detail: 'second gap round, then fix' },
    { title: 'Foundation', detail: 'shared assets, template, build scripts' },
    { title: 'Implement', detail: 'one pipeline per chapter: write, review/verify/fix x2' },
    { title: 'Final Check', detail: 'index, README, independent whole-course checks and fixes' },
  ],
}

const ROOT = '/home/user/ai_lab/dpdk_research'
const ENV = `
SHARED ENVIRONMENT (read carefully):
- Course output root: ${ROOT}  (write only inside it; never git commit/push — the orchestrator does that).
- DPDK 26.11.0 source tree (read docs and code here, it is authoritative): ${'$'}DPDK_SRC. Docs live in ${'$'}DPDK_SRC/doc/guides (prog_guide, nics, sample_app_ug, linux_gsg, etc.), headers in lib/*/rte_*.h, examples in examples/.
- An installed DPDK (static libs, pkg-config, testpmd and other tools, 90 example binaries in the build dir) is ready. Before any build/run: \`source /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh\`. Compile with: gcc x.c -o x $(pkg-config --cflags libdpdk) $(pkg-config --libs --static libdpdk). Build dir with prebuilt examples/apps: ${'$'}DPDK_SRC/build.
- Machine: 4-core Xeon VM (AVX2/AVX-512), 15 GB RAM, root, Linux 6.18. ONE real NIC (eth0, virtio) — it carries the session's network: NEVER bind it to DPDK, never attach af_packet/af_xdp to eth0. Instead use virtual devices: --vdev=net_null0, net_ring0, net_tap0 (root works), net_af_packet/net_af_xdp on a veth pair you create (ip link add <name> type veth peer name <peer>; use unique names prefixed with your chapter number and delete them afterwards), net_memif, net_vhost + virtio_user, net_pcap (with pcap files), crypto_null/crypto_openssl/crypto_scheduler, event_sw, dma_skeleton, baseband_null, compress_zlib.
- Drivers built: bus vdev/pci; mempool ring/stack/bucket; net null,ring,af_packet,af_xdp,tap,vhost,virtio,memif,bonding,pcap,failsafe; crypto null,scheduler,openssl; event sw,skeleton; dma skeleton; baseband null; compress zlib; ml null; raw skeleton.
- Hugepages: 1024 x 2MB are mounted at /dev/hugepages but SHARED with many parallel agents. Prefer --no-huge -m 256 (or less) for examples; when demonstrating hugepages use -m 64..128 at most. ALWAYS pass a unique --file-prefix=<yourchapter-or-name> (or --in-memory) so concurrent DPDK processes do not collide. Use --no-pci. Always wrap runs in timeout (e.g. timeout -s INT -k 5 20 ...) and redirect output to files (testpmd with stats-period needs SIGINT).
- Many agents run concurrently on 4 cores: keep runs short (<30s), don't run heavy builds of DPDK itself.
`

const HTML_RULES = `
CHAPTER HTML REQUIREMENTS:
- Each chapter is ${ROOT}/chapters/NN-slug/index.html, a polished, self-contained-feeling page that links the shared ../../assets/course.css and ../../assets/course.js (do NOT edit shared assets; put chapter-specific CSS/JS inline or in the chapter folder). Works opened from the file system (file://) — no build step, no network required; no external CDNs.
- Must contain: prev/next/index navigation; learning objectives; prose explaining every concept in the chapter spec from first principles, building easy -> complex; MULTIPLE diagrams (inline SVG, readable in light and dark mode) and at least two ANIMATIONS / interactive visualizations (JS/CSS/SVG — e.g. packets moving through rings, mbuf layout explorer, step-through of an algorithm, sliders that change parameters) that visualize the mechanism, not decoration; annotated code walkthroughs; the ACTUAL output captured from running the code here; a "common pitfalls" section; exercises; a summary; references to the specific DPDK source files/docs (paths relative to the DPDK tree).
- Code lives in ${ROOT}/chapters/NN-slug/code/: complete .c programs (well commented), a Makefile using pkg-config libdpdk (static), a run.sh that builds and runs every example with the right EAL args and vdevs (self-cleaning, uses timeout, unique --file-prefix), and expected_output.txt with real captured output. Every example MUST compile with -Wall without errors and MUST actually be run by you; never fabricate output. Code that genuinely cannot run here (needs real NIC/hardware) must be clearly marked as such, and still compile, with the reason stated.
- Also write ${ROOT}/chapters/NN-slug/README.md (short: what's here, how to run).
- Accuracy: verify API names, signatures and behaviour against the 26.11 headers in ${'$'}DPDK_SRC/lib, not memory.
- Write plain, clear English for a programmer who knows C and basic networking but not DPDK.
`

const NOTE_SCHEMA = { type: 'object', properties: { file: { type: 'string' }, summary: { type: 'string' } }, required: ['file', 'summary'] }

const AREAS = [
  ['01-overview-history-architecture', 'DPDK big picture: history, goals, why kernel bypass, user-space drivers, poll-mode vs interrupts, run-to-completion vs pipeline models, the overall architecture and library map, licensing, release cadence, ecosystem (OVS-DPDK, VPP, SPDK, F-Stack, TRex, Seastar), comparison with AF_XDP/io_uring/netmap/RDMA.'],
  ['02-eal', 'Environment Abstraction Layer: rte_eal_init, EAL args, lcores, main/worker lcores, rte_eal_remote_launch, service cores, lcore variables, threads/affinity, logging (rte_log), timers/TSC cycles, multi-process (primary/secondary), IOVA modes, VFIO/UIO, device probing, buses, devargs, hotplug, EAL cleanup.'],
  ['03-memory', 'Memory: hugepages, memsegs, memzones, rte_malloc, NUMA/sockets, IOVA/physical addressing, --no-huge/--in-memory, legacy vs dynamic memory, external memory, memory alignment/cache lines, false sharing, prefetching.'],
  ['04-mbuf-mempool-ring', 'rte_ring (lock-free MPMC/SPSC, RTS/HTS modes, peek, burst/bulk, zero-copy), rte_mempool (per-lcore caches, ops/handlers ring/stack/bucket), rte_mbuf (layout, headroom/tailroom, chained segments, refcnt, indirect/external buffers, offload flags, dynfields/dynflags, packet types, pktmbuf pool creation), rte_stack, rte_reorder.'],
  ['05-ethdev', 'ethdev: port lifecycle (configure, queue setup, start), rx/tx burst, descriptors, offloads (checksum, TSO, VLAN), RSS and RETA, multiple queues, link status, stats/xstats, promiscuous, MTU, callbacks, rte_flow (patterns/actions, validate/create, flow isolation, async flow API), traffic manager, metering, PTP, ethdev telemetry, how a PMD is structured (eth_dev_ops, rx/tx functions, vectorized paths), PMD guide doc nics/.'],
  ['06-virtual-devices-and-virtio', 'Virtual and software PMDs: net_null, net_ring, net_tap, af_packet, af_xdp, pcap, memif, bonding, failsafe, vhost-user library and net_vhost, virtio-user / virtio PMD, vDPA, KNI removal history, how to test without hardware, testpmd usage and commands, dumpcap/pdump/pcapng.'],
  ['07-packet-processing-libs', 'Packet-processing libraries: lib/net headers and helpers (rte_ether, rte_ip, cksum), hash (cuckoo, rte_hash API, RCU-safe), LPM/LPM6, FIB/RIB, ACL, EFD, member, ip_frag, GRO/GSO, meter, sched (QoS hierarchical scheduler), policer, BPF, pipeline/port/table libs, graph + node library (l3fwd-graph), distributor, IPsec library, PDCP. Classic sample apps: l2fwd, l3fwd, ipsec-secgw.'],
  ['08-crypto-event-accel', 'Accelerator frameworks: cryptodev (sessions, symmetric/asymmetric ops, crypto_null/openssl/scheduler), security library, compressdev, eventdev (event scheduling, atomic/ordered/parallel queues, event_sw, adapters: eth rx/tx, timer, crypto), dmadev, bbdev, gpudev, mldev, regexdev, rawdev.'],
  ['09-performance-concurrency', 'Performance and concurrency: cache lines, burst sizes, vector PMD paths (SSE/AVX2/AVX512), prefetch, branch prediction (likely/unlikely), batching, lock-free design, rte_atomic vs C11 atomics, rte_spinlock/rwlock/ticketlock/seqlock/MCS, RCU (rte_rcu_qsbr), memory ordering, NUMA awareness, isolcpus/nohz_full, power management (l3fwd-power, PMD power mgmt, rte_power), measuring with rte_rdtsc, telemetry, perf, benchmarking methodology, common performance traps.'],
  ['10-building-debugging-ecosystem', 'Developer workflow: building with meson/ninja, pkg-config, static vs shared, writing an app (examples/skeleton), cmdline library, telemetry, rte_trace, proc-info, debugging tips, testing (app/test, DTS), contributing, ABI/API stability policy, cross-compiling, Windows/FreeBSD support, real deployments and case studies, and how to build a minimal user-space UDP/IP responder on DPDK (ARP + ICMP + UDP echo) as a capstone.'],
]

phase('Research')
const notes = await parallel(AREAS.map(([key, topic]) => () => agent(
  `You are a deep-research agent preparing material for a comprehensive DPDK course (from beginner to expert).\n${ENV}\nYOUR AREA: ${topic}\n\nResearch it deeply: read the relevant docs in $DPDK_SRC/doc/guides, the headers and implementation in $DPDK_SRC/lib and drivers, and the sample apps in examples/. Use the web (WebSearch / web fetch) for history, design rationale, talks, papers and real-world usage where useful. Do quick experiments if they clarify how something actually behaves on this machine (respecting the environment rules).\n\nWrite a thorough research note to ${ROOT}/research/${key}.md containing: the concepts (precise, with API names and file paths), how they work internally, how they relate to each other, the right order to teach them (easy -> hard), concrete runnable example ideas that work on THIS machine (with which vdevs/args), visualization/animation ideas that would make the mechanisms clear, common pitfalls, and source references. Be detailed (this note feeds a course planner). Return the file path and a ~200-word summary.`,
  { label: `research:${key}`, phase: 'Research', schema: NOTE_SCHEMA })))
const noteFiles = notes.filter(Boolean).map(n => n.file)
log(`Research notes: ${noteFiles.length}/${AREAS.length}`)

const CHAPTER = {
  type: 'object',
  properties: {
    num: { type: 'integer' }, slug: { type: 'string' }, title: { type: 'string' },
    level: { type: 'string' }, summary: { type: 'string' },
    prerequisites: { type: 'array', items: { type: 'integer' } },
    concepts: { type: 'array', items: { type: 'string' } },
    apis: { type: 'array', items: { type: 'string' } },
    code_examples: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, description: { type: 'string' }, how_to_run_here: { type: 'string' } }, required: ['name', 'description', 'how_to_run_here'] } },
    visualizations: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, kind: { type: 'string' }, description: { type: 'string' } }, required: ['name', 'kind', 'description'] } },
    exercises: { type: 'array', items: { type: 'string' } },
    sources: { type: 'array', items: { type: 'string' } },
  },
  required: ['num', 'slug', 'title', 'level', 'summary', 'prerequisites', 'concepts', 'apis', 'code_examples', 'visualizations', 'exercises', 'sources'],
}
const PLAN_SCHEMA = {
  type: 'object',
  properties: { course_title: { type: 'string' }, audience: { type: 'string' }, design_notes: { type: 'string' }, chapters: { type: 'array', items: CHAPTER } },
  required: ['course_title', 'audience', 'design_notes', 'chapters'],
}
const GAP_SCHEMA = {
  type: 'object',
  properties: { gaps: { type: 'array', items: { type: 'object', properties: { severity: { type: 'string', enum: ['high', 'medium', 'low'] }, chapter: { type: 'string' }, issue: { type: 'string' }, recommendation: { type: 'string' } }, required: ['severity', 'chapter', 'issue', 'recommendation'] } } },
  required: ['gaps'],
}

phase('Plan')
let plan = await agent(
  `You are the lead course designer for a complete DPDK course, beginner to expert.\n${ENV}\nRead ALL these research notes in full: ${noteFiles.join(', ')}. Also skim $DPDK_SRC/doc/guides/prog_guide/index.rst to make sure no major library is forgotten.\n\nDesign the course: between 18 and 28 chapters (your choice), ordered strictly easy -> complex, each chapter independent enough to be written in parallel by a separate author but building on earlier ones (state prerequisites). Start from "what is a packet / why kernel bypass" and end with expert topics and a capstone (e.g. a tiny UDP/IP stack with ARP+ICMP+UDP echo on a tap or veth). Cover every concept of the library at an appropriate depth. For each chapter specify concepts, exact APIs, 2-5 runnable code examples that work on THIS machine (state vdevs/args), 3+ visualizations (diagrams + at least 2 animations/interactive), exercises, sources. slug format: lowercase-words (no number; the folder will be NN-slug with NN zero-padded num).\n\nAlso write the plan as human-readable markdown to ${ROOT}/PLAN.md. Return the plan object.\n${HTML_RULES}`,
  { label: 'plan:v1', phase: 'Plan', schema: PLAN_SCHEMA })

const LENSES = [
  'TECHNICAL COVERAGE: compare the plan against every library/driver class/concept in the DPDK 26.11 tree and docs (lib/, drivers/, doc/guides/prog_guide). What important concepts, APIs, or mechanisms are missing, shallow, misplaced or inaccurate (check API names against headers)?',
  'PEDAGOGY & PROGRESSION: is the order truly easy -> complex? Are there conceptual jumps, missing bridges, overloaded chapters, chapters that should split/merge, prerequisites that are wrong, weak capstone, missing "why" motivation? Are visualizations actually explaining mechanisms?',
  'RUNNABILITY ON THIS MACHINE: for every proposed code example, check it can really compile and run here with the listed vdevs/args (try quick probes if needed: e.g. does net_tap/af_xdp on veth work, does crypto_openssl load, does event_sw run). Flag examples that cannot run and propose working alternatives.',
  'LEARNER & PRACTITIONER VIEW: as a network engineer adopting DPDK for production, what practical topics are missing (debugging, tuning, deployment, testpmd skills, telemetry, multi-process, failure modes, security, measuring performance honestly, integration with Linux like tap/af_xdp/control plane)?',
]

async function gapRound(n, current) {
  const ph = `Gap Review ${n}`
  const planJson = JSON.stringify(current)
  const reviews = await parallel(LENSES.map((lens, i) => () => agent(
    `You are reviewing a draft DPDK course plan to find GAPS. Lens: ${lens}\n${ENV}\nResearch notes are in ${ROOT}/research/ (read what you need). Investigate the DPDK source/docs and the web to back up your points. Be concrete and actionable; don't pad.\n\nPLAN JSON:\n${planJson}`,
    { label: `gaps${n}:lens${i + 1}`, phase: ph, schema: GAP_SCHEMA })))
  const gaps = reviews.filter(Boolean).flatMap(r => r.gaps)
  log(`Gap round ${n}: ${gaps.length} gaps found`)
  const revised = await agent(
    `You are the lead course designer. Revise the DPDK course plan to address the gap-review findings below. For each finding decide: accept (fix it), or reject with reason (only if it's wrong — verify against source/docs). Keep 18-28 chapters, strict easy -> complex order, renumber consistently.\n${ENV}\nRewrite ${ROOT}/PLAN.md with the revised plan and append a section "Revision ${n} changelog" listing each finding and how it was handled. Return the full revised plan object.\n${HTML_RULES}\n\nCURRENT PLAN JSON:\n${planJson}\n\nGAP FINDINGS:\n${JSON.stringify(gaps)}`,
    { label: `plan:v${n + 1}`, phase: ph, schema: PLAN_SCHEMA })
  return revised || current
}
plan = await gapRound(1, plan)
plan = await gapRound(2, plan)
const chapters = plan.chapters.slice().sort((a, b) => a.num - b.num)
const dirOf = c => `${String(c.num).padStart(2, '0')}-${c.slug}`
const toc = chapters.map(c => `${dirOf(c)}: ${c.title}`).join('\n')
log(`Final plan: ${chapters.length} chapters`)

phase('Foundation')
await agent(
  `Build the shared foundation for an HTML DPDK course titled "${plan.course_title}".\n${ENV}\nCreate in ${ROOT}:\n1. assets/course.css — a clean, modern, readable design system: CSS custom properties on :root with a dark-mode set under @media (prefers-color-scheme: dark), typography, layout (max-width content, sidebar/top nav, responsive to phone width with no horizontal scroll), code blocks, callouts (note/warning/pitfall/tip), figure/diagram frames, tables, nav bar (prev/index/next), objective boxes, exercise boxes, output blocks (terminal style), SVG helper classes (.svg-box, .svg-arrow, .svg-packet, .svg-label, colors via CSS vars so inline SVG works in both themes).\n2. assets/course.js — small dependency-free helpers chapters can use: a Stepper (step-through animation with prev/next/play controls and captions), an Animator (requestAnimationFrame loop with play/pause/speed), simple SVG element builders, a copy-to-clipboard for code blocks, a lightweight C syntax highlighter (no external libs), a tab switcher. Document the API at the top of the file.\n3. assets/README.md documenting the CSS classes and JS API with examples.\n4. assets/demo.html showing every component (including one working animation) so chapter authors can copy patterns.\n5. common/build_dpdk.sh — a script for READERS to clone DPDK (v26.11 tag), install dependencies on Debian/Ubuntu, build and install to a prefix, and print the PKG_CONFIG_PATH; plus common/env.sh.example; common/setup_hugepages.sh; common/Makefile.inc reusable by chapter Makefiles (pkg-config static build, -O2 -Wall).\n6. _template/CHAPTER_TEMPLATE.html — the skeleton every chapter should follow (nav, header, objectives, sections, figures, code, output, pitfalls, exercises, summary, references, nav).\nTest that demo.html renders without JS errors using Playwright (require('playwright'), chromium.launch()), screenshot it at deviceScaleFactor 1 in light and dark, look at them, and fix any issues. Return a short summary of the API chapter authors must use.\n\nCOURSE TOC (for context):\n${toc}`,
  { label: 'foundation', phase: 'Foundation' })

const FINDINGS = {
  type: 'object',
  properties: { findings: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, severity: { type: 'string', enum: ['high', 'medium', 'low'] }, category: { type: 'string' }, location: { type: 'string' }, problem: { type: 'string' }, suggested_fix: { type: 'string' } }, required: ['id', 'severity', 'category', 'location', 'problem', 'suggested_fix'] } } },
  required: ['findings'],
}
const VERDICTS = {
  type: 'object',
  properties: { verdicts: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, confirmed: { type: 'boolean' }, reasoning: { type: 'string' } }, required: ['id', 'confirmed', 'reasoning'] } } },
  required: ['verdicts'],
}

function reviewRound(c, n) {
  const d = `${ROOT}/chapters/${dirOf(c)}`
  return async () => {
    const rev = await agent(
      `Review round ${n} of DPDK course chapter ${dirOf(c)} at ${d}. Be a demanding, independent reviewer.\n${ENV}\n${HTML_RULES}\nCHAPTER SPEC:\n${JSON.stringify(c)}\n\nCheck: (a) technical accuracy of every claim and API against the 26.11 headers/docs in $DPDK_SRC; (b) every concept and example in the spec is covered and explained clearly, easy -> complex; (c) code: rebuild with make and run run.sh yourself; check it compiles cleanly with -Wall, runs, output matches expected_output.txt and what the HTML shows; check resource cleanup and error handling; (d) diagrams/animations: load the page with Playwright (chromium, file:// URL), capture console errors, screenshot at deviceScaleFactor 1 (light + dark via colorScheme, plus a 390px-wide viewport), look at the screenshots: broken layout, unreadable SVG in dark mode, animations that don't work, horizontal overflow; (e) navigation links and references resolve; (f) missing pitfalls/exercises/summary. Do NOT modify files. Return findings (empty if none). Delete any scratch files/veths you create.`,
      { label: `review${n}:${c.num}`, phase: 'Implement', schema: FINDINGS })
    const findings = rev ? rev.findings : []
    if (!findings.length) return `round ${n}: no findings`
    const ver = await agent(
      `You are an independent verifier. A reviewer reported the findings below about DPDK course chapter ${dirOf(c)} at ${d}. For EACH finding, check it yourself against the actual files, by running code/Playwright, and against $DPDK_SRC headers/docs. Mark confirmed=true only if it is real and worth fixing; mark false if it is wrong, already fine, or not reproducible. Do not modify files.\n${ENV}\nFINDINGS:\n${JSON.stringify(findings)}`,
      { label: `verify${n}:${c.num}`, phase: 'Implement', schema: VERDICTS })
    const ok = new Set((ver ? ver.verdicts : []).filter(v => v.confirmed).map(v => v.id))
    const confirmed = findings.filter(f => ok.has(f.id))
    if (!confirmed.length) return `round ${n}: ${findings.length} findings, 0 confirmed`
    await agent(
      `Fix these VERIFIED problems in DPDK course chapter ${dirOf(c)} at ${d}. After fixing, rebuild and re-run the code (update expected_output.txt and the output shown in HTML if output changed), and re-check the page with Playwright for console errors. Don't touch shared assets or other chapters. Return a short summary of what changed.\n${ENV}\n${HTML_RULES}\nCHAPTER SPEC:\n${JSON.stringify(c)}\n\nCONFIRMED FINDINGS:\n${JSON.stringify(confirmed)}`,
      { label: `fix${n}:${c.num}`, phase: 'Implement' })
    return `round ${n}: ${findings.length} findings, ${confirmed.length} confirmed+fixed`
  }
}

phase('Implement')
const results = await pipeline(chapters,
  c => agent(
    `Write chapter ${dirOf(c)} of the DPDK course "${plan.course_title}" (audience: ${plan.audience}).\n${ENV}\n${HTML_RULES}\nFirst read ${ROOT}/assets/README.md, ${ROOT}/assets/demo.html and ${ROOT}/_template/CHAPTER_TEMPLATE.html and use the shared components. Read relevant research notes in ${ROOT}/research/ and the DPDK sources/docs. Write everything into ${ROOT}/chapters/${dirOf(c)}/. Write and actually run every code example, capturing real output. Then load the page with Playwright (file://) to make sure there are no console errors, the animations run, and screenshots (deviceScaleFactor 1, light and dark, plus 390px width) look right; fix what you see. Clean up any veths/processes you create.\n\nDESIGN NOTES FOR THE WHOLE COURSE:\n${plan.design_notes}\n\nFULL TOC (for prev/next links and cross-references; link as ../NN-slug/index.html; index is ../../index.html):\n${toc}\n\nYOUR CHAPTER SPEC:\n${JSON.stringify(c)}\n\nReturn a short summary: files written, examples and whether each ran, visualizations built.`,
    { label: `write:${c.num}`, phase: 'Implement' }),
  (w, c) => reviewRound(c, 1)().then(r1 => [w, r1]),
  (prev, c) => reviewRound(c, 2)().then(r2 => ({ chapter: dirOf(c), write: prev[0], round1: prev[1], round2: r2 })),
)

phase('Final Check')
await agent(
  `Create the course entry points in ${ROOT}.\n${ENV}\n1. ${ROOT}/index.html — a visual table of contents using the shared assets: course title "${plan.course_title}", intro, a reading-path / dependency diagram (SVG) of chapters, chapter cards (number, title, level, one-line summary, link to chapters/NN-slug/index.html), how to set up DPDK (link common/build_dpdk.sh). Include one small animation (e.g. a packet journeying NIC -> ring -> mbuf -> app) as hero.\n2. ${ROOT}/README.md — what the course is, who it's for, prerequisites, table of contents with links, how to build DPDK and run all examples, environment notes (virtual devices, no real NIC needed), known limitations.\n3. ${ROOT}/run_all.sh — runs every chapter's code/run.sh in order, reports pass/fail per chapter.\nRead each chapter's README.md to get accurate summaries. Verify all links in index.html resolve. Chapters:\n${toc}`,
  { label: 'index+readme', phase: 'Final Check' })

const CHECKS = [
  'BUILD & RUN: run ' + ROOT + '/run_all.sh (or each chapter run.sh one at a time). For every chapter record: compiles with -Wall cleanly? runs? output consistent with expected_output.txt? Report failures precisely.',
  'PAGES & LINKS: with Playwright load index.html and every chapter page via file://; collect console errors, failed resource loads, broken internal links (follow every href that is a relative path), missing nav, horizontal overflow at 390px, dark-mode readability (screenshot a sample). Report every problem.',
  'CONTENT COMPLETENESS & ACCURACY: compare every chapter against its spec in PLAN.md; check each chapter has objectives, multiple diagrams, at least two working animations/interactive visuals, code walkthrough, real output, pitfalls, exercises, summary, references; spot-check 3+ technical claims per chapter against $DPDK_SRC headers/docs. Check consistency of terminology across chapters and that the progression is coherent.',
]
const finalFindings = (await parallel(CHECKS.map((ck, i) => () => agent(
  `Independent final check of the whole DPDK course at ${ROOT}. Do NOT modify files.\n${ENV}\nCHECK: ${ck}\nReturn findings with location = file path.`,
  { label: `final-check:${i + 1}`, phase: 'Final Check', schema: FINDINGS })))).filter(Boolean).flatMap(r => r.findings)
log(`Final check: ${finalFindings.length} findings`)
let finalFix = 'nothing to fix'
if (finalFindings.length) {
  const ver = await agent(
    `Independently verify each of these final-check findings about the DPDK course at ${ROOT} (inspect files, run code, use Playwright). confirmed=true only if real. Do not modify files.\n${ENV}\nFINDINGS:\n${JSON.stringify(finalFindings)}`,
    { label: 'final-verify', phase: 'Final Check', schema: VERDICTS })
  const ok = new Set((ver ? ver.verdicts : []).filter(v => v.confirmed).map(v => v.id))
  const confirmed = finalFindings.filter(f => ok.has(f.id))
  if (confirmed.length) {
    finalFix = await agent(
      `Fix these verified problems in the DPDK course at ${ROOT}. Re-run affected code and re-check affected pages afterwards. Then run ${ROOT}/run_all.sh and report the final per-chapter pass/fail table.\n${ENV}\n${HTML_RULES}\nFINDINGS:\n${JSON.stringify(confirmed)}`,
      { label: 'final-fix', phase: 'Final Check' })
  } else finalFix = `${finalFindings.length} findings, none confirmed`
}
return { course_title: plan.course_title, chapters: chapters.map(dirOf), results, finalFindings: finalFindings.length, finalFix }
