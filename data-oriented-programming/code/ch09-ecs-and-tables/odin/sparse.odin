package main

// Storage 1: one sparse set per component type (the EnTT layout).
// Each component lives in a packed `data` array whose order is the set's own, and
// `sparse[entity.index]` says where (or NONE).

NONE :: max(u32)

// Sparse array indexed by entity index -> position in the packed arrays.
// `dense[i]` is the entity whose component is `data[i]`.
Sparse_Set :: struct($T: typeid) {
	sparse: [dynamic]u32,
	dense:  [dynamic]Entity,
	data:   [dynamic]T,
}

sparse_destroy :: proc(s: ^Sparse_Set($T)) {
	delete(s.sparse)
	delete(s.dense)
	delete(s.data)
}

// Two dependent loads: sparse, then dense. Comparing the whole Entity (with its
// generation) means a stale id fails here even if its index was reused.
sparse_position :: #force_inline proc(s: ^Sparse_Set($T), e: Entity) -> (int, bool) {
	if int(e.index) >= len(s.sparse) {
		return 0, false
	}
	d := int(s.sparse[e.index])
	if d >= len(s.dense) || s.dense[d] != e {
		return 0, false
	}
	return d, true
}

sparse_get :: #force_inline proc(s: ^Sparse_Set($T), e: Entity) -> ^T {
	d, ok := sparse_position(s, e)
	return &s.data[d] if ok else nil
}

// O(1): append to the packed arrays and point the sparse slot at the new position.
sparse_insert :: proc(s: ^Sparse_Set($T), e: Entity, value: T) {
	if d, ok := sparse_position(s, e); ok {
		s.data[d] = value
		return
	}
	if int(e.index) >= len(s.sparse) {
		old := len(s.sparse)
		resize(&s.sparse, int(e.index) + 1)
		for &x in s.sparse[old:] {
			x = NONE
		}
	}
	s.sparse[e.index] = u32(len(s.dense))
	append(&s.dense, e)
	append(&s.data, value)
}

// O(1) swap-and-pop: the last element moves into the hole and its sparse slot is fixed.
sparse_remove :: proc(s: ^Sparse_Set($T), e: Entity) -> (value: T, ok: bool) {
	d := sparse_position(s, e) or_return
	last := s.dense[len(s.dense) - 1]
	s.sparse[last.index] = u32(d)
	s.sparse[e.index] = NONE
	value = s.data[d]
	unordered_remove(&s.dense, d)
	unordered_remove(&s.data, d)
	return value, true
}

// Join of two sets: walk the smaller packed array, probe the other one by entity id.
// `$f` is a compile-time parameter, so every system gets its own specialised loop.
query2 :: proc(a: ^Sparse_Set($A), b: ^Sparse_Set($B), ctx: $C, $f: proc(ctx: C, a: ^A, b: ^B)) {
	// Hoist the slices into locals: reading them through `a`/`b` in the loop forces reloads.
	if len(a.dense) <= len(b.dense) {
		dense, data := a.dense[:], a.data[:]
		for e, i in dense {
			if vb := sparse_get(b, e); vb != nil {
				f(ctx, &data[i], vb)
			}
		}
	} else {
		dense, data := b.dense[:], b.data[:]
		for e, i in dense {
			if va := sparse_get(a, e); va != nil {
				f(ctx, va, &data[i])
			}
		}
	}
}

// Join of three sets, driven by the smallest; the other two are probed per entity.
query3 :: proc(
	a: ^Sparse_Set($A),
	b: ^Sparse_Set($B),
	c: ^Sparse_Set($K),
	ctx: $C,
	$f: proc(ctx: C, a: ^A, b: ^B, c: ^K),
) {
	smallest := min(len(a.dense), len(b.dense), len(c.dense))
	switch smallest {
	case len(c.dense):
		dense, data := c.dense[:], c.data[:]
		for e, i in dense {
			va, vb := sparse_get(a, e), sparse_get(b, e)
			if va != nil && vb != nil {
				f(ctx, va, vb, &data[i])
			}
		}
	case len(a.dense):
		dense, data := a.dense[:], a.data[:]
		for e, i in dense {
			vb, vc := sparse_get(b, e), sparse_get(c, e)
			if vb != nil && vc != nil {
				f(ctx, &data[i], vb, vc)
			}
		}
	case:
		dense, data := b.dense[:], b.data[:]
		for e, i in dense {
			va, vc := sparse_get(a, e), sparse_get(c, e)
			if va != nil && vc != nil {
				f(ctx, va, &data[i], vc)
			}
		}
	}
}

// The sparse-set world: an entity allocator plus one set per component type.
Sparse_World :: struct {
	entities: Entities,
	pos:      Sparse_Set(Pos),
	vel:      Sparse_Set(Vel),
	hp:       Sparse_Set(Hp),
}

sparse_world_destroy :: proc(w: ^Sparse_World) {
	entities_destroy(&w.entities)
	sparse_destroy(&w.pos)
	sparse_destroy(&w.vel)
	sparse_destroy(&w.hp)
}

sparse_world_spawn :: proc(w: ^Sparse_World, pos: Pos, vel: Maybe(Vel), hp: Maybe(Hp)) -> Entity {
	e := entities_spawn(&w.entities)
	sparse_insert(&w.pos, e, pos)
	if v, ok := vel.?; ok {
		sparse_insert(&w.vel, e, v)
	}
	if h, ok := hp.?; ok {
		sparse_insert(&w.hp, e, h)
	}
	return e
}

sparse_world_despawn :: proc(w: ^Sparse_World, e: Entity) -> bool {
	if !entities_alive(&w.entities, e) {
		return false
	}
	sparse_remove(&w.pos, e)
	sparse_remove(&w.vel, e)
	sparse_remove(&w.hp, e)
	entities_despawn(&w.entities, e)
	return true
}
