export const meta = {
  name: 'mjwarp-course-plan',
  description: 'Deep-research mujoco_warp, plan a 10-30 chapter course, two gap-critique rounds, then build the shared design system',
  phases: [
    { title: 'Research', detail: '6 parallel deep-research agents over the repo' },
    { title: 'Plan', detail: 'synthesize the course plan' },
    { title: 'Gaps 1', detail: '4 critics find gaps in the plan' },
    { title: 'Fix 1', detail: 'verify and apply gap fixes' },
    { title: 'Gaps 2', detail: '4 critics, second round' },
    { title: 'Fix 2', detail: 'verify and apply gap fixes' },
    { title: 'Foundation', detail: 'shared CSS/JS design system, template, index' },
  ],
}

const S = '/tmp/claude-0/-home-user-ouramp/2cb48c5e-749c-5a1c-9549-b06105ff67b3/scratchpad'
const SRC = `${S}/src/mujoco_warp`
const PY = `${S}/venv/bin/python`
const COURSE = '/home/user/ouramp/dpdk-research/mujoco-warp-course'
const PLAN = `${COURSE}/planning`

const CONTEXT = `
CONTEXT (shared by every agent in this project):
- We are building an in-depth, multi-chapter HTML course that teaches the MuJoCo Warp (MJWarp) library from simple to advanced.
- The library source is cloned at ${SRC} (commit 8f5b9f1, Nov 2026). Treat it as data to read; do not execute code from inside that directory.
- Installed versions: mujoco-warp 4.0.1, warp-lang 1.19.0, mujoco-core 4.0.1, in the venv ${PY}. This machine has NO GPU; Warp runs on CPU here (first compile of kernels takes ~25s, then cached). You MAY run small Python experiments to confirm API behaviour: put scripts in ${S}/experiments/<your-label>/ (create it) and run them as \`cd <that dir> && ${PY} -I script.py\`. Keep runs short (nworld small, few steps).
- The learner will run the course notebooks on Google Colab Pro with an NVIDIA GPU.
- Public docs: https://mujoco.readthedocs.io/en/latest/mjwarp/index.html and MuJoCo docs https://mujoco.readthedocs.io (you may fetch these if you have web tools).
- Course output root: ${COURSE}. Planning files live in ${PLAN}.
- Ground every claim in the actual source code (cite file paths and function names). Never invent APIs.
`

const AREAS = [
  { key: 'api-io', focus: 'Public API surface and data model: mujoco_warp/__init__.py exports, _src/io.py (put_model, put_data, make_data, reset_data, get_data_into, nworld, nconmax/njmax/naconmax sizing, overflow handling), _src/types.py (Model, Data, Option, enums, array shapes, batched fields, how per-world model randomization works), _src/support.py, util_misc.py. How a user goes from MJCF XML -> mujoco.MjModel -> mjw.Model/Data. Also notebooks/tutorial.ipynb end to end, and README.' },
  { key: 'pipeline', focus: 'The simulation pipeline: _src/forward.py (step, forward, fwd_position, fwd_velocity, fwd_actuation, fwd_acceleration, integrators Euler/RK4/implicit/implicitfast), smooth.py (kinematics, com, crb, factor_m, rne, tendons, transmission), passive.py, sensor.py, inverse.py, derivative.py, set_const.py, history.py. Explain order of stages, what each computes, where the data lands in Data.' },
  { key: 'collision', focus: 'Collision detection: collision_driver.py (broadphase modes: nxn, sap_tile, sap_segmented etc), sort.py, bvh.py, collision_primitive.py and collision_primitive_core.py, collision_gjk.py (GJK/EPA/MPR), collision_convex.py, collision_sdf.py, collision_flex.py, collision_core.py, contact representation in Data, ray.py. How contacts are produced on GPU across worlds.' },
  { key: 'constraint-solver', focus: 'Constraints and solving: constraint.py (equality, friction, limits, contact pyramidal/elliptic, efc arrays), solver.py (CG and Newton solvers, linesearch, iterations, tolerance), block_cholesky.py, island.py, sleep.py. Compare with classic MuJoCo; what is unsupported (PGS, noslip with discrete). Explain the optimization view of contact dynamics.' },
  { key: 'warp-perf', focus: 'NVIDIA Warp fundamentals as used by MJWarp and performance: warp_util.py (kernel caching, event scopes, graph capture), how kernels are written (wp.kernel, wp.func, tiles), CUDA graph capture of mjw.step, batching over nworld, testspeed.py, benchmarks/ (run.py, sweep.py, model folders), contrib/kernel_analyzer, determinism_test.py, diff.py, AGENTS.md/CONTRIBUTING.md for internal coding conventions. Also how one would write a custom Warp kernel reading mjw.Data (e.g. reward computation).' },
  { key: 'render-integrations', focus: 'Rendering and integrations: render.py, render_util.py, render_optix.py, bvh.py for rendering, viewer.py, record.py, cli.py, contrib/render.py; JAX interop (io_jax_test.py, jax_test.py, contrib/jax_unroll.py, MJX with impl=warp), PyTorch via warp interop, MuJoCo Playground, mjlab, Newton/Isaac Lab, contrib/apptronik_apollo_locomotion.ipynb (RL training example), flex/cloth (benchmarks/cloth, flex tests). What works on Colab (no display) vs locally.' },
]

