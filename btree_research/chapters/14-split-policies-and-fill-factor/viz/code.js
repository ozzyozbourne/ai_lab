/* Chapter 14: code panel snippets (condensed from zig/src/split.zig and rust/src/split.rs;
 * comments, the interval bookkeeping and most fields of the returned Choice are left out
 * so that both fit next to the figure; the panel title says "condensed"). Every name
 * that appears here exists in the sources.
 * Loaded with a classic script tag: no fetch under file://. */
window.CHAPTER_CODE = {
  chooseSplit: {
    zig: `
pub fn chooseSplit(scratch: Allocator, items: []const Cell, new_index: usize,
                   page: PageInfo, policy: Policy) !Choice {
    const cands = try candidates(scratch, items, page.capacity);
    const leftmost = cands[0];
    const rightmost = cands[cands.len - 1];

    const fill: ?u8 = switch (policy) {
        .half => null,
        .fill => |ff| ff,
        .rightmost, .adaptive => |ff| if (page.isRightmost()) ff else null,
    };
    deltaSort(cands, page.capacity, fill);

    var pick: usize = 0;
    var strategy: Strategy = .default;
    if (policy == .adaptive) {
        const old_bytes = leftmost.left_bytes + leftmost.right_bytes - items[new_index].size;
        const interval = defaultInterval(cands, old_bytes / 20);
        if (firstDistinct(items, cands[0..interval])) |i| {
            pick = i;
        } else if (items[leftmost.first_right - 1].key != items[rightmost.first_right].key) {
            strategy = .many_duplicates;
            pick = firstDistinct(items, cands).?;
        } else if (page.isRightmost() or page.upper_key.? != items[new_index].key) {
            strategy = .single_value;
            deltaSort(cands, page.capacity, single_value_fill);
        }
    }
    const c = cands[pick]; // the result also carries byte counts, penalty and interval
    return .{ .first_right = c.first_right, .strategy = strategy };
}`,
    rust: `
pub fn choose_split(cands: &mut Vec<Candidate>, items: &[Cell], new_index: usize,
                    page: PageInfo, policy: Policy) -> Choice {
    candidates(cands, items, page.capacity);
    let leftmost = cands[0];
    let rightmost = cands[cands.len() - 1];

    let fill = match policy {
        Policy::Half => None,
        Policy::Fill(ff) => Some(ff),
        Policy::Rightmost(ff) | Policy::Adaptive(ff) => page.is_rightmost().then_some(ff),
    };
    delta_sort(cands, page.capacity, fill);

    let mut pick = 0;
    let mut strategy = Strategy::Default;
    if matches!(policy, Policy::Adaptive(_)) {
        let old_bytes = leftmost.left_bytes + leftmost.right_bytes - u32::from(items[new_index].size);
        let interval = default_interval(cands, old_bytes / 20) as usize;
        if let Some(i) = first_distinct(items, &cands[..interval]) {
            pick = i;
        } else if items[leftmost.first_right as usize - 1].key != items[rightmost.first_right as usize].key {
            strategy = Strategy::ManyDuplicates;
            pick = first_distinct(items, cands).unwrap();
        } else if page.upper_key != Some(items[new_index].key) {
            strategy = Strategy::SingleValue;
            delta_sort(cands, page.capacity, Some(SINGLE_VALUE_FILL));
        }
    }
    let c = cands[pick]; // the result also carries byte counts, penalty and interval
    Choice { first_right: c.first_right, strategy }
}`
  }
};

/* Lines of the snippets above (identical numbering in both languages) for each
 * phase of the step-by-step figure. [a, b] is an inclusive range. */
window.CHAPTER_CODE_LINES = {
  start: [1, 2],
  candidates: 3,
  target: [[7, 12]],
  space: [14, 30],
  interval: [17, 18],
  'default-distinct': [19, 20],
  'many-duplicates': [[21, 23]],
  'single-value': [[24, 26]],
  'run-continues': [24, 27],
  result: [29, 30]
};

