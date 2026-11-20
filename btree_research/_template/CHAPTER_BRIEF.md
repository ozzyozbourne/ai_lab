# Brief for chapter implementers

You implement ONE chapter of the guide "Understanding B-trees, from simple to complex"
in `/home/user/ai_lab/btree_research/chapters/NN-slug/`. Other agents implement the other
chapters at the same time. Touch only your own chapter directory.

## Read first (in this order)

1. `../PLAN.md`: the Conventions section (binding) and your chapter's table row. Also
   skim the rows of the neighbouring chapters so you know what was taught before you and
   what is left for later; do not teach later chapters' material in depth.
2. `../ZIG_CHEATSHEET.md`: verified Zig 0.17.1 APIs. Your memory of Zig is out of date
   (I/O, containers, allocators, threads and reflection all changed). When unsure, read
   the std source in `/opt/zigdl/zig-x86_64-linux-0.17.1/lib/std`, never guess.
   `../_template/zig` and `../_template/rust` are compiling skeletons to copy.
3. `../common/README.md`: PRNG, op-stream generator, oracle, CRC32, hexdump. Copy the
   files you need into your `src/` (keep the "Copied from" header).
4. `../assets/README.md` (and `../assets/demo.html`): the visualization toolkit API.
5. `../research/*.md`: source notes with file:line references. Grep them for your
   topics; open the real source under `/home/user/ai_lab/db_study/<db>/` to confirm
   anything you quote. Cite as `db/path/file.c:123`.

## Deliverables

```
chapters/NN-slug/
  README.md             the chapter (see PLAN "Text" convention), 1500 to 3500 words
  solutions.md          worked solutions to the exercises
  expected_output.txt   exact stdout of both `run` programs
  zig/   build.zig, build.zig.zon (own name + fingerprint), src/main.zig, src/*.zig
  rust/  Cargo.toml (package chNN_slug, edition 2024, no dependencies), src/main.rs, src/*.rs
  viz/   index.html (+ extra pages if the plan asks), code.js
```

Write the Zig version first, then port to Rust so that structure, names, tests and
output match; then explain the differences in the README. Aim for 250 to 800 lines per
language; clear, heavily commented teaching code, not production code. Comments explain
why, and point at the invariant being maintained.

Zig requirements: allocators passed explicitly everywhere; the allocator(s) named in
your row are used where they are the natural choice and the README section "Allocator
notes" explains the choice, the lifetime, and what would go wrong with a different one;
tests use `std.testing.allocator` so leaks fail the test; allocation-failure paths are
tested where your structure allocates on insert.

## Definition of done (run all of these yourself, repeatedly)

```
cd zig  && zig build test --summary all && zig build run > /tmp/out_zig.txt
cd rust && cargo test && cargo clippy --all-targets -- -D warnings && cargo run > /tmp/out_rust.txt
diff out_zig.txt ../expected_output.txt && diff out_rust.txt ../expected_output.txt
```

(use your own scratch paths, not /tmp). Then verify the visualization with Playwright
(`require('playwright')` works from any directory, `chromium.launch()` needs no options;
install nothing): open every page via `file://`, fail on any console error or page
error, drive the controls (play, step forward and back, the interactive inputs, theme
toggle), check there is no horizontal page overflow at 390 px, take screenshots at
1280x800 and 390x844 in light and dark, and LOOK at them (Read the PNG): fix overlaps,
clipped labels, unreadable contrast, and animations that do not actually explain the
idea. Keep screenshots out of the repository.

Delete build output before finishing (`.zig-cache`, `zig-out`, `target` are gitignored,
but remove any other scratch files). Do not run git commands.

## Visualization rules

- Use only `../../../assets/viz.css` and `../../../assets/viz.js` (from `chapters/NN-slug/viz/`) via classic script/link tags
  with relative paths. Do NOT edit anything in `assets/`. If a component you need is
  missing or buggy, write a small chapter-local helper in `viz/local.js` and mention it
  in your final report.
- The page teaches the chapter's central idea to someone who has not read the code:
  every step has a caption saying what happens and why; colours follow the toolkit's
  semantic tokens; there is a legend; the reader can interact (type keys, pick
  parameters, replay). Prefer a real JS model that generates the steps.
- Embed the final state of your programs' fixed scenario and check the JS model against
  it with `BTViz.selfTest` where the toolkit provides it.
- Link back to the chapter README and to the previous / next chapter's visualization.

## Honesty rules

- Statements about a database must be backed by the research notes or the source you
  opened. Label textbook material as textbook. Do not invent numbers, benchmarks or
  quotes. Counts printed by your own programs are fine.
- If something in your plan row turns out to be wrong or infeasible, do the closest
  correct thing and say so in your final report.

## Final report (your reply)

At most 8 lines: what you built; the exact summary lines of `zig build test`,
`cargo test`, clippy; whether both outputs match `expected_output.txt`; what the
Playwright check covered; any deviation from the plan row; anything a later chapter
that copies your code must know.

## Notes learned from the first wave

- Scratch space is shared by many agents working at once. Use ONLY a private
  subdirectory `<scratchpad>/work/chNN/` for scripts, screenshots and scratch builds;
  never read, move or delete files outside it.
- Zig `build.zig.zon` package names are limited to 32 characters; shorten the name there
  if your slug is longer (keep the full name for the executable and the Rust crate).
- In Rust, structure the crate as `src/lib.rs` plus a thin `src/main.rs` so public API
  that the demo does not call is not flagged as dead code by clippy.
- From `chapters/NN-slug/viz/` the toolkit is at `../../../assets/`.
- Known toolkit quirks: give `BTViz.ArrayView` its final `capacity` from the first frame;
  keep `BTViz.selfTest` names short (they do not wrap on phones).
- Line counts above the 800-line aim are acceptable when most of the excess is tests.
- Recurring visualization defect found in review: interactive controls (insert, delete,
  fetch ...) acted on the hidden END state of a preloaded scripted trace instead of the
  state shown on screen, so the picture jumped. Controls must act on the state the reader
  is looking at; start interactive figures empty or from the displayed step.
- Validate typed input: reject or clearly report negative numbers, decimals, empty and
  out-of-range values instead of silently changing them; captions must stay true for
  edge-case inputs.
- Exercise solutions were a repeated source of false claims: every number, outcome or
  "this is atomic / this is better" statement in `solutions.md` must come from code you
  actually ran against the chapter's own tests; otherwise word it as an expectation and
  say it was not measured.
- Layout defect found in review: the drawing, its caption and the step controls must be
  visible together on one 1280x800 screen and adjacent on a phone. Do not put a tall
  side column or scoreboard between the picture and its controls. Measure it with
  Playwright (bounding boxes), do not eyeball it.
- Escape all user-typed text before it reaches captions, logs or quiz text (innerHTML).
