package main

// Part (a): sizes, alignments and offsets of the chapter's structs, as Odin dev-2026-11 lays them out on x86-64.

import "core:fmt"
import "core:math"

// ---- Kelley's alignment quiz ----
U32_Bool :: struct {
	a: u32,
	b: bool,
}
Quiz :: struct {
	a: u32,
	b: u64,
	c: u32,
}
Quiz_Sorted :: struct {
	a: u32,
	c: u32,
	b: u64,
}
Quiz_Sorted_Bool :: struct {
	a: u32,
	c: u32,
	b: u64,
	d: bool,
}

// default-layout
// Odin keeps declaration order (C layout). #packed drops all padding; #align(N) raises the struct's alignment.
Mixed :: struct {
	a: u8,
	b: u64,
	c: u8,
	d: u32,
}
Mixed_Packed :: struct #packed {
	a: u8,
	b: u64,
	c: u8,
	d: u32,
}
Mixed_Sorted :: struct {
	b: u64,
	d: u32,
	a: u8,
	c: u8,
}
Cache_Line :: struct #align (64) {
	counter: u64,
}

#assert(size_of(Mixed) == 24 && offset_of(Mixed, b) == 8 && offset_of(Mixed, d) == 20)
#assert(size_of(Mixed_Packed) == 14 && align_of(Mixed_Packed) == 1)
#assert(size_of(Mixed_Sorted) == 16)
#assert(size_of(Cache_Line) == 64 && align_of(Cache_Line) == 64)
// default-layout

// monster
Animation :: struct {
	frames: []u32,
}

// A pointer, two u32s and a bool: 8 + 4 + 4 + 1 = 17 bytes of data, 24 bytes of struct.
Monster :: struct {
	anim:  ^Animation,
	hp:    u32,
	y:     u32,
	alive: bool,
}
// `alive` moved out of band (one array of live monsters, one of dead ones): 16 bytes.
Monster_Oob :: struct {
	anim: ^Animation,
	hp:   u32,
	y:    u32,
}
// The pointer replaced by a u32 index into an animation table: 12 bytes, alignment 4.
Monster_Idx :: struct {
	anim: u32,
	hp:   u32,
	y:    u32,
}

#assert(size_of(Monster) == 24)
#assert(size_of(Monster_Oob) == 16)
#assert(size_of(Monster_Idx) == 12)
// monster

// niche
Kind :: enum u8 {
	Bee,
	Human,
	Snake,
	Wolf,
	Ghost,
}
Kind_Default :: enum {
	Bee,
	Human,
} // backing type defaults to int: 8 bytes
// Odin has no NonZero types; a distinct integer with a reserved value is the usual typed index.
Anim_Id :: distinct u32
ANIM_NONE :: Anim_Id(max(u32))

#assert(size_of(Kind) == 1 && size_of(Kind_Default) == 8)
#assert(size_of(Maybe(Kind)) == 2) // a union tag byte; no niche from unused enum values
#assert(size_of(Maybe(u32)) == 8) // tag + padding
#assert(size_of(Maybe(Anim_Id)) == 8) // the reserved value is a convention, not a niche
#assert(size_of(Maybe(^u64)) == 8) // a single-pointer union uses nil: no tag
// niche

// quantize
Pos_F32 :: struct {
	x, y, z: f32,
} // 12 bytes
Pos_U16 :: struct {
	x, y, z: u16,
} // 6 bytes: 1 km cell / 65535 ≈ 1.5 cm steps
Pos_F16 :: struct {
	x, y, z: f16,
} // 6 bytes, but only ~3 significant digits

// Least-significant bit first: kind = bits 0..3, layer = 4..7, index = 8..31.
Packed_Ref :: bit_field u32 {
	kind:  u8  | 4,
	layer: u8  | 4,
	index: u32 | 24,
}

#assert(size_of(Packed_Ref) == 4)
// quantize

CELL_M :: f32(1000)

quantize :: proc(v: f32) -> u16 {
	return u16(math.round(clamp(v / CELL_M, 0, 1) * f32(max(u16))))
}

dequantize :: proc(q: u16) -> f32 {
	return f32(q) / f32(max(u16)) * CELL_M
}

