// Part (a): sizes, alignments and offsets of the chapter's structs, as rustc 1.100 lays them out on x86-64.
// Every number the chapter quotes for Rust is printed (and most are asserted at compile time) here.
#![allow(dead_code)] // these types exist to be measured, not used

use std::mem::offset_of;
use std::num::NonZeroU32;

// ---- Kelley's alignment quiz ----
#[repr(C)]
struct U32Bool {
    a: u32,
    b: bool,
}

#[repr(C)]
struct Quiz {
    a: u32,
    b: u64,
    c: u32,
}

#[repr(C)]
struct QuizSorted {
    a: u32,
    c: u32,
    b: u64,
}

#[repr(C)]
struct QuizSortedBool {
    a: u32,
    c: u32,
    b: u64,
    d: bool,
}

// ---- the same fields, two layouts ----
// default-layout
struct Mixed {
    a: u8,
    b: u64,
    c: u8,
    d: u32,
}

#[repr(C)]
struct MixedC {
    a: u8,
    b: u64,
    c: u8,
    d: u32,
}

#[repr(C, packed)]
struct MixedPacked {
    a: u8,
    b: u64,
    c: u8,
    d: u32,
}
// default-layout

// ---- Kelley's monster: 24 -> 16 -> 12 bytes ----
// monster
struct Animation {
    frames: Vec<u32>,
}

/// A pointer, two u32s and a bool: 8 + 4 + 4 + 1 = 17 bytes of data, 24 bytes of struct.
struct Monster<'a> {
    anim: &'a Animation,
    hp: u32,
    y: u32,
    alive: bool,
}

/// `alive` moved out of band (one array of live monsters, one of dead ones): 16 bytes.
struct MonsterOob<'a> {
    anim: &'a Animation,
    hp: u32,
    y: u32,
}

/// The pointer replaced by a u32 index into an animation table: 12 bytes, alignment 4.
struct MonsterIdx {
    anim: u32,
    hp: u32,
    y: u32,
}

const _: () = assert!(size_of::<Monster>() == 24);
const _: () = assert!(size_of::<MonsterOob>() == 16);
const _: () = assert!(size_of::<MonsterIdx>() == 12);
// monster

// ---- enums and niches ----
// niche
#[derive(Clone, Copy)]
enum Kind {
    Bee,
    Human,
    Snake,
    Wolf,
    Ghost,
}

/// A typed index whose zero bit pattern is forbidden, so `Option<AnimId>` can use 0 for `None`.
#[derive(Clone, Copy)]
struct AnimId(NonZeroU32);

const _: () = assert!(size_of::<Kind>() == 1);
const _: () = assert!(size_of::<Option<Kind>>() == 1); // spare discriminant values
const _: () = assert!(size_of::<Option<u32>>() == 8); // no spare bit pattern: tag + padding
const _: () = assert!(size_of::<Option<AnimId>>() == 4); // 0 is the niche
const _: () = assert!(size_of::<Option<&u64>>() == 8); // null is the niche
// niche

// ---- smaller types and bit packing ----
// quantize
/// World position as three f32: 12 bytes.
struct PosF32 {
    x: f32,
    y: f32,
    z: f32,
}

/// The same position quantized to u16 steps inside a 1 km cell (1000 m / 65535 ≈ 1.5 cm): 6 bytes.
struct PosU16 {
    x: u16,
    y: u16,
    z: u16,
}

const CELL_M: f32 = 1000.0;

fn quantize(v: f32) -> u16 {
    ((v / CELL_M).clamp(0.0, 1.0) * u16::MAX as f32).round() as u16
}

fn dequantize(q: u16) -> f32 {
    q as f32 / u16::MAX as f32 * CELL_M
}

/// Rust has no bit-fields: pack kind (4 bits), layer (4 bits) and index (24 bits) into a u32 by hand.
#[derive(Clone, Copy)]
struct PackedRef(u32);

impl PackedRef {
    fn new(kind: u32, layer: u32, index: u32) -> Self {
        assert!(kind < 16 && layer < 16 && index < (1 << 24));
        PackedRef(kind | layer << 4 | index << 8)
    }
    fn kind(self) -> u32 {
        self.0 & 0xF
    }
    fn layer(self) -> u32 {
        (self.0 >> 4) & 0xF
    }
    fn index(self) -> u32 {
        self.0 >> 8
    }
}
// quantize

#[repr(C, align(64))]
struct CacheLine {
    counter: u64,
}

fn row(name: &str, size: usize, align: usize, offsets: &str) {
    println!("{name:<28} size {size:>3}  align {align:>2}  {offsets}");
}

