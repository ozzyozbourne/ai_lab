/* Chapter 06 visualization data. A classic script (no fetch under file://).
 *
 * CHAPTER_CODE: the heart of the fuzzer and of the minimiser, condensed from
 * zig/src/fuzz.zig, zig/src/minimize.zig and their Rust twins.
 *
 * CHAPTER_EXPECTED: parts 1, 3 and 4 of ../expected_output.txt, copied verbatim.
 * index.html recomputes them with the JavaScript port in local.js and
 * compares the text, so the picture cannot drift from the programs.
 */
window.CHAPTER_CODE = {
  replay: {
    zig: `
for (steps, 0..) |step, i| {
    // 1. the same operation goes to the tree and to the oracle
    const answer_ok = switch (step.op) {
        .put => |p| try tree.put(gpa, p.key, p.value) == try oracle.put(gpa, p.key, p.value),
        .delete => |d| tree.delete(gpa, d.key) == oracle.delete(d.key),
        .get => |g| tree.get(g.key) == oracle.get(g.key),
        .range => |r| sameEntries(&tree, oracle.range(r.lo, r.hi)),
    };
    if (!answer_ok) return fail(i, .wrong_result);
    // 2. every invariant, after every step
    tree.validate(&diag) catch |err| return fail(i, .{ .invariant = err });
    // 3. the full contents, every 16 steps and at the end
    if (tree.len != oracle.len()) return fail(i, .wrong_contents);
    if (sweep and !sameEntries(&tree, oracle.range(0, max))) return fail(i, .wrong_contents);
}
return null; // no difference found`,
    rust: `
for (i, &step) in steps.iter().enumerate() {
    // 1. the same operation goes to the tree and to the oracle
    let answer_ok = match step.op {
        Op::Put { key, value } => tree.put(key, value)? == oracle.put(key, value),
        Op::Delete { key } => tree.delete(key) == oracle.delete(key),
        Op::Get { key } => tree.get(key) == oracle.get(key),
        Op::Range { lo, hi } => same_entries(&tree, oracle.range(lo, hi)),
    };
    if !answer_ok { return fail(i, Kind::WrongResult); }
    // 2. every invariant, after every step
    if let Err(v) = tree.validate() { return fail(i, Kind::Invariant(v.error)); }
    // 3. the full contents, every 16 steps and at the end
    if tree.len != oracle.len() { return fail(i, Kind::WrongContents); }
    if sweep && !same_entries(&tree, oracle.range(0, MAX)) { return fail(i, Kind::WrongContents); }
}
None // no difference found`
  },
  minimize: {
    zig: `
// fast: aligned chunks of a half, a quarter, ... down to single steps
var chunk = @max(current.items.len / 2, 1);
while (true) : (chunk /= 2) {
    var i: usize = 0;
    while (i < current.items.len) {
        // tryWithout: replay current without steps [i, i + chunk) and keep
        // the shorter sequence if it still fails in the same way
        if (!try tryWithout(i, i + chunk)) i += chunk; // needed: move on
    }
    if (chunk == 1) break;
}
// exhaustive: every contiguous block, longest first; start over after a hit
restart: while (true) {
    const n = current.items.len;
    var len = n - 1;
    while (len >= 1) : (len -= 1) {
        for (0..n - len + 1) |start| {
            if (try tryWithout(start, start + len)) continue :restart;
        }
    }
    break; // no contiguous block can be removed
}`,
    rust: `
// fast: aligned chunks of a half, a quarter, ... down to single steps
let mut chunk = (current.len() / 2).max(1);
loop {
    let mut i = 0;
    while i < current.len() {
        // try_without: replay current without steps i..i + chunk and keep
        // the shorter sequence if it still fails in the same way
        if !try_without(i, i + chunk) { i += chunk; } // needed: move on
    }
    if chunk == 1 { break; }
    chunk /= 2;
}
// exhaustive: every contiguous block, longest first; start over after a hit
'restart: loop {
    let n = current.len();
    for len in (1..n).rev() {
        for start in 0..=n - len {
            if try_without(start, start + len) { continue 'restart; }
        }
    }
    break; // no contiguous block can be removed
}`
  }
};

window.CHAPTER_EXPECTED = {
  part1: `
== 1. One seed is one test case ==
seed 1: 256 ops on 64 keys spread over u64, put:delete:get:range = 8:4:4:1, faults in 1 of 2 puts, drain yes
  M=4: 294 steps replayed, 9 allocation failures injected, max height 4, max keys 42: ok
seed 2: 256 ops on 64 keys spread over u64, put:delete:get:range = 5:3:0:2, faults in every put, drain no
  M=4: 256 steps replayed, 28 allocation failures injected, max height 4, max keys 38: ok
seed 3: 256 ops on 4 keys spread over u64, put:delete:get:range = 5:0:0:1, faults in 1 of 2 puts, drain yes
  M=4: 260 steps replayed, 2 allocation failures injected, max height 2, max keys 4: ok`,
  part3: `
== 3. A fixed mix against the swarm (M = 4, seeds 1..150) ==
fixed mix: 38400 steps, max height 4, coverage 18/21, never reached: put_oom, put_oom_rollback, root_shrink
swarm    : 40965 steps, max height 5, coverage 21/21`,
  part4: `
== 4. Three broken trees (M = 4, swarm seeds 1..200) ==
bug split_wrong_value
  caught by 191 of 200 seeds; shortest failing run: seed 20, step 6 of 67
  wrong result (answer differs from the oracle)
  with validate alone: not caught
  minimised to 5 steps in 25 replays:
    put 2 = 1
    put 4 = 2
    put 3 = 3
    put 1 = 4
    delete 3
    -> wrong result (answer differs from the oracle)
bug merge_leaks_node
  caught by 154 of 200 seeds; shortest failing run: seed 68, step 9 of 512
  invariant NodeCountMismatch
  with the oracle comparison alone: not caught
  minimised to 6 steps in 38 replays:
    put 4 = 1
    put 2 = 2
    put 3 = 3
    put 1 = 4
    delete 2
    delete 4
    -> invariant NodeCountMismatch
bug borrow_forgets_child
  caught by 71 of 200 seeds; shortest failing run: seed 28, step 52 of 256
  invariant MissingChild at depth 1 (node starts with key 7782220156096217088)
  with the oracle comparison alone: not tried (the tree is malformed)
  minimised to 11 steps in 117 replays:
    put 10 = 1
    put 9 = 2
    put 3 = 3
    put 7 = 4
    put 8 = 5
    put 1 = 6
    put 6 = 7
    put 5 = 8
    put 4 = 9
    put 2 = 10
    delete 9
    -> invariant MissingChild at depth 1 (node starts with key 7)`
};
