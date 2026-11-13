//! Chapter 6: two custom allocators built on the `Allocator` trait (stable since Rust 1.100).
//!
//! * [`Bump`]: a bump (linear) arena over one heap buffer. Frees are no-ops; `reset` frees everything.
//! * [`Pool`]: equal-size chunks with a free list threaded through the free chunks.
//!
//! Both keep their bytes in a heap-allocated `Box<[Cell<u8>]>`. The `Cell` gives the interior
//! mutability needed to hand out writable memory through a shared reference. `Allocator` is
//! implemented only for `&Bump` and `&Pool`, never for the owning values: a `Vec<T, &Bump>` holds a
//! borrow, so the arena cannot be moved, reset or dropped while any block it handed out is alive.
//! The `unsafe` in this crate is the two `unsafe impl Allocator` blocks and the `unsafe fn
//! deallocate` signatures the trait requires; every method body is safe code.

use std::alloc::{AllocError, Allocator, Layout};
use std::cell::Cell;
use std::ptr::NonNull;

/// A bump (linear) arena over one heap buffer of fixed capacity.
///
/// Containers borrow it (`Vec<T, &Bump>`); using the arena by value is rejected:
///
/// ```compile_fail,E0277
/// use ch06_allocation_strategies::Bump;
/// let v: Vec<u8, Bump> = Vec::new_in(Bump::with_capacity(64));
/// ```
pub struct Bump {
    buf: Box<[Cell<u8>]>,
    used: Cell<usize>,
}

impl Bump {
    /// An arena that can hand out `bytes` bytes (minus alignment padding) between resets.
    pub fn with_capacity(bytes: usize) -> Self {
        Self { buf: vec![Cell::new(0); bytes].into_boxed_slice(), used: Cell::new(0) }
    }

    /// Bytes handed out since the last reset, including alignment padding.
    pub fn used(&self) -> usize {
        self.used.get()
    }

    pub fn capacity(&self) -> usize {
        self.buf.len()
    }

    /// Frees everything at once by moving the bump pointer back to the start.
    ///
    /// It takes `&mut self`, so it can only be called when no `&Bump` borrow is alive, which means
    /// no `Vec<_, &Bump>` or `Box<_, &Bump>` still points into the buffer:
    ///
    /// ```compile_fail,E0502
    /// use ch06_allocation_strategies::Bump;
    /// let mut frame = Bump::with_capacity(1024);
    /// let names: Vec<u8, &Bump> = Vec::with_capacity_in(16, &frame);
    /// frame.reset(); // error[E0502]: cannot borrow `frame` as mutable because it is also borrowed as immutable
    /// println!("{}", names.len());
    /// ```
    pub fn reset(&mut self) {
        *self.used.get_mut() = 0;
    }
}

// SAFETY:
// * The allocator is `&Bump`, not `Bump`. Every block lies inside `buf`, and a container holding a
//   `&Bump` keeps the arena borrowed, so the arena cannot be dropped, moved or `reset` (which takes
//   `&mut self`) while a block is alive. Copying or moving the `&Bump` itself never touches `buf`.
//   We deliberately give the owning `Bump` no `Allocator` impl: moving it by value would move the
//   `Box`, and under Stacked Borrows that move retags the `Box` and invalidates pointers into it.
// * Blocks never overlap: `used` only moves forward between resets, and each block starts at or
//   after the end of the previous one.
// * `base + capacity` cannot overflow the address space, because `buf` is a real allocation.
// * Nothing here can panic (all arithmetic is checked), so no method unwinds.
// * The arena never reads or writes the bytes it has handed out.
unsafe impl Allocator for &Bump {
    fn allocate(&self, layout: Layout) -> Result<NonNull<[u8]>, AllocError> {
        // `Cell<u8>` has the same layout as `u8`, and writing through a pointer derived from a
        // shared reference is allowed because the bytes are inside `UnsafeCell`s.
        let base = self.buf.as_ptr().cast_mut().cast::<u8>();
        let start = (base.addr() + self.used.get())
            .checked_next_multiple_of(layout.align())
            .ok_or(AllocError)?
            - base.addr();
        let end = start.checked_add(layout.size()).ok_or(AllocError)?;
        if end > self.buf.len() {
            return Err(AllocError);
        }
        self.used.set(end);
        let ptr = NonNull::new(base.wrapping_add(start)).ok_or(AllocError)?;
        Ok(NonNull::slice_from_raw_parts(ptr, layout.size()))
    }