pub fn print() {
    println!("== layout (rustc, x86-64) ==");
    row(
        "U32Bool repr(C)",
        size_of::<U32Bool>(),
        align_of::<U32Bool>(),
        "",
    );
    row(
        "Quiz {u32,u64,u32} repr(C)",
        size_of::<Quiz>(),
        align_of::<Quiz>(),
        "",
    );
    row(
        "QuizSorted {u32,u32,u64}",
        size_of::<QuizSorted>(),
        align_of::<QuizSorted>(),
        "",
    );
    row(
        "QuizSorted + bool",
        size_of::<QuizSortedBool>(),
        align_of::<QuizSortedBool>(),
        "",
    );
    // default-offsets
    let off = |a, b, c, d| format!("offsets a={a} b={b} c={c} d={d}");
    row(
        "Mixed (default repr)",
        size_of::<Mixed>(),
        align_of::<Mixed>(),
        &off(
            offset_of!(Mixed, a),
            offset_of!(Mixed, b),
            offset_of!(Mixed, c),
            offset_of!(Mixed, d),
        ),
    );
    row(
        "Mixed repr(C)",
        size_of::<MixedC>(),
        align_of::<MixedC>(),
        &off(
            offset_of!(MixedC, a),
            offset_of!(MixedC, b),
            offset_of!(MixedC, c),
            offset_of!(MixedC, d),
        ),
    );
    row(
        "Mixed repr(C, packed)",
        size_of::<MixedPacked>(),
        align_of::<MixedPacked>(),
        &off(
            offset_of!(MixedPacked, a),
            offset_of!(MixedPacked, b),
            offset_of!(MixedPacked, c),
            offset_of!(MixedPacked, d),
        ),
    );
    // default-offsets
    row(
        "Monster {&Anim,u32,u32,bool}",
        size_of::<Monster>(),
        align_of::<Monster>(),
        &format!(
            "offsets anim={} hp={} y={} alive={}",
            offset_of!(Monster, anim),
            offset_of!(Monster, hp),
            offset_of!(Monster, y),
            offset_of!(Monster, alive)
        ),
    );
    row(
        "MonsterOob (bool out of band)",
        size_of::<MonsterOob>(),
        align_of::<MonsterOob>(),
        "",
    );
    row(
        "MonsterIdx (u32 index)",
        size_of::<MonsterIdx>(),
        align_of::<MonsterIdx>(),
        "",
    );
    row(
        "Kind (5 variants)",
        size_of::<Kind>(),
        align_of::<Kind>(),
        "",
    );
    row(
        "Option<Kind>",
        size_of::<Option<Kind>>(),
        align_of::<Option<Kind>>(),
        "",
    );
    row(
        "Option<u32>",
        size_of::<Option<u32>>(),
        align_of::<Option<u32>>(),
        "",
    );
    row(
        "Option<NonZeroU32>",
        size_of::<Option<NonZeroU32>>(),
        align_of::<Option<NonZeroU32>>(),
        "",
    );
    row(
        "Option<AnimId>",
        size_of::<Option<AnimId>>(),
        align_of::<Option<AnimId>>(),
        "",
    );
    row(
        "Option<&u64>",
        size_of::<Option<&u64>>(),
        align_of::<Option<&u64>>(),
        "",
    );
    row(
        "Option<Box<u64>>",
        size_of::<Option<Box<u64>>>(),
        align_of::<Option<Box<u64>>>(),
        "",
    );
    row("PosF32", size_of::<PosF32>(), align_of::<PosF32>(), "");
    row("PosU16", size_of::<PosU16>(), align_of::<PosU16>(), "");
    row(
        "PackedRef (manual bits)",
        size_of::<PackedRef>(),
        align_of::<PackedRef>(),
        "",
    );
    row(
        "CacheLine repr(align(64))",
        size_of::<CacheLine>(),
        align_of::<CacheLine>(),
        "",
    );
    let p = PackedRef::new(3, 7, 123_456);
    println!(
        "PackedRef(3, 7, 123456) -> kind={} layer={} index={} raw={:#010x}",
        p.kind(),
        p.layer(),
        p.index(),
        p.0
    );
    let q = quantize(123.456);
    println!(
        "quantize(123.456 m) = {q} -> {:.4} m (error {:.4} m)",
        dequantize(q),
        (dequantize(q) - 123.456).abs()
    );
    println!("f16: unstable in Rust 1.100 (feature \"f16\"); store u16 bits or quantize instead");
}
