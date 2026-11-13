package main

// Generational entity ids, shared by both storages (the idea is Chapter 5's pool, minus the values).

// The index names a slot, the generation says which occupant of that slot this id means.
// A struct of two u32s compares with == field by field.
Entity :: struct {
	index:      u32,
	generation: u32,
}

// Hands out entity ids. Freed indices are reused LIFO, with their generation bumped,
// so an old id never matches the new occupant. A slot whose generation runs out is retired.
Entities :: struct {
	generations: [dynamic]u32, // current generation of every index ever used
	live:        [dynamic]bool,
	free:        [dynamic]u32,
}

entities_destroy :: proc(es: ^Entities) {
	delete(es.generations)
	delete(es.live)
	delete(es.free)
}

entities_spawn :: proc(es: ^Entities) -> Entity {
	if index, ok := pop_safe(&es.free); ok {
		es.live[index] = true
		return {index, es.generations[index]}
	}
	append(&es.generations, 1) // generations start at 1: a zeroed Entity is never alive
	append(&es.live, true)
	return {u32(len(es.generations) - 1), 1}
}

entities_alive :: proc(es: ^Entities, e: Entity) -> bool {
	i := int(e.index)
	return i < len(es.live) && es.live[i] && es.generations[i] == e.generation
}

// Caller checks entities_alive first. Bumps the generation: every copy of `e` goes stale.
entities_despawn :: proc(es: ^Entities, e: Entity) {
	g := &es.generations[e.index]
	es.live[e.index] = false
	// Out of generations: retire the slot, as Chapter 5's pool does (wrapping would revive old ids).
	if g^ == max(u32) {
		return
	}
	g^ += 1
	append(&es.free, e.index)
}

// The current id for slot `index` (alive or not: callers check).
entities_at :: proc(es: ^Entities, index: int) -> Entity {
	return {u32(index), es.generations[index]}
}