    unsafe fn deallocate(&self, _ptr: NonNull<u8>, _layout: Layout) {
        // Individual frees do nothing. `reset` frees the whole frame at once.
    }
}

const NIL: u32 = u32::MAX;

/// A fixed-capacity pool of equal-size chunks. A free chunk stores the index of the next free
/// chunk in its first four bytes, so the free list costs no memory of its own.
pub struct Pool {
    buf: Box<[Cell<u8>]>,
    first: usize, // offset of chunk 0 in `buf` (aligned)
    chunk: usize, // bytes per chunk, a multiple of `align`
    align: usize,
    free_head: Cell<u32>,
}

impl Pool {
    /// A pool with room for `count` values of type `T`.
    pub fn for_type<T>(count: usize) -> Self {
        let layout = Layout::new::<T>();
        let align = layout.align().max(4);
        let chunk = layout.size().max(4).next_multiple_of(align);
        assert!(count < NIL as usize, "pool too large for u32 indices");
        let buf: Box<[Cell<u8>]> = vec![Cell::new(0); chunk * count + align].into_boxed_slice();
        let first = buf.as_ptr().addr().next_multiple_of(align) - buf.as_ptr().addr();
        let pool = Self { buf, first, chunk, align, free_head: Cell::new(NIL) };
        // Thread the free list through every chunk: 0 -> 1 -> ... -> count-1 -> NIL.
        for i in (0..count).rev() {
            pool.push_free(i as u32);
        }
        pool
    }

    /// The four header bytes of chunk `i`, or `None` if `i` is out of range.
    fn link(&self, i: u32) -> Option<&[Cell<u8>]> {
        // Checked: `i` may be NIL (u32::MAX), and `NIL * chunk` must not overflow and panic.
        let at = (i as usize).checked_mul(self.chunk)?.checked_add(self.first)?;
        self.buf.get(at..at.checked_add(4)?)
    }

    fn push_free(&self, i: u32) {
        if let Some(link) = self.link(i) {
            for (cell, byte) in link.iter().zip(self.free_head.get().to_le_bytes()) {
                cell.set(byte);
            }
            self.free_head.set(i);
        }
    }

    fn pop_free(&self) -> Option<u32> {
        let i = self.free_head.get();
        let link = self.link(i)?; // NIL is out of range, so an empty pool returns None here
        let next = u32::from_le_bytes([link[0].get(), link[1].get(), link[2].get(), link[3].get()]);
        self.free_head.set(next);
        Some(i)
    }
}

// SAFETY:
// * As for `Bump`, the allocator is `&Pool`: a live block keeps the pool borrowed, so `buf` (and the
//   `Box` that owns it) cannot be dropped or moved until every container using the pool is gone.
// * A chunk is handed out only while it is off the free list, so live blocks never overlap.
// * Each chunk starts at `first + i * chunk`, a multiple of `align`, and `allocate` rejects any
//   layout that is larger than a chunk or more strictly aligned.
// * The free-list link is written only into chunks that are free (never into a live block), and
//   nothing here can panic (chunk offsets use checked arithmetic), so no method unwinds.
unsafe impl Allocator for &Pool {
    fn allocate(&self, layout: Layout) -> Result<NonNull<[u8]>, AllocError> {
        if layout.size() > self.chunk || layout.align() > self.align {
            return Err(AllocError);
        }
        let i = self.pop_free().ok_or(AllocError)?;
        let base = self.buf.as_ptr().cast_mut().cast::<u8>();
        let ptr = NonNull::new(base.wrapping_add(self.first + i as usize * self.chunk)).ok_or(AllocError)?;
        Ok(NonNull::slice_from_raw_parts(ptr, layout.size()))
    }

    unsafe fn deallocate(&self, ptr: NonNull<u8>, _layout: Layout) {
        let offset = ptr.as_ptr().addr().wrapping_sub(self.buf.as_ptr().addr() + self.first);
        self.push_free((offset / self.chunk) as u32);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An empty pool of huge chunks: `NIL * chunk` overflows usize, and `allocate` must return
    /// `AllocError` instead of panicking (the `Allocator` trait forbids unwinding).
    #[test]
    fn empty_pool_of_huge_chunks_fails_without_panicking() {
        let pool = Pool::for_type::<[u8; 1 << 33]>(0);
        assert!((&pool).allocate(Layout::new::<[u8; 1 << 33]>()).is_err());
    }
}
