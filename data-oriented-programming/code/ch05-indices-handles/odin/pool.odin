package main

// A generational pool (a "slot map"): values live in one dynamic array of slots, callers hold
// 8-byte handles (index + generation), and a free list is threaded through the free slots.
// Tests: `odin test odin -vet -strict-style` (from code/ch05-indices-handles)

import "core:testing"

// The type parameter is used only for typing: Handle(Monster) and Handle(Item) are different types.
Handle :: struct($T: typeid) {
	index: u32,
	gen:   u32, // starts at 1, so the zero value Handle{} is never valid
}

FREE_END :: max(u32) // end of the free list

Slot :: struct($T: typeid) {
	item:      T,
	gen:       u32, // survives the slot being freed and reused
	next_free: u32, // link in the free list while the slot is free
	live:      bool,
}

Pool :: struct($T: typeid) {
	slots:     [dynamic]Slot(T),
	free_head: u32, // the free list lives *inside* `slots`
	len:       int,
}

pool_make :: proc($T: typeid, allocator := context.allocator) -> Pool(T) {
	return {slots = make([dynamic]Slot(T), allocator), free_head = FREE_END}
}

pool_destroy :: proc(p: ^Pool($T)) {
	delete(p.slots)
}

pool_insert :: proc(p: ^Pool($T), item: T) -> Handle(T) {
	p.len += 1
	if p.free_head != FREE_END {
		index := p.free_head
		s := &p.slots[index]
		p.free_head = s.next_free // pop the free list
		s.item, s.live = item, true
		return {index, s.gen}
	}
	append(&p.slots, Slot(T){item = item, gen = 1, next_free = FREE_END, live = true})
	return {u32(len(p.slots) - 1), 1}
}

// The pointer is valid only until the next insert: `slots` may reallocate. Keep the handle.
pool_get :: proc(p: ^Pool($T), h: Handle(T)) -> (^T, bool) #optional_ok {
	if int(h.index) >= len(p.slots) {
		return nil, false
	}
	s := &p.slots[h.index]
	if !s.live || s.gen != h.gen {
		return nil, false // stale handle, or never issued
	}
	return &s.item, true
}

pool_remove :: proc(p: ^Pool($T), h: Handle(T)) -> (item: T, ok: bool) {
	if _, live := pool_get(p, h); !live {
		return // stale or double remove
	}
	s := &p.slots[h.index]
	item, ok = s.item, true
	s.live = false
	s.item = {}
	p.len -= 1
	if s.gen == max(u32) {
		return // retired: wrapping to 0 would make old handles valid again
	}
	s.gen += 1 // every outstanding copy of `h` stops matching
	s.next_free = p.free_head
	p.free_head = h.index // push onto the free list
	return
}

@(test)
test_stale_handle :: proc(t: ^testing.T) {
	p := pool_make(string)
	defer pool_destroy(&p)
	a := pool_insert(&p, "orc")
	b := pool_insert(&p, "elf")
	orc, removed := pool_remove(&p, a)
	testing.expect(t, removed && orc == "orc")
	_, ok := pool_get(&p, a)
	testing.expect(t, !ok, "removed handle must not resolve")
	_, again := pool_remove(&p, a)
	testing.expect(t, !again, "double remove must be rejected")
	c := pool_insert(&p, "goblin") // reuses a's slot
	testing.expect_value(t, c.index, a.index)
	testing.expect_value(t, c.gen, a.gen + 1)
	_, ok = pool_get(&p, a)
	testing.expect(t, !ok, "stale handle must not see the new occupant")
	testing.expect_value(t, pool_get(&p, c)^, "goblin")
	testing.expect_value(t, pool_get(&p, b)^, "elf")
	_, ok = pool_get(&p, Handle(string){})
	testing.expect(t, !ok, "the zero handle is never valid")
	testing.expect_value(t, p.len, 2)
}

@(test)
test_free_list_lifo :: proc(t: ^testing.T) {
	p := pool_make(int)
	defer pool_destroy(&p)
	hs: [5]Handle(int)
	for &h, i in hs {
		h = pool_insert(&p, i)
	}
	pool_remove(&p, hs[1])
	pool_remove(&p, hs[3])
	testing.expect_value(t, pool_insert(&p, 30).index, 3) // last freed slot first
	testing.expect_value(t, pool_insert(&p, 10).index, 1)
	testing.expect_value(t, pool_insert(&p, 5).index, 5) // empty free list: append
	testing.expect_value(t, len(p.slots), 6)
}

@(test)
test_handles_survive_growth :: proc(t: ^testing.T) {
	p := pool_make(u64)
	defer pool_destroy(&p)
	first := pool_insert(&p, 7)
	for i in 0 ..< 10_000 {
		pool_insert(&p, u64(i)) // reallocates: a ^u64 from before would dangle
	}
	testing.expect_value(t, pool_get(&p, first)^, 7)
}