row :: proc(name: string, size, align: int, extra := "") {
	fmt.printfln("%-28s size %3d  align %2d  %s", name, size, align, extra)
}

print_layout :: proc() {
	fmt.println("== layout (odin, x86-64) ==")
	row("U32_Bool", size_of(U32_Bool), align_of(U32_Bool))
	row("Quiz {u32,u64,u32}", size_of(Quiz), align_of(Quiz))
	row("Quiz_Sorted {u32,u32,u64}", size_of(Quiz_Sorted), align_of(Quiz_Sorted))
	row("Quiz_Sorted + bool", size_of(Quiz_Sorted_Bool), align_of(Quiz_Sorted_Bool))
	row(
		"Mixed (struct)",
		size_of(Mixed),
		align_of(Mixed),
		fmt.tprintf(
			"offsets a=%d b=%d c=%d d=%d",
			offset_of(Mixed, a),
			offset_of(Mixed, b),
			offset_of(Mixed, c),
			offset_of(Mixed, d),
		),
	)
	row(
		"Mixed struct #packed",
		size_of(Mixed_Packed),
		align_of(Mixed_Packed),
		fmt.tprintf(
			"offsets a=%d b=%d c=%d d=%d",
			offset_of(Mixed_Packed, a),
			offset_of(Mixed_Packed, b),
			offset_of(Mixed_Packed, c),
			offset_of(Mixed_Packed, d),
		),
	)
	row(
		"Mixed sorted by hand",
		size_of(Mixed_Sorted),
		align_of(Mixed_Sorted),
		fmt.tprintf(
			"offsets a=%d b=%d c=%d d=%d",
			offset_of(Mixed_Sorted, a),
			offset_of(Mixed_Sorted, b),
			offset_of(Mixed_Sorted, c),
			offset_of(Mixed_Sorted, d),
		),
	)
	row(
		"Monster {^Anim,u32,u32,bool}",
		size_of(Monster),
		align_of(Monster),
		fmt.tprintf(
			"offsets anim=%d hp=%d y=%d alive=%d",
			offset_of(Monster, anim),
			offset_of(Monster, hp),
			offset_of(Monster, y),
			offset_of(Monster, alive),
		),
	)
	row("Monster_Oob (bool out of band)", size_of(Monster_Oob), align_of(Monster_Oob))
	row("Monster_Idx (u32 index)", size_of(Monster_Idx), align_of(Monster_Idx))
	row("Kind enum u8", size_of(Kind), align_of(Kind))
	row("enum (default int)", size_of(Kind_Default), align_of(Kind_Default))
	row("Maybe(Kind)", size_of(Maybe(Kind)), align_of(Maybe(Kind)))
	row("Maybe(u32)", size_of(Maybe(u32)), align_of(Maybe(u32)))
	row("Maybe(Anim_Id)", size_of(Maybe(Anim_Id)), align_of(Maybe(Anim_Id)))
	row("Maybe(^u64)", size_of(Maybe(^u64)), align_of(Maybe(^u64)))
	row("Pos_F32", size_of(Pos_F32), align_of(Pos_F32))
	row("Pos_U16", size_of(Pos_U16), align_of(Pos_U16))
	row("Pos_F16", size_of(Pos_F16), align_of(Pos_F16))
	row("Packed_Ref bit_field u32", size_of(Packed_Ref), align_of(Packed_Ref))
	row("Cache_Line #align (64)", size_of(Cache_Line), align_of(Cache_Line))
	p := Packed_Ref {
		kind  = 3,
		layer = 7,
		index = 123456,
	}
	fmt.printfln(
		"Packed_Ref(3, 7, 123456) -> kind=%d layer=%d index=%d raw=0x%08x",
		p.kind,
		p.layer,
		p.index,
		transmute(u32)p,
	)
	q := quantize(123.456)
	fmt.printfln("quantize(123.456 m) = %d -> %.4f m (error %.4f m)", q, dequantize(q), abs(dequantize(q) - 123.456))
	h := f16(123.456)
	fmt.printfln("f16 123.456 -> %.4f (error %.4f)", f32(h), abs(f32(h) - 123.456))
	free_all(context.temp_allocator)
}
