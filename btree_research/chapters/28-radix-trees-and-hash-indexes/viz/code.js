/* Chapter 28 code snippets for the visualization's code panel (no fetch under file://).
 * Abridged from zig/src/art.zig and rust/src/art.rs: comments and error-path cleanup removed. */
window.CHAPTER_CODE = {
  insert: {
    zig: `
fn insertAt(self: *Art, ref: Ref, key: []const u8, depth: usize, value: u64, old: *?u64) PutError!Ref {
    switch (ref) {
        .none => return self.newChain(key[depth..], value),
        .leaf => |v| {
            if (depth != key.len) return error.PrefixKey;
            old.* = v;
            return .{ .leaf = value };
        },
        .prefix => |p| {
            for (p.slice(), 0..) |stored, i| {
                if (depth + i == key.len) return error.PrefixKey;
                if (stored != key[depth + i]) return self.splitPrefix(p, i, key, depth + i, value);
            }
            p.child = try self.insertAt(p.child, key, depth + p.len, value, old);
            return ref;
        },
        .n4, .n16, .n48, .n256 => {
            if (depth == key.len) return error.PrefixKey;
            const byte = key[depth];
            if (childOf(ref, byte)) |child| {
                setChild(ref, byte, try self.insertAt(child, key, depth + 1, value, old));
                return ref;
            }
            const chain = try self.newChain(key[depth + 1 ..], value);
            errdefer self.freeChain(chain);
            const node = if (isFull(ref)) try self.grow(ref) else ref;
            addChild(node, byte, chain);
            return node;
        },
    }
}`,
    rust: `
fn insert_at(&mut self, r: Ref, key: &[u8], depth: usize, value: u64, old: &mut Option<u64>) -> Result<Ref, ArtError> {
    match r {
        Ref::None => self.new_chain(&key[depth..], value),
        Ref::Leaf(v) => {
            if depth != key.len() { return Err(ArtError::PrefixKey); }
            *old = Some(v);
            Ok(Ref::Leaf(value))
        }
        Ref::Prefix(id) => {
            let p = self.pools.prefix.items[id as usize];
            for (i, &stored) in p.slice().iter().enumerate() {
                if depth + i == key.len() { return Err(ArtError::PrefixKey); }
                if stored != key[depth + i] { return self.split_prefix(id, i, key, depth + i, value); }
            }
            let child = self.insert_at(p.child, key, depth + p.len as usize, value, old)?;
            self.pools.prefix.items[id as usize].child = child;
            Ok(r)
        }
        _ => {
            if depth == key.len() { return Err(ArtError::PrefixKey); }
            let byte = key[depth];
            if let Some(child) = self.child_of(r, byte) {
                let new_child = self.insert_at(child, key, depth + 1, value, old)?;
                self.set_child(r, byte, new_child);
                return Ok(r);
            }
            let chain = self.new_chain(&key[depth + 1..], value)?;
            let node = if self.is_full(r) { self.grow(r)? } else { r };
            self.add_child(node, byte, chain);
            Ok(node)
        }
    }
}`
  },
  lookup: {
    zig: `
pub fn lookup(self: *const Art, key: []const u8) Lookup {
    var ref = self.root;
    var depth: usize = 0;
    var steps: u32 = 0;
    while (true) {
        switch (ref) {
            .none => return .{ .value = null, .steps = steps },
            .leaf => |v| return .{ .value = if (depth == key.len) v else null, .steps = steps },
            .prefix => |p| {
                steps += 1;
                if (!std.mem.startsWith(u8, key[depth..], p.slice())) return .{ .value = null, .steps = steps };
                depth += p.len;
                ref = p.child;
            },
            .n4, .n16, .n48, .n256 => {
                steps += 1;
                if (depth == key.len) return .{ .value = null, .steps = steps };
                ref = childOf(ref, key[depth]) orelse return .{ .value = null, .steps = steps };
                depth += 1;
            },
        }
    }
}`,
    rust: `
pub fn lookup(&self, key: &[u8]) -> Lookup {
    let mut r = self.root;
    let mut depth = 0;
    let mut steps = 0;
    loop {
        match r {
            Ref::None => return Lookup { value: None, steps },
            Ref::Leaf(v) => return Lookup { value: (depth == key.len()).then_some(v), steps },
            Ref::Prefix(id) => {
                steps += 1;
                let p = &self.pools.prefix.items[id as usize];
                if !key[depth..].starts_with(p.slice()) { return Lookup { value: None, steps }; }
                depth += p.len as usize;
                r = p.child;
            }
            _ => {
                steps += 1;
                if depth == key.len() { return Lookup { value: None, steps }; }
                match self.child_of(r, key[depth]) {
                    Some(child) => r = child,
                    None => return Lookup { value: None, steps },
                }
                depth += 1;
            }
        }
    }
}`
  },
  scan: {
    zig: `
pub fn next(self: *Iterator) Allocator.Error!?Entry {
    if (self.pending != .none) {
        const ref = self.pending;
        self.pending = .none;
        if (try self.descend(ref)) |e| return e;
    }
    while (self.stack.items.len > 0) {
        const top = &self.stack.items[self.stack.items.len - 1];
        self.key.shrinkRetainingCapacity(top.key_len);
        if (nextChild(top.node, top.next)) |bc| {
            top.next = @as(u16, bc.byte) + 1;
            try self.key.append(self.gpa, bc.byte);
            if (try self.descend(bc.child)) |e| return e;
        } else {
            _ = self.stack.pop();
        }
    }
    return null;
}`,
    rust: `
fn advance(&mut self) -> Option<u64> {
    if self.pending != Ref::None {
        let r = std::mem::replace(&mut self.pending, Ref::None);
        if let Some(v) = self.descend(r) { return Some(v); }
    }
    while let Some(top) = self.stack.last_mut() {
        self.key.truncate(top.key_len);
        if let Some((byte, child)) = self.tree.next_child(top.node, top.next) {
            top.next = u16::from(byte) + 1;
            self.key.push(byte);
            if let Some(v) = self.descend(child) { return Some(v); }
        } else {
            self.stack.pop();
        }
    }
    None
}`
  }
};