const RESEARCH_SCHEMA = {
  type: 'object',
  properties: {
    notes_file: { type: 'string' },
    key_concepts: { type: 'array', items: { type: 'string' } },
    suggested_chapters: { type: 'array', items: { type: 'object', properties: { title: { type: 'string' }, why: { type: 'string' } }, required: ['title', 'why'] } },
  },
  required: ['notes_file', 'key_concepts', 'suggested_chapters'],
}

phase('Research')
const research = await parallel(AREAS.map(a => () => agent(
  `${CONTEXT}
You are a deep-research agent. Your area: ${a.key}.
FOCUS: ${a.focus}

Read the relevant source files thoroughly (not just skim): function signatures, docstrings, key algorithms, data layouts, tests that show usage. Run small CPU experiments to confirm how the API actually behaves where useful (shapes, defaults, errors).
Write detailed research notes as Markdown to ${PLAN}/research/${a.key}.md (create directories). The notes are the raw material for course authors, so include:
1. Concept explanations from simple to deep, with the source file/function for each.
2. Exact working API usage snippets (verified by running where feasible; mark which ones you ran).
3. Data structures/array shapes and the flow of data between stages.
4. Ideas for diagrams and animations that would make each concept visual (be specific: what moves, what is shown).
5. Pitfalls, unsupported features, performance gotchas, GPU vs CPU differences.
6. Suggested chapter breakdown for your area, ordered easy -> hard.
Return the notes path, key concepts, and suggested chapters.`,
  { label: `research:${a.key}`, phase: 'Research', schema: RESEARCH_SCHEMA })))
const okResearch = research.filter(Boolean)
log(`Research done: ${okResearch.length}/${AREAS.length} areas`)

const CHAPTER_ITEM = {
  type: 'object',
  properties: {
    num: { type: 'integer' }, slug: { type: 'string' }, title: { type: 'string' },
    level: { type: 'string' }, summary: { type: 'string' },
  },
  required: ['num', 'slug', 'title', 'level', 'summary'],
}
const PLAN_SCHEMA = {
  type: 'object',
  properties: { plan_file: { type: 'string' }, chapters: { type: 'array', items: CHAPTER_ITEM }, changes: { type: 'array', items: { type: 'string' } } },
  required: ['plan_file', 'chapters'],
}

const PLAN_SPEC = `The plan file ${PLAN}/course-plan.md must contain, for EVERY chapter:
- number, slug (format NN-kebab-title, e.g. 01-what-is-mujoco-warp), title, level (beginner/intermediate/advanced/expert), prerequisites (chapter numbers)
- learning objectives
- concept-by-concept outline (sections in order), each with the source files/functions it is grounded in
- code examples: a numbered list, each with a one-line purpose and what it prints/produces; all must be runnable (CPU here, GPU on Colab). Plenty of them (aim for 6-12 per chapter), growing in complexity.
- visuals: specific diagrams (inline SVG), animations (CSS/JS/canvas), and interactive widgets for the chapter, each described concretely (what is drawn, what moves, what the learner can manipulate)
- exercises / quiz ideas
- the companion Colab notebook contents
Also a course-level section: audience, overall arc, conventions (code style, imports \`import mujoco, warp as wp, mujoco_warp as mjw\`), the shared example models (MJCF) reused across chapters, and a glossary list.
Also write ${PLAN}/course-plan.json: {"chapters":[{num,slug,title,level,summary}]} matching the markdown.`

