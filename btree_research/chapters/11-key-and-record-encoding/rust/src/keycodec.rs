//! Order-preserving ("byte-comparable", "memcmp-able") key encoding.
//!
//! STANDALONE: depends on `std` only. Chapter 12 may copy this file as
//! `base_keycodec.rs`. Nothing here allocates: the caller owns every buffer.
//! Twin of `zig/src/keycodec.zig`; the bytes produced are identical.
//!
//! THE property (tested at the bottom of this file against an oracle that
//! never looks at bytes: random schemas, every byte value, every truncation):
//! for two keys built with the same sequence of `put_*` calls and the same
//! `ColumnOpts` per column,
//!
//!     key_a.cmp(key_b) (slice comparison = memcmp) == logical order of the values
//!
//! so a B-tree that only knows how to compare byte strings sorts them right.
//!
//! Layout of one column inside a key:
//!
//!     tag (1 byte)   0x00 NULL when NULLS FIRST
//!                    0x01 a value follows
//!                    0x02 NULL when NULLS LAST (the default here, for ASC and
//!                         for DESC; Postgres defaults to NULLS LAST for ASC
//!                         but to NULLS FIRST for DESC, so a caller that
//!                         mirrors Postgres must set `nulls_first` on a
//!                         bare DESC column itself)
//!     payload        u64   8 bytes big-endian
//!                    i64   8 bytes big-endian with the sign bit flipped
//!                    f64   8 bytes, see `encode_f64`
//!                    bytes escaped and terminated, see `encode_bytes`
//!     DESC columns   every payload byte is inverted (b ^ 0xff); the tag is not,
//!                    so NULL placement is independent of ASC / DESC
//!
//! A composite key is the concatenation of its columns. Keys are NOT
//! self-describing: the reader must know the column types and options.
//!
//! API
//!   primitives     encode_u64/decode_u64, encode_i64/decode_i64, encode_f64/decode_f64
//!                  encoded_bytes_len, encode_bytes, decode_bytes, invert
//!   KeyWriter      new(buf), put_null, put_u64, put_i64, put_f64, put_bytes, written()
//!                  every put is all-or-nothing: on NoSpaceLeft nothing was written
//!   KeyReader      new(bytes), take_u64, take_i64, take_f64 (None = SQL NULL),
//!                  bytes_len (peek), take_bytes(out), skip_bytes, done()

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ColumnOpts {
    /// Descending order for this column.
    pub desc: bool,
    /// NULLs sort before all values (default: after all values, whatever
    /// `desc` is; see the note on Postgres in the file header).
    pub nulls_first: bool,
}

impl ColumnOpts {
    /// Ascending, NULLS LAST: the default.
    pub const ASC: ColumnOpts = ColumnOpts {
        desc: false,
        nulls_first: false,
    };
    /// Descending, NULLS LAST (not what a bare `DESC` means in Postgres).
    pub const DESC: ColumnOpts = ColumnOpts {
        desc: true,
        nulls_first: false,
    };
}

pub const TAG_NULL_FIRST: u8 = 0x00;
pub const TAG_VALUE: u8 = 0x01;
pub const TAG_NULL_LAST: u8 = 0x02;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyError {
    /// The output buffer is too small.
    NoSpaceLeft,
    /// The key ended in the middle of a column.
    Truncated,
    /// A tag byte that this column (with these options) can never have.
    BadTag,
    /// An escape byte followed by something that is never escaped.
    BadEscape,
}

// ---- fixed-width primitives (ascending, no tag) ---------------------------

/// Big-endian: the most significant byte comes first, so the first byte that
/// differs between two keys is the most significant difference between the
/// numbers. Little-endian would compare the LEAST significant byte first.
pub fn encode_u64(v: u64) -> [u8; 8] {
    v.to_be_bytes()
}

pub fn decode_u64(b: [u8; 8]) -> u64 {
    u64::from_be_bytes(b)
}

const SIGN_BIT: u64 = 1 << 63;

