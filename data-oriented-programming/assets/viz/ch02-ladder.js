/* ch02-ladder — feeds the shared latency-ladder figure with rows computed from this chapter's own measurements.
 * Usage: <div class="figure-body" data-viz="latency-ladder" data-ch02-ladder data-opts='{"set":"orb"}'></div>
 * Must load after assets/data/bench-ch02.js and BEFORE assets/viz/latency-ladder.js (all `defer`, so document
 * order is execution order). It replaces data-opts with {"rows": [...], "source": "..."} before the ladder mounts.
 * If ch02-sweep is missing, the element keeps its own data-opts (the foundation's "orb" preset).
 * Rows: the Rust ch02-sweep point nearest each target working set (ns per dependent load), the ch02-mlp
 * "8 chains" point (DRAM loads with 8 in flight, per load), and ch02-access "sequential" scaled to 1 MiB. */
(window.BookQ ||= []).push((B) => {
  const sweep = B.bench("ch02-sweep");
  if (!sweep) return;
  const lang = "rust";
  const pts = sweep.runs.filter((r) => String(r.lang).toLowerCase() === lang).map((r) => ({ bytes: r.n * 64, ns: r.ns / r.n }));
  if (pts.length < 4) return;
  const near = (bytes) => pts.reduce((a, p) => (Math.abs(Math.log(p.bytes / bytes)) < Math.abs(Math.log(a.bytes / bytes)) ? p : a));
  const used = new Set(), rows = [];
  const add = (label, bytes, note) => {
    const p = near(bytes);
    if (used.has(p.bytes)) return;
    used.add(p.bytes);
    rows.push({ label: `${label} (${B.fmtBytes(p.bytes)})`, ns: +p.ns.toPrecision(3), note });
  };
  add("L1 hit", 16 << 10);
  add("L2 hit", 128 << 10);
  add("L3 hit", 3 << 20);
  add("DRAM, dependent", 64 << 20, "+ TLB misses");
  add("DRAM, dependent", 512 << 20, "+ page-walk misses");
  const mlp = B.bench("ch02-mlp"), acc = B.bench("ch02-access");
  const pick = (rec, label) => rec && rec.runs.find((r) => r.label === label && String(r.lang).toLowerCase() === lang);
  const m8 = pick(mlp, "8 chains");
  if (m8) rows.push({ label: `DRAM, 8 loads in flight (${B.fmtBytes(m8.n * 64)})`, ns: +(m8.ns / m8.n).toPrecision(3), note: "per load" });
  const seq = pick(acc, "sequential");
  if (seq) rows.push({ label: "Read 1 MiB sequentially", ns: +((seq.ns / seq.n) * 262144).toPrecision(3), note: `${((4 * seq.n) / seq.ns).toFixed(1)} GB/s` });
  rows.sort((a, b) => a.ns - b.ns);
  const source = `Computed from this chapter's own runs (bench-ch02.js, ${sweep.source || "measured"}, ${sweep.date || ""}): ` +
    "Rust, taskset -c 2, ns per dependent load from the ch02-sweep chase; the 8-chain row from ch02-mlp; the 1 MiB row from ch02-access sequential.";
  document.querySelectorAll("[data-ch02-ladder]").forEach((el) => { el.dataset.opts = JSON.stringify({ rows, source }); });
});
