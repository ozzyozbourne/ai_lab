//! Generational entity ids, shared by both storages (the idea is Chapter 5's pool, minus the values).

/// A generational entity id, as in Chapter 5: the index names a slot, the generation says
/// which occupant of that slot this id means.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Entity {
    pub index: u32,
    pub generation: u32,
}

/// Hands out entity ids. Freed indices are reused LIFO, with their generation bumped,
/// so an old id never matches the new occupant. A slot whose generation runs out is retired.
#[derive(Default)]
pub struct Entities {
    generations: Vec<u32>, // current generation of every index ever used
    live: Vec<bool>,
    free: Vec<u32>,
}

impl Entities {
    pub fn spawn(&mut self) -> Entity {
        if let Some(index) = self.free.pop() {
            self.live[index as usize] = true;
            return Entity { index, generation: self.generations[index as usize] };
        }
        self.generations.push(1); // generations start at 1: a zeroed Entity is never alive
        self.live.push(true);
        Entity { index: self.generations.len() as u32 - 1, generation: 1 }
    }

    pub fn alive(&self, e: Entity) -> bool {
        let i = e.index as usize;
        i < self.live.len() && self.live[i] && self.generations[i] == e.generation
    }

    /// Caller checks `alive` first. Bumps the generation: every copy of `e` goes stale.
    pub fn despawn(&mut self, e: Entity) {
        let i = e.index as usize;
        self.live[i] = false;
        // Out of generations: retire the slot, as Chapter 5's pool does (wrapping would revive old ids).
        if let Some(g) = self.generations[i].checked_add(1) {
            self.generations[i] = g;
            self.free.push(e.index);
        }
    }

    /// Number of indices ever handed out (live, free or retired).
    pub fn capacity(&self) -> usize {
        self.generations.len()
    }

    /// The current id for slot `index` (alive or not: callers check).
    pub fn at(&self, index: usize) -> Entity {
        Entity { index: index as u32, generation: self.generations[index] }
    }
}