/// Two's complement puts negative numbers (sign bit 1) after positive ones in
/// unsigned order. Flipping the sign bit moves the negative half below the
/// positive half and keeps the order inside each half:
///   i64 min -> 00 00.., -1 -> 7f ff.., 0 -> 80 00.., i64 max -> ff ff..
pub fn encode_i64(v: i64) -> [u8; 8] {
    encode_u64((v as u64) ^ SIGN_BIT)
}

pub fn decode_i64(b: [u8; 8]) -> i64 {
    (decode_u64(b) ^ SIGN_BIT) as i64
}

/// The one NaN bit pattern this encoder produces (a positive quiet NaN).
pub const CANONICAL_NAN: u64 = 0x7ff8_0000_0000_0000;

/// IEEE 754 doubles are sign-magnitude: for non-negative numbers the bit
/// pattern already sorts like the value, for negative numbers a larger
/// pattern means a smaller value. So:
///   non-negative: set the sign bit (moves them above all negatives)
///   negative:     invert every bit (reverses their order, clears the top bit)
/// Two normalisations keep "equal values have equal keys":
///   -0.0 is stored as +0.0 (they compare equal), and
///   every NaN is stored as `CANONICAL_NAN`, which sorts after +infinity.
/// Resulting order: -inf < negatives < 0 < positives < +inf < NaN.
pub fn encode_f64(v: f64) -> [u8; 8] {
    let mut bits = v.to_bits();
    if v == 0.0 {
        bits = 0;
    }
    if v.is_nan() {
        bits = CANONICAL_NAN;
    }
    encode_u64(if bits & SIGN_BIT == 0 { bits | SIGN_BIT } else { !bits })
}

pub fn decode_f64(b: [u8; 8]) -> f64 {
    let e = decode_u64(b);
    f64::from_bits(if e & SIGN_BIT != 0 { e ^ SIGN_BIT } else { !e })
}

/// Inverts every byte in place: turns an ascending encoding into a
/// descending one (a < b as bytes  <=>  !a > !b as bytes, for equal lengths
/// or when neither is a prefix of the other, which the terminator ensures).
pub fn invert(bytes: &mut [u8]) {
    for b in bytes {
        *b = !*b;
    }
}

// ---- variable-length byte strings -----------------------------------------

/// Escape scheme (the one DuckDB's ART keys use):
///   0x00 and 0x01 in the data are written as 0x01 followed by the byte,
///   and the string ends with a single 0x00 terminator.
/// Why a terminator: in a composite key the next column follows immediately,
/// so ("a", "b") and ("ab", "") would otherwise both be `61 62`. Why it must
/// be the smallest byte: a string must sort before every string it is a
/// prefix of, whatever column follows. Why escaping: the data may contain
/// 0x00 itself, and `00` -> `01 00`, `01` -> `01 01`, `02` -> `02` keeps order.
pub const TERMINATOR: u8 = 0x00;
pub const ESCAPE: u8 = 0x01;

pub fn encoded_bytes_len(s: &[u8]) -> usize {
    s.len() + 1 + s.iter().filter(|&&c| c <= ESCAPE).count()
}

/// Writes the escaped, terminated form of `s`. Writes nothing if it does not fit.
pub fn encode_bytes(out: &mut [u8], s: &[u8]) -> Result<usize, KeyError> {
    let n = encoded_bytes_len(s);
    if out.len() < n {
        return Err(KeyError::NoSpaceLeft);
    }
    let mut pos = 0;
    for &c in s {
        if c <= ESCAPE {
            out[pos] = ESCAPE;
            pos += 1;
        }
        out[pos] = c;
        pos += 1;
    }
    out[pos] = TERMINATOR;
    Ok(n)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodedBytes {
    /// Encoded bytes read, including the terminator.
    pub consumed: usize,
    /// Length of the original string.
    pub len: usize,
}

/// Undoes `encode_bytes` from the start of `enc`. `mask` is 0x00 for an
/// ascending column and 0xff for a descending one (bytes are un-inverted on
/// the fly). With `out == None` nothing is stored: use that to measure.
pub fn decode_bytes(mut out: Option<&mut [u8]>, enc: &[u8], mask: u8) -> Result<DecodedBytes, KeyError> {
    let mut pos = 0;
    let mut len = 0;
    loop {
        let mut c = *enc.get(pos).ok_or(KeyError::Truncated)? ^ mask;
        pos += 1;
        if c == TERMINATOR {
            return Ok(DecodedBytes { consumed: pos, len });
        }
        if c == ESCAPE {
            c = *enc.get(pos).ok_or(KeyError::Truncated)? ^ mask;
            pos += 1;
            if c > ESCAPE {
                return Err(KeyError::BadEscape);
            }
        }
        if let Some(o) = out.as_deref_mut() {
            *o.get_mut(len).ok_or(KeyError::NoSpaceLeft)? = c;
        }
        len += 1;
    }
}

// ---- KeyWriter: build a (composite) key in a caller buffer ----------------

#[derive(Debug)]
pub struct KeyWriter<'a> {
    buf: &'a mut [u8],
    len: usize,
}

