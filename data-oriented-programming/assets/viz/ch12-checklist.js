/* ch12-checklist — a decision flow for "should I restructure this data, and how?".
 * <div class="figure-body" data-viz="ch12-checklist" data-opts='{}'></div>
 * Options:
 *   path   optional list of "yes"/"no" answers to start from (e.g. ["yes","no","yes"]); default: the first question
 * Model: a fixed tree of seven yes/no questions and eight outcomes. Each answer moves to the next node; the
 * breadcrumb lists the answers so far (click one to go back to it). Counters show how many questions were
 * answered and how many of the eight outcomes are still reachable from the current node. Every outcome links to
 * the chapter that covers it. The tree is the book's own advice, not a measurement. */
(window.BookQ ||= []).push((B) => B.viz.register("ch12-checklist", (root, opts) => {
  const { h, viz } = B;
  for (const k of Object.keys(opts)) viz.check(k === "path", `ch12-checklist: unknown option "${k}" (known: path)`);
  const start = opts.path ?? [];
  viz.check(Array.isArray(start) && start.every((a) => a === "yes" || a === "no"), 'ch12-checklist: "path" must be a list of "yes"/"no"');

  const Q = {
    hot: { q: "Has a profile or a careful timing shown that this code matters?",
      hint: "On the critical path, a large share of the time, or a memory budget you are missing. A hunch is not a profile.", yes: "algo", no: "R_measure" },
    algo: { q: "Is there a better algorithm, or a way to do less work?",
      hint: "A different complexity class, a spatial index, caching a result, skipping work nobody needs.", yes: "R_algo", no: "many" },
    many: { q: "Are there many of the thing, processed together?",
      hint: "Thousands or more per frame or request, touched by the same loop. \u201cWhere there is one, there are many.\u201d", yes: "stable", no: "R_simple" },
    stable: { q: "Has the shape of this data settled?",
      hint: "Fields and access patterns are no longer changing weekly. Teodorescu: a data-oriented system is harder to change when the data changes.", yes: "mem", no: "R_wait" },
    mem: { q: "Is the loop waiting on memory?",
      hint: "Time per element jumps when the data outgrows L2, or the loop reads many more bytes than it uses.", yes: "fields", no: "R_compute" },
    fields: { q: "Does the hot loop read only a few fields of each record?",
      hint: "For example position and velocity out of a 200-byte entity.", yes: "R_split", no: "ptrs" },
    ptrs: { q: "Is the data reached through pointers, or allocated one object at a time?",
      hint: "Linked lists, trees of boxes, a new/malloc per entity.", yes: "R_indices", no: "R_shrink" },
  };
  const R = {
    R_measure: { title: "Stop. Measure first.", kind: "stop",
      text: "Knuth\u2019s 3% has to be found, not guessed. Profile the real workload, then time the candidate with the harness: warm-up, median, keep-alive, checksum.",
      links: [["Measuring without fooling yourself (Ch 2)", "02-the-machine.html#harness"], ["The tools (this chapter)", "#tools"]] },
    R_algo: { title: "Fix the algorithm first.", kind: "go",
      text: "Aras\u2019s path tracer: a BVH gave about 370\u00d7, SIMD on top another 1.28\u00d7. Layout multiplies whatever the algorithm leaves; do the big division first.",
      links: [["A spatial hash instead of O(n\u00b2) (Ch 10)", "10-boids-spatial-hash.html"]] },
    R_simple: { title: "Leave it simple.", kind: "stop",
      text: "A handful of objects fits in L1 whatever the layout. Gray\u2019s default applies: an array of plain structs, and SoA only where the speed is needed.",
      links: [["AoS is a fine default (Ch 4)", "04-aos-soa-hot-cold.html"]] },
    R_wait: { title: "Wait for the data to settle, but keep the door open.", kind: "stop",
      text: "Keep the simple layout behind a narrow interface: indices or handles instead of pointers, and loops that take slices. Then a later switch to SoA or tables stays a local change.",
      links: [["Indices and handles (Ch 5)", "05-indices-handles.html"], ["Thinking in tables (Ch 9)", "09-ecs-and-tables.html"]] },
    R_compute: { title: "Not memory: look at branches, batches and SIMD.", kind: "go",
      text: "If the data already fits in cache, layout will not move it much. Remove unpredictable branches, batch by kind, and vectorize the inner loop.",
      links: [["Branches, batches and existence (Ch 7)", "07-branches-batches-existence.html"], ["SIMD and parallelism (Ch 8)", "08-simd-and-parallelism.html"]] },
    R_split: { title: "Split hot from cold, or go SoA.", kind: "go",
      text: "Move the fields the loop reads into their own dense arrays so every fetched line is useful. Shrink the types while you are there.",
      links: [["AoS, SoA and hot/cold (Ch 4)", "04-aos-soa-hot-cold.html"], ["Size, alignment, padding (Ch 3)", "03-size-alignment-padding.html"]] },
    R_indices: { title: "Replace pointers with indices; allocate in bulk.", kind: "go",
      text: "32-bit indices into arrays halve the links and make the data relocatable; arenas and pools put related objects next to each other and free them in one step.",
      links: [["Indices, handles, generations (Ch 5)", "05-indices-handles.html"], ["Allocation strategies (Ch 6)", "06-allocation-strategies.html"], ["The flat AST (Ch 11)", "11-capstone-flat-ast-compiler.html"]] },
    R_shrink: { title: "Shrink the records and sort by access.", kind: "go",
      text: "The loop uses most of each record, so splitting will not help. Remove padding, narrow the types, and process records in the order they sit in memory.",
      links: [["Size, alignment, padding (Ch 3)", "03-size-alignment-padding.html"], ["Morton order and cell order (Ch 10)", "10-boids-spatial-hash.html"]] },
  };
  const reach = (id) => (R[id] ? new Set([id]) : new Set([...reach(Q[id].yes), ...reach(Q[id].no)]));

  let answers = []; // list of [questionId, "yes"|"no"]
  const nodeOf = () => { let id = "hot"; for (const [, a] of answers) id = Q[id][a]; return id; };
  for (const a of start) { const id = nodeOf(); viz.check(!!Q[id], 'ch12-checklist: "path" is longer than the tree'); answers.push([id, a]); }

  const cnt = B.counters([["n", "questions answered"], ["left", "outcomes still possible"]]);
  const crumbs = h("ol", { class: "ch12-crumbs", "aria-label": "Answers so far" });
  const card = h("div", { class: "ch12-card", "aria-live": "polite" });
  const back = h("button", { type: "button", onclick: () => { answers.pop(); draw(); } }, "Back");
  const restart = h("button", { type: "button", onclick: () => { answers = []; draw(); } }, "Start over");
  root.append(crumbs, card, cnt.el, h("div", { class: "controls" }, back, restart),
    h("p", { class: "viz-note" }, "Seven questions, eight outcomes. Every outcome ends the same way: change one thing, then measure again, A and B alternated."));

  function draw() {
    const id = nodeOf();
    crumbs.replaceChildren(...answers.map(([qid, a], i) => h("li", {},
      h("button", { type: "button", class: "ch12-crumb", title: "Go back to this question", onclick: () => { answers = answers.slice(0, i); draw(); } },
        h("span", {}, Q[qid].q), h("b", { class: a === "yes" ? "ch12-yes" : "ch12-no" }, a)))));
    if (Q[id]) {
      const n = Q[id];
      card.className = "ch12-card";
      card.replaceChildren(h("p", { class: "ch12-step" }, `Question ${answers.length + 1}`), h("p", { class: "ch12-q" }, n.q), h("p", { class: "ch12-hint" }, n.hint),
        h("div", { class: "ch12-answers" },
          h("button", { type: "button", class: "ch12-btn-yes", onclick: () => { answers.push([id, "yes"]); draw(); } }, "Yes"),
          h("button", { type: "button", class: "ch12-btn-no", onclick: () => { answers.push([id, "no"]); draw(); } }, "No")));
    } else {
      const r = R[id];
      card.className = "ch12-card ch12-" + r.kind;
      card.replaceChildren(h("p", { class: "ch12-step" }, r.kind === "stop" ? "Outcome: don\u2019t restructure (yet)" : "Outcome: restructure"),
        h("p", { class: "ch12-q" }, r.title), h("p", {}, r.text),
        h("ul", { class: "ch12-links" }, r.links.map(([t, href]) => h("li", {}, h("a", { href }, t)))),
        h("p", { class: "ch12-hint" }, "Then measure again with the same harness, A and B alternated, and keep the change only if the difference is larger than the noise."));
    }
    back.disabled = answers.length === 0; restart.disabled = answers.length === 0;
    cnt.set("n", answers.length); cnt.set("left", reach(id).size + " of 8");
  }
  draw();
}));
