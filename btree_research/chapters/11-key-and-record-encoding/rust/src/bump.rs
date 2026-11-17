//! The Rust counterparts of the two Zig allocators this chapter features.
//!
//! `Bump`      a fixed-capacity bump allocator over one `Vec<u8>`, handing out
//!             byte RANGES instead of pointers. It plays the role of Zig's
//!             `FixedBufferAllocator`: no per-key allocation, everything is
//!             freed at once, and when the space is used up `alloc` returns
//!             `Err(OutOfSpace)` (the mirror of `error.OutOfMemory`).
//! `SmallBuf`  inline array first, heap `Vec` on overflow: what Zig's
//!             `BufferFirstAllocator` gives any allocation, written by hand
//!             for one buffer.
//!
//! Why ranges and not `&mut [u8]`: a slice borrowed from the Vec would keep
//! the whole `Bump` mutably borrowed, so a second `alloc` could not happen
//! while the first key is still in use. An index range borrows nothing.
use std::ops::Range;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfSpace;

#[derive(Debug)]
pub struct Bump {
    bytes: Vec<u8>,
    limit: usize,
}

impl Bump {
    /// All memory is reserved here; `alloc` never reallocates.
    pub fn with_limit(limit: usize) -> Self {
        Self {
            bytes: Vec::with_capacity(limit),
            limit,
        }
    }

    /// Claims `len` zeroed bytes at the end, or fails without changing anything.
    pub fn alloc(&mut self, len: usize) -> Result<Range<usize>, OutOfSpace> {
        let start = self.bytes.len();
        if self.limit - start < len {
            return Err(OutOfSpace);
        }
        self.bytes.resize(start + len, 0);
        Ok(start..start + len)
    }

    pub fn get(&self, range: Range<usize>) -> &[u8] {
        &self.bytes[range]
    }

    pub fn get_mut(&mut self, range: Range<usize>) -> &mut [u8] {
        &mut self.bytes[range]
    }

    /// Bytes handed out so far (Zig: `fba.end_index`).
    pub fn used(&self) -> usize {
        self.bytes.len()
    }

    pub fn limit(&self) -> usize {
        self.limit
    }

    /// Frees everything at once and keeps the memory (Zig: `fba.reset()`).
    pub fn reset(&mut self) {
        self.bytes.clear();
    }
}

/// `len` bytes that live inline (on the stack, inside this value) when
/// `len <= N` and in a heap `Vec` otherwise.
#[derive(Debug)]
pub enum SmallBuf<const N: usize> {
    Inline { bytes: [u8; N], len: usize },
    Heap(Vec<u8>),
}

impl<const N: usize> SmallBuf<N> {
    pub fn with_len(len: usize) -> Self {
        if len <= N {
            SmallBuf::Inline { bytes: [0; N], len }
        } else {
            SmallBuf::Heap(vec![0; len])
        }
    }

    pub fn is_inline(&self) -> bool {
        matches!(self, SmallBuf::Inline { .. })
    }

    pub fn as_slice(&self) -> &[u8] {
        match self {
            SmallBuf::Inline { bytes, len } => &bytes[..*len],
            SmallBuf::Heap(v) => v,
        }
    }

    pub fn as_mut_slice(&mut self) -> &mut [u8] {
        match self {
            SmallBuf::Inline { bytes, len } => &mut bytes[..*len],
            SmallBuf::Heap(v) => v,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bump_hands_out_consecutive_ranges_and_fails_cleanly_when_full() {
        let mut bump = Bump::with_limit(10);
        let a = bump.alloc(4).unwrap();
        let b = bump.alloc(6).unwrap();
        assert_eq!((a.clone(), b.clone()), (0..4, 4..10));
        bump.get_mut(a.clone()).copy_from_slice(b"key1");
        assert_eq!(bump.get(a), b"key1");
        // Full: the failed call changes nothing (the allocation-failure path).
        assert_eq!(bump.alloc(1), Err(OutOfSpace));
        assert_eq!(bump.used(), 10);
        assert_eq!(bump.alloc(0), Ok(10..10));
        bump.reset();
        assert_eq!(bump.used(), 0);
        assert_eq!(bump.limit(), 10);
        assert_eq!(bump.alloc(10), Ok(0..10));
    }

    #[test]
    fn small_buf_is_inline_up_to_n_bytes() {
        let mut small = SmallBuf::<32>::with_len(32);
        assert!(small.is_inline());
        small.as_mut_slice()[31] = 7;
        assert_eq!(small.as_slice().len(), 32);
        assert_eq!(small.as_slice()[31], 7);

        let mut big = SmallBuf::<32>::with_len(33);
        assert!(!big.is_inline());
        big.as_mut_slice()[32] = 9;
        assert_eq!(big.as_slice()[32], 9);
    }
}