impl<'a> KeyWriter<'a> {
    pub fn new(buf: &'a mut [u8]) -> Self {
        Self { buf, len: 0 }
    }

    /// The key built so far.
    pub fn written(&self) -> &[u8] {
        &self.buf[..self.len]
    }

    /// Number of key bytes written so far.
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Claims `n` bytes or fails without changing anything.
    fn reserve(&mut self, n: usize) -> Result<&mut [u8], KeyError> {
        if self.buf.len() - self.len < n {
            return Err(KeyError::NoSpaceLeft);
        }
        let out = &mut self.buf[self.len..self.len + n];
        self.len += n;
        Ok(out)
    }

    pub fn put_null(&mut self, opts: ColumnOpts) -> Result<(), KeyError> {
        let out = self.reserve(1)?;
        out[0] = if opts.nulls_first { TAG_NULL_FIRST } else { TAG_NULL_LAST };
        Ok(())
    }

    fn put_fixed(&mut self, payload: [u8; 8], opts: ColumnOpts) -> Result<(), KeyError> {
        let out = self.reserve(9)?;
        out[0] = TAG_VALUE;
        out[1..].copy_from_slice(&payload);
        if opts.desc {
            invert(&mut out[1..]);
        }
        Ok(())
    }

    pub fn put_u64(&mut self, v: u64, opts: ColumnOpts) -> Result<(), KeyError> {
        self.put_fixed(encode_u64(v), opts)
    }

    pub fn put_i64(&mut self, v: i64, opts: ColumnOpts) -> Result<(), KeyError> {
        self.put_fixed(encode_i64(v), opts)
    }

    pub fn put_f64(&mut self, v: f64, opts: ColumnOpts) -> Result<(), KeyError> {
        self.put_fixed(encode_f64(v), opts)
    }

    pub fn put_bytes(&mut self, s: &[u8], opts: ColumnOpts) -> Result<(), KeyError> {
        let out = self.reserve(1 + encoded_bytes_len(s))?;
        out[0] = TAG_VALUE;
        encode_bytes(&mut out[1..], s).expect("reserved exactly enough");
        // Inverted, the terminator is 0xff: a DESC string sorts AFTER the
        // strings it is a prefix of, which is what descending means.
        if opts.desc {
            invert(&mut out[1..]);
        }
        Ok(())
    }
}

// ---- KeyReader: take the columns back out, in the same order --------------