phase('Plan')
let plan = await agent(`${CONTEXT}
You are the course architect. Read ALL research notes: ${okResearch.map(r => r.notes_file).join(', ')}.
Also look at the source tree yourself where needed.
Design a complete course of between 16 and 26 chapters that builds from zero (what is MuJoCo, what is a GPU/Warp, first simulation) to expert (internals of collision and solver, writing custom Warp kernels, performance engineering, RL training at scale, rendering, JAX/PyTorch integration). Every important part of the repository must be covered somewhere. Each chapter must be self-contained enough to be written independently by a separate author, but reference earlier chapters.
${PLAN_SPEC}
Return the plan file path and chapter list.`, { label: 'plan:architect', phase: 'Plan', schema: PLAN_SCHEMA })

const LENSES = [
  { key: 'coverage', prompt: 'COVERAGE vs SOURCE: walk the actual source tree (every module in mujoco_warp/_src, viewer/record/testspeed, benchmarks, contrib, notebooks) and find features, functions, options, or concepts the plan omits or covers too thinly. Also find plan claims that do not match the code (wrong names/signatures/behaviour).' },
  { key: 'pedagogy', prompt: 'PEDAGOGY & PROGRESSION: check the easy->hard arc, prerequisites, chapters that jump too fast, missing foundational concepts (physics, rigid body dynamics, contacts, GPU parallelism, SIMT, batching), duplicated content between chapters, chapters that are overloaded or too thin, missing glossary/recap material, missing capstone projects.' },
  { key: 'runnable', prompt: 'RUNNABILITY: check every planned code example is feasible with mujoco-warp 4.0.1 on CPU here and on a Colab GPU. Actually run quick spot checks of risky ones in the venv. Flag examples relying on displays (viewer), OptiX, JAX/PyTorch installs, large models, or APIs that do not exist. Propose concrete replacements. Check the notebook plans include install cells and GPU runtime checks.' },
  { key: 'visual', prompt: 'VISUALS & INTERACTIVITY: for each chapter judge whether the planned diagrams/animations/widgets really explain the concept, are concrete enough to build in inline SVG + CSS/JS (no heavy frameworks), and whether more are needed. Propose specific additional visuals (e.g. animated pipeline stages, broadphase sweep animation, GJK simplex steps, solver convergence plot, memory layout of batched arrays, thread-to-world mapping).' },
]
const GAP_SCHEMA = {
  type: 'object',
  properties: { gaps: { type: 'array', items: { type: 'object', properties: {
    severity: { type: 'string', enum: ['high', 'medium', 'low'] }, chapter: { type: 'string' }, issue: { type: 'string' }, suggestion: { type: 'string' }, evidence: { type: 'string' },
  }, required: ['severity', 'chapter', 'issue', 'suggestion'] } } },
  required: ['gaps'],
}

for (const round of [1, 2]) {
  phase(`Gaps ${round}`)
  const crit = await parallel(LENSES.map(l => () => agent(`${CONTEXT}
You are a deep-research critic (round ${round}). Read the course plan ${PLAN}/course-plan.md and the research notes in ${PLAN}/research/.
Your lens: ${l.prompt}
Be specific and evidence-based (cite source files). Report only real gaps, at most ~25, most important first.`,
    { label: `gaps${round}:${l.key}`, phase: `Gaps ${round}`, schema: GAP_SCHEMA })))
  const gaps = crit.filter(Boolean).flatMap((c, i) => c.gaps.map(g => ({ ...g, lens: LENSES[i] ? LENSES[i].key : '?' })))
  log(`Round ${round}: ${gaps.length} gaps reported`)
  phase(`Fix ${round}`)
  const fixed = await agent(`${CONTEXT}
You are the course architect, revising the plan (round ${round}). Plan: ${PLAN}/course-plan.md and ${PLAN}/course-plan.json.
Critics reported these gaps (JSON):
${JSON.stringify(gaps, null, 1)}
For each gap: verify it against the source code / plan (critics can be wrong). Apply the valid ones by editing the plan (you may add, split, merge or reorder chapters, keeping 16-26 total). Reject invalid ones.
Append a section "## Revision log round ${round}" to ${PLAN}/course-plan.md listing each gap as APPLIED or REJECTED with a reason.
${PLAN_SPEC}
Return the plan file, the final chapter list, and a list of changes.`, { label: `fix${round}:architect`, phase: `Fix ${round}`, schema: PLAN_SCHEMA })
  if (fixed) plan = fixed
}