/* Copied from ../expected_output.txt (the output of `zig build run` and `cargo run`).
 * index.html compares the JavaScript model against these with BTViz.selfTest. */
window.CHAPTER_EXPECTED = {
  /* part 3: bytes used per page, 300 inserts, seed 14 */
  scenario: `
workload ascending
  half          2036 2089 2068 2106 2048 2100 2067 2032 2084 2066 3331
  fill-90       3723 3688 3683 3651 3699 3656 1927
  rightmost-90  3723 3688 3683 3651 3699 3656 1927
  adaptive-90   3723 3688 3683 3651 3699 3656 1927
workload random
  half          2892 3176 2881 2786 3075 3113 2728 3034
  fill-90       3700 400 511 507 538 1038 661 1174 863 519 1328 1092 691 674 2985 1954 3199 1851
  rightmost-90  2892 3176 2881 2786 2439 2507 2354 2799 1851
  adaptive-90   2892 3176 2881 2786 2439 2507 2354 2799 1851
workload dup-groups
  half          2673 2257 2905 2990 3097 3567 3647 2939
  fill-90       4003 489 438 435 826 681 886 963 1415 896 1207 1048 2787 2717 2681 2603
  rightmost-90  2334 2429 2936 2996 2592 2787 2800 2598 2603
  adaptive-90   2210 2282 3127 3031 2493 2409 3239 2579 2705
workload dup-heavy
  half          2107 2035 2104 2092 2107 2661 2071 2018 2038 2071 2771
  fill-90       3712 3674 3711 1333 389 405 440 3646 3709 3056
  rightmost-90  2107 2035 2104 2011 2103 3304 3646 3709 3056
  adaptive-90   3974 3971 3960 459 3886 3975 3850
`,
  /* part 1: the choice lines, page not rightmost (upper bound 40), then rightmost */
  handInner: `
  half          s=3  left 46  right 60  separator 16 bytes  default
  fill-90       s=6  left 86  right 20  separator  8 bytes  default
  rightmost-90  s=3  left 46  right 60  separator 16 bytes  default
  adaptive-90   s=6  left 86  right 20  separator  8 bytes  many_duplicates
`,
  handRightmost: `
  half          s=3  left 46  right 60  separator 16 bytes  default
  fill-90       s=6  left 86  right 20  separator  8 bytes  default
  rightmost-90  s=6  left 86  right 20  separator  8 bytes  default
  adaptive-90   s=6  left 86  right 20  separator  8 bytes  default
`,
  /* part 2: [workload, policy, pages, avg fill %, separators with a tid, separator bytes], 20000 inserts */
  experiment: [
    ["ascending", "half", 774, "50.5", 0, 6184],
    ["ascending", "fill-90", 435, "89.9", 0, 3472],
    ["ascending", "rightmost-90", 435, "89.9", 0, 3472],
    ["ascending", "adaptive-90", 435, "89.9", 0, 3472],
    ["random", "half", 554, "70.3", 0, 4424],
    ["random", "fill-90", 1161, "33.5", 0, 9280],
    ["random", "rightmost-90", 565, "69.0", 0, 4512],
    ["random", "adaptive-90", 565, "69.0", 0, 4512],
    ["dup-groups", "half", 572, "68.2", 398, 7752],
    ["dup-groups", "fill-90", 1114, "35.0", 730, 14744],
    ["dup-groups", "rightmost-90", 570, "68.5", 378, 7576],
    ["dup-groups", "adaptive-90", 572, "68.2", 0, 4568],
    ["dup-heavy", "half", 761, "51.3", 759, 12152],
    ["dup-heavy", "fill-90", 459, "85.0", 453, 7288],
    ["dup-heavy", "rightmost-90", 748, "52.2", 747, 11952],
    ["dup-heavy", "adaptive-90", 417, "93.6", 395, 6488]
  ]
};
