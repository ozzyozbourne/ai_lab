//! Storage 1: one sparse set per component type (the EnTT layout).
//! An entity is a generational id; each component lives in a packed `data` array whose order
//! is the set's own, and `sparse[entity.index]` says where (or NONE).

use crate::entity::{Entities, Entity};
use crate::{Hp, Pos, Vel};

const NONE: u32 = u32::MAX;

/// Sparse array indexed by entity index -> position in the packed arrays.
/// `dense[i]` is the entity whose component is `data[i]`.
pub struct SparseSet<T> {
    sparse: Vec<u32>,
    dense: Vec<Entity>,
    data: Vec<T>,
}

impl<T> Default for SparseSet<T> {
    fn default() -> Self {
        Self { sparse: Vec::new(), dense: Vec::new(), data: Vec::new() }
    }
}

impl<T> SparseSet<T> {
    pub fn len(&self) -> usize {
        self.dense.len()
    }

    /// Two dependent loads: sparse, then dense. Comparing the whole Entity (with its
    /// generation) means a stale id fails here even if its index was reused.
    fn position(&self, e: Entity) -> Option<usize> {
        let d = *self.sparse.get(e.index as usize)? as usize;
        (self.dense.get(d) == Some(&e)).then_some(d)
    }

    pub fn get(&self, e: Entity) -> Option<&T> {
        self.position(e).map(|d| &self.data[d])
    }

    pub fn get_mut(&mut self, e: Entity) -> Option<&mut T> {
        self.position(e).map(|d| &mut self.data[d])
    }

    /// O(1): append to the packed arrays and point the sparse slot at the new position.
    pub fn insert(&mut self, e: Entity, value: T) {
        if let Some(d) = self.position(e) {
            self.data[d] = value;
            return;
        }
        let i = e.index as usize;
        if i >= self.sparse.len() {
            self.sparse.resize(i + 1, NONE);
        }
        self.sparse[i] = self.dense.len() as u32;
        self.dense.push(e);
        self.data.push(value);
    }

    /// O(1) swap-and-pop: the last element moves into the hole and its sparse slot is fixed.
    pub fn remove(&mut self, e: Entity) -> Option<T> {
        let d = self.position(e)?;
        let last = *self.dense.last()?;
        self.sparse[last.index as usize] = d as u32;
        self.sparse[e.index as usize] = NONE;
        self.dense.swap_remove(d);
        Some(self.data.swap_remove(d))
    }

    /// Entities in packed order, alongside their components.
    pub fn iter(&self) -> impl Iterator<Item = (Entity, &T)> {
        self.dense.iter().copied().zip(&self.data)
    }

    pub fn iter_mut(&mut self) -> impl Iterator<Item = (Entity, &mut T)> {
        self.dense.iter().copied().zip(&mut self.data)
    }
}

/// Join of two sets: walk the smaller packed array, probe the other one by entity id.
pub fn query2<A, B>(a: &mut SparseSet<A>, b: &SparseSet<B>, mut f: impl FnMut(&mut A, &B)) {
    if a.len() <= b.len() {
        for (e, va) in a.iter_mut() {
            if let Some(vb) = b.get(e) {
                f(va, vb);
            }
        }
    } else {
        for (e, vb) in b.iter() {
            if let Some(va) = a.get_mut(e) {
                f(va, vb);
            }
        }
    }
}

/// Join of three sets, driven by the smallest; the other two are probed per entity.
pub fn query3<A, B, C>(
    a: &SparseSet<A>,
    b: &SparseSet<B>,
    c: &mut SparseSet<C>,
    mut f: impl FnMut(&A, &B, &mut C),
) {
    let smallest = a.len().min(b.len()).min(c.len());
    if c.len() == smallest {
        for (e, vc) in c.iter_mut() {
            if let (Some(va), Some(vb)) = (a.get(e), b.get(e)) {
                f(va, vb, vc);
            }
        }
    } else if a.len() == smallest {
        for (e, va) in a.iter() {
            if let Some(vb) = b.get(e)
                && let Some(vc) = c.get_mut(e)
            {
                f(va, vb, vc);
            }
        }
    } else {
        for (e, vb) in b.iter() {
            if let Some(va) = a.get(e)
                && let Some(vc) = c.get_mut(e)
            {
                f(va, vb, vc);
            }
        }
    }
}

/// The sparse-set world: an entity allocator plus one set per component type.
#[derive(Default)]
pub struct SparseWorld {
    pub entities: Entities,
    pub pos: SparseSet<Pos>,
    pub vel: SparseSet<Vel>,
    pub hp: SparseSet<Hp>,
}

impl SparseWorld {
    pub fn spawn(&mut self, pos: Pos, vel: Option<Vel>, hp: Option<Hp>) -> Entity {
        let e = self.entities.spawn();
        self.pos.insert(e, pos);
        if let Some(v) = vel {
            self.vel.insert(e, v);
        }
        if let Some(h) = hp {
            self.hp.insert(e, h);
        }
        e
    }

    pub fn despawn(&mut self, e: Entity) -> bool {
        if !self.entities.alive(e) {
            return false;
        }
        self.pos.remove(e);
        self.vel.remove(e);
        self.hp.remove(e);
        self.entities.despawn(e);
        true
    }
}
