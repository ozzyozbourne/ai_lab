package main

// Storage 2: one table per component combination (archetype storage, minimal).
// With three component types a combination is a bit_set, so the "archetype graph edge"
// for adding .Vel is just `mask + {.Vel}` and the tables live in an array indexed by mask.
// A real ECS has open-ended component ids and needs a hash map plus cached edges for this.

Component :: enum u8 {
	Pos,
	Vel,
	Hp,
}
Mask :: bit_set[Component;u8]

// One archetype: SoA columns with aligned rows. Columns for components outside `mask` stay empty.
Table :: struct {
	mask:     Mask,
	entities: [dynamic]Entity,
	pos:      [dynamic]Pos,
	vel:      [dynamic]Vel,
	hp:       [dynamic]Hp,
}

// Where an entity's row lives: the entity index (Mertens calls this the "record").
Location :: struct {
	table: u8,
	row:   u32,
}

// The components of one entity while it moves between tables.
Row :: struct {
	pos: Maybe(Pos),
	vel: Maybe(Vel),
	hp:  Maybe(Hp),
}

Arch_World :: struct {
	entities: Entities,
	loc:      [dynamic]Location, // indexed by entity index
	tables:   [8]Table, // indexed by transmute(u8)mask
}

arch_world_make :: proc() -> (w: Arch_World) {
	for &t, m in w.tables {
		t.mask = transmute(Mask)u8(m)
	}
	return
}

arch_world_destroy :: proc(w: ^Arch_World) {
	entities_destroy(&w.entities)
	delete(w.loc)
	for &t in w.tables {
		delete(t.entities)
		delete(t.pos)
		delete(t.vel)
		delete(t.hp)
	}
}

arch_spawn :: proc(w: ^Arch_World, pos: Pos, vel: Maybe(Vel), hp: Maybe(Hp)) -> Entity {
	e := entities_spawn(&w.entities)
	if int(e.index) >= len(w.loc) {
		resize(&w.loc, int(e.index) + 1)
	}
	arch_put(w, e, {pos, vel, hp})
	return e
}

arch_despawn :: proc(w: ^Arch_World, e: Entity) -> bool {
	if !entities_alive(&w.entities, e) {
		return false
	}
	arch_take(w, e)
	entities_despawn(&w.entities, e)
	return true
}

// Appends a row to the table that matches exactly the components present.
@(private = "file")
arch_put :: proc(w: ^Arch_World, e: Entity, r: Row) {
	mask: Mask
	if r.pos != nil {mask += {.Pos}}
	if r.vel != nil {mask += {.Vel}}
	if r.hp != nil {mask += {.Hp}}
	t := &w.tables[transmute(u8)mask]
	w.loc[e.index] = {transmute(u8)mask, u32(len(t.entities))}
	append(&t.entities, e)
	if p, ok := r.pos.?; ok {append(&t.pos, p)}
	if v, ok := r.vel.?; ok {append(&t.vel, v)}
	if h, ok := r.hp.?; ok {append(&t.hp, h)}
}

// Swap-and-pops the entity's row out of its table, column by column, and fixes the
// location of the entity that moved into the hole.
@(private = "file")
arch_take :: proc(w: ^Arch_World, e: Entity) -> (r: Row) {
	l := w.loc[e.index]
	t := &w.tables[l.table]
	row := int(l.row)
	unordered_remove(&t.entities, row)
	if row < len(t.entities) {
		w.loc[t.entities[row].index].row = l.row
	}
	if .Pos in t.mask {
		r.pos = t.pos[row]
		unordered_remove(&t.pos, row)
	}
	if .Vel in t.mask {
		r.vel = t.vel[row]
		unordered_remove(&t.vel, row)
	}
	if .Hp in t.mask {
		r.hp = t.hp[row]
		unordered_remove(&t.hp, row)
	}
	return
}

// Adding a component is a move: the whole row is copied to the table for `mask + {.Vel}`.
arch_add_vel :: proc(w: ^Arch_World, e: Entity, v: Vel) {
	r := arch_take(w, e)
	r.vel = v
	arch_put(w, e, r)
}

arch_remove_vel :: proc(w: ^Arch_World, e: Entity) -> Maybe(Vel) {
	r := arch_take(w, e)
	v := r.vel
	r.vel = nil
	arch_put(w, e, r)
	return v
}

arch_has :: proc(w: ^Arch_World, e: Entity, c: Component) -> bool {
	return entities_alive(&w.entities, e) && c in transmute(Mask)w.loc[e.index].table
}

arch_get :: proc(w: ^Arch_World, e: Entity) -> (r: Row) {
	if !entities_alive(&w.entities, e) {
		return
	}
	l := w.loc[e.index]
	t := &w.tables[l.table]
	if .Pos in t.mask {r.pos = t.pos[l.row]}
	if .Vel in t.mask {r.vel = t.vel[l.row]}
	if .Hp in t.mask {r.hp = t.hp[l.row]}
	return
}

// The number of entities in every table whose mask contains all of `with`.
arch_count_with :: proc(w: ^Arch_World, with: Mask) -> (n: int) {
	for &t in w.tables {
		if with <= t.mask {
			n += len(t.entities)
		}
	}
	return
}
