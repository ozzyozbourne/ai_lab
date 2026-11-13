//! Storage 2: one table per component combination (archetype storage, minimal).
//! With three component types a combination is a 3-bit mask, so the "archetype graph edge"
//! for adding VEL is just `mask | VEL` and the tables live in an array indexed by mask.
//! A real ECS has open-ended component ids and needs a hash map plus cached edges for this.
use crate::entity::{Entities, Entity};
use crate::{Hp, Pos, Vel};

pub const POS: u8 = 1;
pub const VEL: u8 = 2;
pub const HP: u8 = 4;

/// One archetype: SoA columns with aligned rows. Columns for components outside `mask` stay empty.
#[derive(Default)]
pub struct Table {
    pub mask: u8,
    pub entities: Vec<Entity>,
    pub pos: Vec<Pos>,
    pub vel: Vec<Vel>,
    pub hp: Vec<Hp>,
}

/// Where an entity's row lives: the entity index (Mertens calls this the "record").
#[derive(Clone, Copy, Default)]
struct Location {
    table: u8,
    row: u32,
}

/// The components of one entity while it moves between tables.
#[derive(Clone, Copy)]
struct Row {
    pos: Option<Pos>,
    vel: Option<Vel>,
    hp: Option<Hp>,
}

pub struct ArchWorld {
    pub entities: Entities,
    loc: Vec<Location>, // indexed by entity index
    tables: [Table; 8], // indexed by component mask
}

impl Default for ArchWorld {
    fn default() -> Self {
        let tables = std::array::from_fn(|m| Table { mask: m as u8, ..Table::default() });
        Self { entities: Entities::default(), loc: Vec::new(), tables }
    }
}

impl ArchWorld {
    pub fn spawn(&mut self, pos: Pos, vel: Option<Vel>, hp: Option<Hp>) -> Entity {
        let e = self.entities.spawn();
        if e.index as usize >= self.loc.len() {
            self.loc.resize(e.index as usize + 1, Location::default());
        }
        self.put(e, Row { pos: Some(pos), vel, hp });
        e
    }

    pub fn despawn(&mut self, e: Entity) -> bool {
        if !self.entities.alive(e) {
            return false;
        }
        self.take(e);
        self.entities.despawn(e);
        true
    }

    /// Appends a row to the table that matches exactly the components present.
    fn put(&mut self, e: Entity, r: Row) {
        let mask = r.pos.map_or(0, |_| POS) | r.vel.map_or(0, |_| VEL) | r.hp.map_or(0, |_| HP);
        let t = &mut self.tables[mask as usize];
        self.loc[e.index as usize] = Location { table: mask, row: t.entities.len() as u32 };
        t.entities.push(e);
        t.pos.extend(r.pos);
        t.vel.extend(r.vel);
        t.hp.extend(r.hp);
    }

    /// Swap-and-pops the entity's row out of its table, column by column, and fixes the
    /// location of the entity that moved into the hole.
    fn take(&mut self, e: Entity) -> Row {
        let Location { table, row } = self.loc[e.index as usize];
        let (t, row) = (&mut self.tables[table as usize], row as usize);
        t.entities.swap_remove(row);
        if let Some(moved) = t.entities.get(row) {
            self.loc[moved.index as usize].row = row as u32;
        }
        Row {
            pos: (table & POS != 0).then(|| t.pos.swap_remove(row)),
            vel: (table & VEL != 0).then(|| t.vel.swap_remove(row)),
            hp: (table & HP != 0).then(|| t.hp.swap_remove(row)),
        }
    }

    /// Adding a component is a move: the whole row is copied to the table for `mask | VEL`.
    pub fn add_vel(&mut self, e: Entity, v: Vel) {
        let mut r = self.take(e);
        r.vel = Some(v);
        self.put(e, r);
    }

    pub fn remove_vel(&mut self, e: Entity) -> Option<Vel> {
        let mut r = self.take(e);
        let v = r.vel.take();
        self.put(e, r);
        v
    }

    pub fn has(&self, e: Entity, component: u8) -> bool {
        self.entities.alive(e) && self.loc[e.index as usize].table & component != 0
    }

    pub fn get(&self, e: Entity) -> (Option<&Pos>, Option<&Vel>, Option<&Hp>) {
        if !self.entities.alive(e) {
            return (None, None, None);
        }
        let Location { table, row } = self.loc[e.index as usize];
        let (t, row) = (&self.tables[table as usize], row as usize);
        (t.pos.get(row), t.vel.get(row), t.hp.get(row))
    }

    /// A query is a filter over tables: every table whose mask contains all of `with`.
    pub fn tables_with(&mut self, with: u8) -> impl Iterator<Item = &mut Table> {
        self.tables.iter_mut().filter(move |t| t.mask & with == with && !t.entities.is_empty())
    }

    pub fn count_with(&self, with: u8) -> usize {
        self.tables.iter().filter(|t| t.mask & with == with).map(|t| t.entities.len()).sum()
    }

    pub fn table_sizes(&self) -> [usize; 8] {
        std::array::from_fn(|m| self.tables[m].entities.len())
    }
}