#[derive(Debug, Clone)]
pub struct KeyReader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> KeyReader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    /// True when every byte has been consumed. A well-formed key ends exactly
    /// after its last column.
    pub fn done(&self) -> bool {
        self.pos == self.bytes.len()
    }

    /// Bytes consumed so far.
    pub fn position(&self) -> usize {
        self.pos
    }

    /// Looks at the tag at `pos`: true = a value follows, false = NULL.
    fn peek_tag(&self, opts: ColumnOpts) -> Result<bool, KeyError> {
        let tag = *self.bytes.get(self.pos).ok_or(KeyError::Truncated)?;
        let null_tag = if opts.nulls_first { TAG_NULL_FIRST } else { TAG_NULL_LAST };
        if tag == TAG_VALUE {
            Ok(true)
        } else if tag == null_tag {
            Ok(false)
        } else {
            Err(KeyError::BadTag)
        }
    }

    fn take_fixed(&mut self, opts: ColumnOpts) -> Result<Option<[u8; 8]>, KeyError> {
        if !self.peek_tag(opts)? {
            self.pos += 1;
            return Ok(None);
        }
        let field = self.bytes.get(self.pos + 1..self.pos + 9).ok_or(KeyError::Truncated)?;
        let mut payload: [u8; 8] = field.try_into().expect("slice of length 8");
        if opts.desc {
            invert(&mut payload);
        }
        self.pos += 9;
        Ok(Some(payload))
    }

    pub fn take_u64(&mut self, opts: ColumnOpts) -> Result<Option<u64>, KeyError> {
        Ok(self.take_fixed(opts)?.map(decode_u64))
    }

    pub fn take_i64(&mut self, opts: ColumnOpts) -> Result<Option<i64>, KeyError> {
        Ok(self.take_fixed(opts)?.map(decode_i64))
    }

    pub fn take_f64(&mut self, opts: ColumnOpts) -> Result<Option<f64>, KeyError> {
        Ok(self.take_fixed(opts)?.map(decode_f64))
    }

    /// Decoded length of the byte-string column at the cursor (None = NULL),
    /// without consuming it. Lets the caller allocate exactly enough.
    pub fn bytes_len(&self, opts: ColumnOpts) -> Result<Option<usize>, KeyError> {
        if !self.peek_tag(opts)? {
            return Ok(None);
        }
        let mask = if opts.desc { 0xff } else { 0x00 };
        Ok(Some(decode_bytes(None, &self.bytes[self.pos + 1..], mask)?.len))
    }

    /// Consumes the byte-string column without storing it; returns its
    /// decoded length (None = NULL).
    pub fn skip_bytes(&mut self, opts: ColumnOpts) -> Result<Option<usize>, KeyError> {
        if !self.peek_tag(opts)? {
            self.pos += 1;
            return Ok(None);
        }
        let mask = if opts.desc { 0xff } else { 0x00 };
        let d = decode_bytes(None, &self.bytes[self.pos + 1..], mask)?;
        self.pos += 1 + d.consumed;
        Ok(Some(d.len))
    }

    /// Copies the byte-string column into `out` and returns its length
    /// (None = NULL). On any error the cursor has not moved.
    pub fn take_bytes(&mut self, out: &mut [u8], opts: ColumnOpts) -> Result<Option<usize>, KeyError> {
        if !self.peek_tag(opts)? {
            self.pos += 1;
            return Ok(None);
        }
        let mask = if opts.desc { 0xff } else { 0x00 };
        let d = decode_bytes(Some(out), &self.bytes[self.pos + 1..], mask)?;
        self.pos += 1 + d.consumed;
        Ok(Some(d.len))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cmp::Ordering;

    const ASC: ColumnOpts = ColumnOpts::ASC;
    const DESC: ColumnOpts = ColumnOpts::DESC;

    #[test]
    fn u64_big_endian_bytes_order_like_the_numbers() {
        let values = [0, 1, 255, 256, 65535, 65536, 1 << 32, u64::MAX - 1, u64::MAX];
        for (i, &a) in values.iter().enumerate() {
            assert_eq!(decode_u64(encode_u64(a)), a);
            for &b in &values[i + 1..] {
                assert!(encode_u64(a) < encode_u64(b));
            }
        }
        assert_eq!(encode_u64(256), [0, 0, 0, 0, 0, 0, 1, 0]);
    }

    #[test]
    fn i64_sign_flip_puts_negatives_first() {
        let values = [i64::MIN, -256, -2, -1, 0, 1, 2, 256, i64::MAX];
        for (i, &a) in values.iter().enumerate() {
            assert_eq!(decode_i64(encode_i64(a)), a);
            for &b in &values[i + 1..] {
                assert!(encode_i64(a) < encode_i64(b));
            }
        }
        assert_eq!(encode_i64(-1), [0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]);
        assert_eq!(encode_i64(0), [0x80, 0, 0, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn f64_total_order_minus_zero_and_nan_normalised() {
        let tiny = f64::from_bits(1); // smallest subnormal
        let values = [
            f64::NEG_INFINITY,
            -1.0e300,
            -1.5,
            -f64::MIN_POSITIVE,
            -tiny,
            0.0,
            tiny,
            1.5,
            1.0e300,
            f64::INFINITY,
            f64::NAN,
        ];
        for (i, &a) in values.iter().enumerate() {
            for &b in &values[i + 1..] {
                assert!(encode_f64(a) < encode_f64(b));
            }
        }
        for &a in &values[..values.len() - 1] {
            assert_eq!(decode_f64(encode_f64(a)), a);
        }
        // -0.0 and +0.0 are equal, so they must have the same key ...
        assert_eq!(encode_f64(0.0), encode_f64(-0.0));
        // ... which means the sign of zero does not survive a round trip.
        assert!(decode_f64(encode_f64(-0.0)).is_sign_positive());
        // Any NaN (here: negative, with payload) becomes the canonical one.
        let odd_nan = f64::from_bits(0xfff0_0000_0000_beef);
        assert_eq!(encode_f64(f64::NAN), encode_f64(odd_nan));
        assert_eq!(decode_f64(encode_f64(odd_nan)).to_bits(), CANONICAL_NAN);
    }

    #[test]
    fn bytes_escaping_keeps_order_and_round_trips() {
        // Already in logical (lexicographic) order.
        let values: [&[u8]; 15] = [
            b"",
            b"\x00",
            b"\x00\x00",
            b"\x00\x01",
            b"\x01",
            b"\x01\x00",
            b"\x02",
            b"a",
            b"a\x00",
            b"a\x00b",
            b"a\x01",
            b"a\x02",
            b"ab",
            b"b",
            b"\xff",
        ];
        let mut ea = [0u8; 16];
        let mut eb = [0u8; 16];
        let mut back = [0u8; 8];
        for (i, &a) in values.iter().enumerate() {
            let na = encode_bytes(&mut ea, a).unwrap();
            assert_eq!(na, encoded_bytes_len(a));
            let d = decode_bytes(Some(&mut back), &ea[..na], 0).unwrap();
            assert_eq!(d.consumed, na);
            assert_eq!(&back[..d.len], a);
            for &b in &values[i + 1..] {
                let nb = encode_bytes(&mut eb, b).unwrap();
                assert!(ea[..na] < eb[..nb]);
            }
        }
        let n = encode_bytes(&mut ea, b"a\x00b").unwrap();
        assert_eq!(&ea[..n], [b'a', 0x01, 0x00, b'b', 0x00]);
    }

    #[test]
    fn bytes_decode_errors() {
        let mut out = [0u8; 4];
        assert_eq!(decode_bytes(Some(&mut out), b"ab", 0), Err(KeyError::Truncated)); // no terminator
        assert_eq!(decode_bytes(Some(&mut out), b"a\x01", 0), Err(KeyError::Truncated)); // escape, then nothing
        assert_eq!(decode_bytes(Some(&mut out), b"a\x01b\x00", 0), Err(KeyError::BadEscape));
        assert_eq!(decode_bytes(Some(&mut out), b"abcde\x00", 0), Err(KeyError::NoSpaceLeft));
        assert_eq!(decode_bytes(None, b"abcde\x00", 0).unwrap().len, 5); // measuring needs no buffer
        assert_eq!(encode_bytes(&mut out[..2], b"ab"), Err(KeyError::NoSpaceLeft));
    }

    #[test]
    fn composite_the_terminator_keeps_column_boundaries_apart() {
        let mut ba = [0u8; 32];
        let mut bb = [0u8; 32];
        let mut a = KeyWriter::new(&mut ba);
        let mut b = KeyWriter::new(&mut bb);
        // ("a", "b") < ("ab", "") because "a" < "ab" in the first column.
        a.put_bytes(b"a", ASC).unwrap();
        a.put_bytes(b"b", ASC).unwrap();
        b.put_bytes(b"ab", ASC).unwrap();
        b.put_bytes(b"", ASC).unwrap();
        assert_eq!(a.written().cmp(b.written()), Ordering::Less);
        assert_eq!(a.written(), [1, b'a', 0, 1, b'b', 0]);
    }

    /// Builds a one-column key with `put` and returns its bytes.
    fn key(put: impl FnOnce(&mut KeyWriter<'_>) -> Result<(), KeyError>) -> Vec<u8> {
        let mut buf = [0u8; 32];
        let mut w = KeyWriter::new(&mut buf);
        put(&mut w).unwrap();
        w.written().to_vec()
    }

    #[test]
    fn descending_and_null_placement() {
        // DESC ints: 5 sorts before 3.
        assert!(key(|w| w.put_i64(5, DESC)) < key(|w| w.put_i64(3, DESC)));
        // DESC strings: "ab" sorts before its prefix "a".
        assert!(key(|w| w.put_bytes(b"ab", DESC)) < key(|w| w.put_bytes(b"a", DESC)));

        // NULLS LAST (default) and NULLS FIRST, each for ASC and DESC: the tag is
        // never inverted, so the NULL position does not depend on `desc`.
        for desc in [false, true] {
            let last = ColumnOpts { desc, nulls_first: false };
            assert!(key(|w| w.put_i64(i64::MAX, last)) < key(|w| w.put_null(last)));
            let first = ColumnOpts { desc, nulls_first: true };
            assert!(key(|w| w.put_null(first)) < key(|w| w.put_i64(i64::MIN, first)));
        }
    }

    #[test]
    fn key_writer_is_all_or_nothing_key_reader_round_trips_every_column_kind() {
        let mut buf = [0u8; 64];
        let mut w = KeyWriter::new(&mut buf);
        w.put_u64(7, ASC).unwrap();
        w.put_i64(-7, DESC).unwrap();
        w.put_f64(-2.5, DESC).unwrap();
        w.put_bytes(b"k\x00y", DESC).unwrap();
        w.put_null(ASC).unwrap();
        w.put_bytes(b"", ASC).unwrap();
        assert!(!w.is_empty());
        let full = w.len();
        let key = w.written().to_vec();

        // No room: nothing is written, the key so far is intact.
        let mut small_buf = vec![0u8; full];
        let mut small = KeyWriter::new(&mut small_buf);
        small.len = full - 3;
        assert_eq!(small.put_u64(1, ASC), Err(KeyError::NoSpaceLeft));
        assert_eq!(small.put_bytes(b"abc", ASC), Err(KeyError::NoSpaceLeft));
        assert_eq!(small.len(), full - 3);

        let mut r = KeyReader::new(&key);
        let mut out = [0u8; 8];
        assert_eq!(r.take_u64(ASC), Ok(Some(7)));
        assert_eq!(r.take_i64(DESC), Ok(Some(-7)));
        assert_eq!(r.take_f64(DESC), Ok(Some(-2.5)));
        assert_eq!(r.bytes_len(DESC), Ok(Some(3)));
        let before = r.position();
        assert_eq!(r.take_bytes(&mut out[..2], DESC), Err(KeyError::NoSpaceLeft));
        assert_eq!(r.position(), before); // cursor stays put
        assert_eq!(r.take_bytes(&mut out, DESC), Ok(Some(3)));
        assert_eq!(&out[..3], b"k\x00y");
        assert_eq!(r.take_i64(ASC), Ok(None));
        assert_eq!(r.skip_bytes(ASC), Ok(Some(0)));
        assert!(r.done());
        assert_eq!(r.take_u64(ASC), Err(KeyError::Truncated));

        // A NULLS LAST tag is not valid for a NULLS FIRST column, and vice versa.
        let nulls_first = ColumnOpts {
            desc: false,
            nulls_first: true,
        };
        assert_eq!(KeyReader::new(&[TAG_NULL_LAST]).take_i64(nulls_first), Err(KeyError::BadTag));
        assert_eq!(KeyReader::new(&[TAG_VALUE, 1, 2, 3]).take_u64(ASC), Err(KeyError::Truncated));
    }
}
