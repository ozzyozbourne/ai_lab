# Research notes

Working notes from the seven research passes that ran, in parallel, before the chapters were written. They are published so readers can see where the book's claims came from. They are raw notes, not edited prose: some numbers in them were later re-measured or corrected in the chapters, and the chapters win where the two disagree. The book-level source list, with verification labels, is in [`../references.html`](../references.html).

Each file ends with a SOURCES section that says which pages were opened and read and which were only seen as search results. Code marked as verified in the notes was compiled and run with the toolchains listed in `references.html` (Rust 1.100.0, Zig 0.17.1, Odin dev-2026-11a). The only edits made for publication: absolute local paths were replaced with `~/langsrc/…` (the language source trees), `~/tools/…`, or repository-relative paths, and one pointer to a scratch prototype that is not shipped with the book was reworded. After review, the TigerBeetle issue #2469 summary in `06-case-studies.md` was corrected (marked in the file). Nothing secret was found in them.

| File | Pass | What it covers |
|---|---|---|
| [`01-foundations-hardware.md`](01-foundations-hardware.md) | Foundations and hardware | Llopis, Acton, Fabian, Kelley and Muratori on what DOD is; latency numbers, cache lines, prefetchers, TLBs, branch prediction, with sources marked (O) opened or (S) seen. |
| [`02-zig.md`](02-zig.md) | Zig | Zig 0.17.1 idioms compiled against the real toolchain: MultiArrayList, allocators, `std.Io`, the disabled loop vectorizer, and the Zig compiler's own token/AST/ZIR layout. |
| [`03-odin.md`](03-odin.md) | Odin | Odin dev-2026-11 idioms checked with `odin run` and `odin check -vet -strict-style`: `#soa`, the context and allocators, `bit_set`, `core:simd`, default target. |
| [`04-rust.md`](04-rust.md) | Rust | Rust 1.100 / edition 2024: `repr` and layout, generational arenas, SoA crates, autovectorization and asm probes, `std::simd` status, stability checked in the source tree. |
| [`05-techniques.md`](05-techniques.md) | Techniques catalogue | Language-neutral catalogue of DOD techniques. Each has the same template: what, why it works on the hardware, when not to use it, canonical example, visualisation idea, best sources ([S1]…). |
| [`06-case-studies.md`](06-case-studies.md) | Case studies | Real rewrites with measured results (Zig compiler, Carbon, TigerBeetle, Ghostty, Linux networking structs, ECS engines, columnar databases), each with its context and caveats. |
| [`07-visualization.md`](07-visualization.md) | Visualisation and front end | How the pages are built: Prism, Three.js and font versions, shared assets, component APIs, the visual style guide, and the offline checks. |
