//! Regenerates the text of common/golden.txt from the four modules and checks
//! it byte for byte. common/zig/golden_test.zig does the same, so if both
//! pass, Zig and Rust agree. Chapters do NOT copy this file.
use crate::crc32::crc32;
use crate::hexdump::hexdump;
use crate::ops::{Config, Op, OpStream, Weights};
use crate::prng::SplitMix64;
use std::fmt::Write; // gives `write!` / `writeln!` on String

const GOLDEN: &str = include_str!("../golden.txt");

/// "1 2 3" from a list of numbers.
fn joined(numbers: impl Iterator<Item = u64>) -> String {
    numbers.map(|n| n.to_string()).collect::<Vec<_>>().join(" ")
}

// Writing to a String cannot fail, so the `unwrap()`s below never panic.
fn render() -> String {
    let mut out = String::new();
    out.push_str(
        "# Golden vectors for common/. Reproduced exactly by the tests in\n\
         # common/zig/golden_test.zig and common/rust/golden_test.rs. Do not edit by hand.\n",
    );

    for seed in [0, 1, 42] {
        writeln!(out, "\n[splitmix64 seed={seed} first=16]").unwrap();
        let mut rng = SplitMix64::new(seed);
        for _ in 0..16 {
            writeln!(out, "0x{:016x}", rng.next_u64()).unwrap();
        }
    }

    let mut rng = SplitMix64::new(42);
    let line = joined((0..16).map(|_| rng.below(10)));
    writeln!(out, "\n[below seed=42 n=10 first=16]\n{line}").unwrap();

    let mut rng = SplitMix64::new(42);
    let line = joined((0..16).map(|_| rng.range(100, 200)));
    writeln!(out, "\n[range seed=42 lo=100 hi=200 first=16]\n{line}").unwrap();

    let mut rng = SplitMix64::new(42);
    let line = joined((0..16).map(|_| u64::from(rng.chance(1, 3))));
    writeln!(
        out,
        "\n[chance seed=42 numerator=1 denominator=3 first=16]\n{line}"
    )
    .unwrap();

    let mut items: Vec<u64> = (0..16).collect();
    SplitMix64::new(7).shuffle(&mut items);
    writeln!(
        out,
        "\n[shuffle seed=7 input=0..16]\n{}",
        joined(items.into_iter())
    )
    .unwrap();

    out.push_str("\n[ops seed=42 count=20 key_space=100 weights=put:3,delete:2,get:2,range:2]\n");
    let weights = Weights {
        put: 3,
        delete: 2,
        get: 2,
        range: 2,
    };
    for op in OpStream::new(Config {
        seed: 42,
        count: 20,
        key_space: 100,
        weights,
    }) {
        match op {
            Op::Put { key, value } => writeln!(out, "put {key} {value}").unwrap(),
            Op::Delete { key } => writeln!(out, "delete {key}").unwrap(),
            Op::Get { key } => writeln!(out, "get {key}").unwrap(),
            Op::Range { lo, hi } => writeln!(out, "range {lo} {hi}").unwrap(),
        }
    }

    out.push_str("\n[crc32]\n");
    for text in [
        "",
        "a",
        "123456789",
        "The quick brown fox jumps over the lazy dog",
    ] {
        writeln!(out, "0x{:08x} \"{text}\"", crc32(text.as_bytes())).unwrap();
    }
    let mut page = [0u8; 4096];
    writeln!(out, "0x{:08x} 4096 zero bytes", crc32(&page)).unwrap();
    for (i, b) in page.iter_mut().enumerate() {
        *b = i as u8; // `as u8` keeps the low 8 bits: i mod 256
    }
    writeln!(
        out,
        "0x{:08x} 4096 bytes, byte[i] = i mod 256",
        crc32(&page)
    )
    .unwrap();

    out.push_str("\n[hexdump of \"B-tree page\" followed by bytes 0x00..0x1b]\n");
    let mut bytes = b"B-tree page".to_vec();
    bytes.extend(0u8..28);
    out.push_str(&hexdump(&bytes));

    out
}

#[test]
fn golden_txt_is_reproduced_exactly() {
    assert_eq!(render(), GOLDEN);
}

#[test]
fn the_private_generator_in_ops_rs_is_splitmix64() {
    // With only `put` enabled each op draws: kind, key, value. Mirror that.
    let weights = Weights {
        put: 1,
        delete: 0,
        get: 0,
        range: 0,
    };
    let mut rng = SplitMix64::new(5);
    for op in OpStream::new(Config {
        seed: 5,
        count: 50,
        key_space: 1000,
        weights,
    }) {
        rng.below(1);
        let key = rng.below(1000);
        let value = rng.next_u64();
        assert_eq!(op, Op::Put { key, value });
    }
}