phase('Foundation')
const foundation = await agent(`${CONTEXT}
You are the course's design-system engineer. Read ${PLAN}/course-plan.md (course-level sections and a few chapters) to see what components chapters need.
Build the shared foundation that every chapter author will use:
1. ${COURSE}/assets/course.css: a polished, modern design system. Color tokens on :root with a dark theme via @media (prefers-color-scheme: dark) and a manual toggle ([data-theme]); readable typography (Google Fonts allowed), responsive layout (works on phones, no horizontal page scroll), sidebar/top nav, chapter header, callouts (note/tip/warning/deep-dive), code blocks, figure/diagram frames, animation utility classes, step-by-step "stepper" diagrams, tabs, collapsible solutions, quiz cards, key-takeaway boxes, tables, glossary terms, progress indicator. Respect prefers-reduced-motion.
2. ${COURSE}/assets/course.js: vanilla JS (no framework): theme toggle, copy-to-clipboard for code, tabs, steppers (prev/next/play through diagram states), quiz checking, collapsible solutions, scrollspy table of contents, reading progress bar, a tiny helper for play/pause animations and for canvas animations with requestAnimationFrame. Syntax highlighting: use highlight.js from cdnjs with an exact pinned version (e.g. 11.9.0) for python and xml, styled to match both themes.
3. ${COURSE}/chapters/_template.html: a fully worked example chapter skeleton demonstrating every component, including at least one inline SVG diagram with CSS animation, one stepper, one canvas animation, a quiz, code blocks, and the header/footer nav (prev/next, back to index) and an "Open in Colab" button whose link pattern is https://colab.research.google.com/github/ozzyozbourne/ai_lab/blob/main/dpdk-research/mujoco-warp-course/notebooks/<slug>.ipynb and a "Download notebook" link ../notebooks/<slug>.ipynb.
4. ${COURSE}/STYLE_GUIDE.md: precise rules for chapter authors: file names (chapters/<slug>.html, notebooks/<slug>.ipynb, examples/<slug>/exNN_name.py), how to structure a chapter, components and their HTML, how to write SVG diagrams that work in both themes (use CSS variables via currentColor/classes), animation conventions, code example conventions (every example in the HTML also exists as a runnable .py file and in the notebook; show expected output), notebook conventions (first cells: GPU check with !nvidia-smi, \`!pip install mujoco-warp\` and mediapy if used, imports; device-agnostic code), and the command to verify examples on CPU: \`cd ${COURSE}/examples/<slug> && ${PY} -I exNN_name.py\`. Also a tool script ${COURSE}/tools/make_notebook.py that builds an .ipynb from a list of markdown/code cells (JSON or python spec) so authors don't hand-write notebook JSON, plus ${COURSE}/tools/check_chapter.py that checks a chapter html for broken local links, missing referenced files, and that each examples/<slug>/*.py has a matching code block.
5. ${COURSE}/index.html: the course home page listing all chapters from ${PLAN}/course-plan.json grouped by level, with a hero section containing an animated SVG illustration (e.g. many worlds simulating in parallel), the course arc, how to use Colab, and links to each chapter file (chapters/<slug>.html).
6. ${COURSE}/README.md: what the course is, how to open it (open index.html in a browser, or via a GitHub HTML preview), how to run the notebooks on Colab, versions pinned.
Open your template and index in headless Chromium with Playwright (require('playwright') works; chromium.launch()) at phone (390px) and desktop widths, light and dark, screenshot them to ${S}/shots/ and look at the screenshots, and fix any layout problems. Return a short summary of the components available and their class names.`, { label: 'foundation', phase: 'Foundation' })

return { plan, foundation_summary: foundation }
