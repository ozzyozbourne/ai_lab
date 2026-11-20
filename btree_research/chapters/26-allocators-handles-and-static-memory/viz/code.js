/* Code snippets for the code panels (abridged from zig/src and rust/src; classic script). */
window.CHAPTER_CODE = {
  create: {
    zig: `
pub fn create(pool: *Pool) Allocator.Error!Handle {
    // Lowest slab that has a free slot (hint: nothing below it has room).
    var id = pool.hint;
    while (id < pool.slabs.items.len and !pool.hasSpace(id)) id += 1;
    if (id == pool.slabs.items.len) id = try pool.addSlab();

    const slab = pool.slabs.items[id].?;
    for (&slab.free, 0..) |*word, w| {
        if (word.* == 0) continue;           // no set bit: no free slot here
        const bit: u6 = @intCast(@ctz(word.*)); // lowest set bit = lowest free slot
        word.* &= ~(@as(u64, 1) << bit);     // clear it: the slot is used
        slab.used += 1;
        pool.live += 1;
        return .{ .slot = @intCast(w * 64 + bit), .slab = @intCast(id), .class = pool.options.class };
    }
    unreachable;
}`,
    rust: `
pub fn create(&mut self) -> Result<Handle, OutOfNodes> {
    // Lowest slab that has a free slot (hint: nothing below it has room).
    let mut id = self.hint;
    while id < self.slabs.len() && !self.has_space(id) {
        id += 1;
    }
    if id == self.slabs.len() {
        id = self.add_slab()?;               // fails when the budget is 0 (frozen)
    }
    let slab = self.slabs[id].as_mut().expect("has_space checked");
    let word = slab.free.iter().position(|&w| w != 0).expect("has_space checked");
    let bit = slab.free[word].trailing_zeros() as usize; // lowest free slot
    slab.free[word] &= !(1 << bit);          // clear it: the slot is used
    slab.used += 1;
    self.live += 1;
    Ok(Handle::new(self.class, id as u32, (word * 64 + bit) as u32))
}`
  },
  relocate: {
    zig: `
// Pool: move one item out of the victim slab. Cannot fail.
pub fn relocate(pool: *Pool, old: Handle) Handle {
    const new = pool.create() catch unreachable; // never from the victim
    pool.get(new).* = pool.get(old).*;           // copy the node
    pool.destroy(old);                           // last one out releases the slab
    return new;
}

// Tree: rewrite the ONE handle that names the node.
fn vacuumNode(tree: *Tree, h: Handle, moved: *u32) void {
    if (isLeaf(h)) return;
    for (0..tree.head(h).len + 1) |i| {
        const slot = &tree.kids(h)[i];
        slot.* = tree.moveIfVictim(slot.*, moved);
        tree.vacuumNode(slot.*, moved);
    }
}`,
    rust: `
// Pool: move one item out of the victim slab. Cannot fail.
pub fn relocate(&mut self, old: Handle) -> Handle {
    let value = *self.get(old);
    let new = self.create().expect("vacuum_begin guaranteed room");
    *self.get_mut(new) = value;                  // copy the node
    self.destroy(old);                           // last one out releases the slab
    new
}

// Tree: rewrite the ONE handle that names the node.
fn vacuum_node(&mut self, h: Handle, moved: &mut u32) {
    if is_leaf(h) {
        return;
    }
    for i in 0..=self.head(h).len() {
        let child = self.move_if_victim(self.kids(h)[i], moved);
        self.kids_mut(h)[i] = child;
        self.vacuum_node(child, moved);
    }
}`
  },
  buddy: {
    zig: `
pub fn freeBlock(b: *Buddy, start: u32) void {
    var block = start;
    var k = b.order[block];
    b.state[block] = .inside;
    while (k < max_order) : (k += 1) {
        // The buddy is the other half of the parent block: flip bit k.
        const buddy = block ^ (@as(u32, 1) << @intCast(k));
        // Merge only with a buddy that is free AND whole (same order).
        if (b.state[buddy] != .free or b.order[buddy] != k) break;
        b.unlinkFree(buddy);
        b.state[buddy] = .inside;
        block = @min(block, buddy);
    }
    b.pushFree(block, k);
}`,
    rust: `
pub fn free_block(&mut self, start: u32) {
    let mut block = start;
    let mut k = self.order[block as usize] as usize;
    self.state[block as usize] = State::Inside;
    while k < self.max_order {
        // The buddy is the other half of the parent block: flip bit k.
        let buddy = block ^ (1 << k);
        // Merge only with a buddy that is free AND whole (same order).
        if self.state[buddy as usize] != State::Free || self.order[buddy as usize] as usize != k {
            break;
        }
        self.unlink_free(buddy);
        self.state[buddy as usize] = State::Inside;
        block = block.min(buddy);
        k += 1;
    }
    self.push_free(block, k);
}`
  },
  freeze: {
    zig: `
// Start-up: take everything the tree will ever need, then freeze.
var static: StaticAllocator = .init(heap.allocator());
var fixed: btree.BTree(4, 32) = .init(static.allocator(), false);
try fixed.leaves.reserve(3);
try fixed.interiors.reserve(2);
static.freeze();                  // init -> static

// StaticAllocator: the policy in front of the parent's rawAlloc.
fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
    if (self.state != .init) {
        self.refused += 1;
        return null;              // the caller sees error.OutOfMemory
    }
    return self.parent.rawAlloc(len, alignment, ret_addr);
}

// SlabPool: the directory is sized once, because growing it would free the
// old one, and the first free ends the init phase.
pub fn reserve(pool: *Pool, count: u32) Allocator.Error!void {
    if (count > pool.slabs.capacity) try pool.slabs.ensureTotalCapacityPrecise(pool.backing, count);
    while (pool.slab_count < count) _ = try pool.addSlab();
}`,
    rust: `
// Start-up: take everything the tree will ever need, then freeze.
let mut fixed: BTree<4, 3, 32> = BTree::new(false);
fixed.leaves.reserve(3).expect("init may allocate");
fixed.interiors.reserve(2).expect("init may allocate");
fixed.leaves.freeze();
fixed.interiors.freeze();

// No allocator interface in stable Rust: the freeze is a property of the pool.
pub fn freeze(&mut self) {
    self.budget = 0;              // slabs that may still be created
}

fn add_slab(&mut self) -> Result<usize, OutOfNodes> {
    if self.budget == 0 {
        return Err(OutOfNodes);   // create() counts it in grow_failures
    }
    self.budget -= 1;
    // ... build the bitmap and the slots, store the slab in the directory
}

pub fn reserve(&mut self, count: u32) -> Result<(), OutOfNodes> {
    let wanted = count as usize;
    if wanted > self.slabs.capacity() {
        self.slabs.reserve_exact(wanted - self.slabs.len());
    }
    while self.slab_count < count {
        self.add_slab()?;
    }
    Ok(())
}`
  }
};
