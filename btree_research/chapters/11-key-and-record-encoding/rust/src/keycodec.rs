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

    // ---- property tests ------------------------------------------------------
    //
    // Everything below uses only this file, so the tests travel with it when it
    // is copied. Each test compares the encoder with `test_order`, an oracle
    // that looks at values and never at bytes.

    /// SplitMix64, for tests only: deterministic, the same in the Zig twin.
    struct TestRng(u64);

    impl TestRng {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }

        /// Integer in [0, n).
        fn below(&mut self, n: usize) -> usize {
            ((u128::from(self.next()) * n as u128) >> 64) as usize
        }

        fn opts(&mut self) -> ColumnOpts {
            let desc = self.below(2) == 1;
            let nulls_first = self.below(2) == 1;
            ColumnOpts { desc, nulls_first }
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum TestKind {
        U64,
        I64,
        F64,
        Bytes,
    }

    const TEST_KINDS: [TestKind; 4] = [TestKind::U64, TestKind::I64, TestKind::F64, TestKind::Bytes];

    #[derive(Debug, Clone, PartialEq)]
    enum TestValue {
        Null,
        U64(u64),
        I64(i64),
        F64(f64),
        Bytes(Vec<u8>),
    }

    const TEST_MAX_COLS: usize = 5;
    /// Longest random byte string. Its encoding is at most 2 * 40 + 1 bytes.
    const TEST_MAX_BYTES: usize = 40;
    const TEST_MAX_KEY: usize = TEST_MAX_COLS * (2 * TEST_MAX_BYTES + 2);

    /// Float order the encoding promises: -0 equals +0, every NaN equals every
    /// other NaN and is greater than all numbers.
    fn test_order_f64(a: f64, b: f64) -> Ordering {
        a.partial_cmp(&b).unwrap_or_else(|| a.is_nan().cmp(&b.is_nan()))
    }

    /// The logical order of two values of one column.
    fn test_order(a: &TestValue, b: &TestValue, opts: ColumnOpts) -> Ordering {
        let null_vs_value = if opts.nulls_first { Ordering::Less } else { Ordering::Greater };
        let asc = match (a, b) {
            (TestValue::Null, TestValue::Null) => return Ordering::Equal,
            (TestValue::Null, _) => return null_vs_value,
            (_, TestValue::Null) => return null_vs_value.reverse(),
            (TestValue::U64(x), TestValue::U64(y)) => x.cmp(y),
            (TestValue::I64(x), TestValue::I64(y)) => x.cmp(y),
            (TestValue::F64(x), TestValue::F64(y)) => test_order_f64(*x, *y),
            (TestValue::Bytes(x), TestValue::Bytes(y)) => x.cmp(y), // plain lexicographic order
            _ => unreachable!("both values belong to the same column"),
        };
        if opts.desc { asc.reverse() } else { asc }
    }

    fn test_put(w: &mut KeyWriter<'_>, v: &TestValue, opts: ColumnOpts) -> Result<(), KeyError> {
        match v {
            TestValue::Null => w.put_null(opts),
            TestValue::U64(x) => w.put_u64(*x, opts),
            TestValue::I64(x) => w.put_i64(*x, opts),
            TestValue::F64(x) => w.put_f64(*x, opts),
            TestValue::Bytes(x) => w.put_bytes(x, opts),
        }
    }

    /// Reads one column of `kind`.
    fn test_take(r: &mut KeyReader<'_>, kind: TestKind, opts: ColumnOpts) -> Result<TestValue, KeyError> {
        Ok(match kind {
            TestKind::U64 => r.take_u64(opts)?.map_or(TestValue::Null, TestValue::U64),
            TestKind::I64 => r.take_i64(opts)?.map_or(TestValue::Null, TestValue::I64),
            TestKind::F64 => r.take_f64(opts)?.map_or(TestValue::Null, TestValue::F64),
            TestKind::Bytes => {
                let mut out = [0u8; TEST_MAX_KEY];
                match r.take_bytes(&mut out, opts)? {
                    None => TestValue::Null,
                    Some(n) => TestValue::Bytes(out[..n].to_vec()),
                }
            }
        })
    }

    /// Why `test_read_all` refused a key.
    #[derive(Debug, PartialEq, Eq)]
    enum ReadAllError {
        Key(KeyError),
        TrailingBytes,
    }

    /// Reads a whole key without storing anything (byte strings are skipped).
    fn test_read_all(key: &[u8], kinds: &[TestKind], opts: &[ColumnOpts]) -> Result<(), ReadAllError> {
        let mut r = KeyReader::new(key);
        for (&kind, &o) in kinds.iter().zip(opts) {
            match kind {
                TestKind::U64 => r.take_u64(o).map(drop),
                TestKind::I64 => r.take_i64(o).map(drop),
                TestKind::F64 => r.take_f64(o).map(drop),
                TestKind::Bytes => r.skip_bytes(o).map(drop),
            }
            .map_err(ReadAllError::Key)?;
        }
        if r.done() { Ok(()) } else { Err(ReadAllError::TrailingBytes) }
    }

    /// Bit patterns at every edge of the f64 format: both zeros, the smallest and
    /// largest subnormals, the smallest normal, the largest finite, infinities,
    /// signalling and quiet NaNs with and without payload, neighbours of 1.0, 2^53.
    const TEST_F64_BITS: [u64; 28] = [
        0x0000000000000000,
        0x8000000000000000,
        0x0000000000000001,
        0x8000000000000001,
        0x000fffffffffffff,
        0x800fffffffffffff,
        0x0010000000000000,
        0x8010000000000000,
        0x7fefffffffffffff,
        0xffefffffffffffff,
        0x7ff0000000000000,
        0xfff0000000000000,
        0x7ff0000000000001,
        0xfff0000000000001,
        0x7ff8000000000000,
        0xfff8000000000000,
        0x7fffffffffffffff,
        0xffffffffffffffff,
        0x3ff0000000000000,
        0xbff0000000000000,
        0x3ff0000000000001,
        0xbff0000000000001,
        0x3fefffffffffffff,
        0xbfefffffffffffff,
        0x4340000000000000,
        0xc340000000000000,
        0x7ff4000000000000,
        0xfff000000000beef,
    ];

    /// Integers around every place where a byte of the encoding rolls over.
    const TEST_I64: [i64; 20] = [
        i64::MIN,
        i64::MIN + 1,
        -0x1_0000_0001,
        -0x8000_0000,
        -257,
        -256,
        -255,
        -129,
        -128,
        -1,
        0,
        1,
        127,
        128,
        255,
        256,
        0x7fff_ffff,
        0x1_0000_0000,
        i64::MAX - 1,
        i64::MAX,
    ];

    /// The data bytes that collide with the framing: 00 terminator, 01 escape and
    /// value tag, 02 NULLS LAST tag, and fd fe ff, which become 02 01 00 when a
    /// DESC column is inverted.
    const TEST_ALPHABET: [u8; 7] = [0x00, 0x01, 0x02, 0xfd, 0xfe, 0xff, b'a'];

    fn test_random_f64(rng: &mut TestRng) -> f64 {
        let special = TEST_F64_BITS[rng.below(TEST_F64_BITS.len())];
        match rng.below(4) {
            0 => f64::from_bits(special),
            1 => f64::from_bits(rng.next()), // any bit pattern, NaNs included
            2 => f64::from_bits(special.wrapping_add(rng.below(5) as u64).wrapping_sub(2)), // within 2 ulp of a special
            _ => (rng.below(9) as i64 - 4) as f64 / 2.0, // many ties
        }
    }

    fn test_random_i64(rng: &mut TestRng) -> i64 {
        match rng.below(4) {
            0 => TEST_I64[rng.below(TEST_I64.len())],
            1 => rng.next() as i64,
            2 => 1i64 << rng.below(63),
            _ => rng.below(7) as i64 - 3, // many ties
        }
    }

    /// Mostly short strings (so that ties and prefixes are common), sometimes up
    /// to `TEST_MAX_BYTES`; bytes from the nasty alphabet or from all 256 values.
    fn test_random_bytes(rng: &mut TestRng) -> Vec<u8> {
        let n = if rng.below(4) == 0 {
            rng.below(TEST_MAX_BYTES + 1)
        } else {
            rng.below(5)
        };
        (0..n)
            .map(|_| {
                if rng.below(4) == 0 {
                    rng.next() as u8
                } else {
                    TEST_ALPHABET[rng.below(TEST_ALPHABET.len())]
                }
            })
            .collect()
    }

    fn test_random_value(rng: &mut TestRng, kind: TestKind) -> TestValue {
        if rng.below(7) == 0 {
            return TestValue::Null;
        }
        match kind {
            TestKind::U64 => TestValue::U64(test_random_i64(rng) as u64),
            TestKind::I64 => TestValue::I64(test_random_i64(rng)),
            TestKind::F64 => TestValue::F64(test_random_f64(rng)),
            TestKind::Bytes => TestValue::Bytes(test_random_bytes(rng)),
        }
    }

    /// Encodes `row` into a fresh `Vec`; also returns the key length after each column.
    fn test_encode(row: &[TestValue], opts: &[ColumnOpts]) -> (Vec<u8>, Vec<usize>) {
        let mut buf = [0u8; TEST_MAX_KEY + 1];
        let mut w = KeyWriter::new(&mut buf);
        let mut ends = Vec::new();
        for (v, &o) in row.iter().zip(opts) {
            test_put(&mut w, v, o).unwrap();
            ends.push(w.len());
        }
        (w.written().to_vec(), ends)
    }

    #[test]
    fn f64_byte_order_is_the_total_order_on_every_special_pattern_and_on_random_bits() {
        for &x in &TEST_F64_BITS {
            for &y in &TEST_F64_BITS {
                let (a, b) = (f64::from_bits(x), f64::from_bits(y));
                assert_eq!(encode_f64(a).cmp(&encode_f64(b)), test_order_f64(a, b), "{x:016x} {y:016x}");
            }
        }
        let mut rng = TestRng(1);
        for _ in 0..20_000 {
            let a = test_random_f64(&mut rng);
            let b = test_random_f64(&mut rng);
            let ea = encode_f64(a);
            assert_eq!(ea.cmp(&encode_f64(b)), test_order_f64(a, b));
            // Decoding gives an equal value, and encoding that gives the same key.
            let back = decode_f64(ea);
            assert_eq!(test_order_f64(a, back), Ordering::Equal);
            assert_eq!(encode_f64(back), ea);
            // Apart from -0.0 and NaN the round trip is exact to the bit.
            if !a.is_nan() && a.to_bits() != SIGN_BIT {
                assert_eq!(back.to_bits(), a.to_bits());
            }
        }
    }

    #[test]
    fn i64_and_u64_byte_order_is_numeric_order_on_extremes_and_on_random_values() {
        for &a in &TEST_I64 {
            for &b in &TEST_I64 {
                assert_eq!(encode_i64(a).cmp(&encode_i64(b)), a.cmp(&b));
            }
        }
        let mut rng = TestRng(2);
        for _ in 0..20_000 {
            let a = test_random_i64(&mut rng);
            let b = test_random_i64(&mut rng);
            assert_eq!(encode_i64(a).cmp(&encode_i64(b)), a.cmp(&b));
            assert_eq!(decode_i64(encode_i64(a)), a);
            // The same bits read as unsigned: no sign flip, a different order.
            let (ua, ub) = (a as u64, b as u64);
            assert_eq!(encode_u64(ua).cmp(&encode_u64(ub)), ua.cmp(&ub));
            assert_eq!(decode_u64(encode_u64(ua)), ua);
        }
    }

    /// Every string over `letters` of length 0 to `max_len`, shortest first.
    fn test_all_strings(letters: &[u8], max_len: usize) -> Vec<Vec<u8>> {
        let mut all = vec![Vec::new()];
        let mut start = 0;
        for _ in 0..max_len {
            let end = all.len();
            for i in start..end {
                for &c in letters {
                    let mut s = all[i].clone();
                    s.push(c);
                    all.push(s);
                }
            }
            start = end;
        }
        all
    }

    #[test]
    fn bytes_every_string_of_up_to_3_framing_bytes_asc_and_desc() {
        // 00 01 02 are terminator, escape and a tag; fe ff are what turns into
        // escape and terminator once a DESC column is inverted.
        let strings = test_all_strings(&[0x00, 0x01, 0x02, 0xfe, 0xff], 3);
        assert_eq!(strings.len(), 1 + 5 + 25 + 125);
        for desc in [false, true] {
            let opts = ColumnOpts { desc, nulls_first: false };
            let mut keys = Vec::new();
            for s in &strings {
                let value = TestValue::Bytes(s.clone());
                let (key, _) = test_encode(std::slice::from_ref(&value), &[opts]);
                assert_eq!(key.len(), 1 + encoded_bytes_len(s));
                let mut r = KeyReader::new(&key);
                assert_eq!(test_take(&mut r, TestKind::Bytes, opts), Ok(value));
                assert!(r.done());
                keys.push(key);
            }
            for (a, ka) in strings.iter().zip(&keys) {
                for (b, kb) in strings.iter().zip(&keys) {
                    let logical = if desc { b.cmp(a) } else { a.cmp(b) };
                    assert_eq!(ka.cmp(kb), logical, "{a:02x?} {b:02x?} desc={desc}");
                }
            }
        }
    }

    #[test]
    fn composite_bytes_bytes_all_short_framing_strings_and_null_all_16_option_combinations() {
        // Column 1 of one row is often a prefix of column 1 of the other while
        // column 2 pulls the other way: only correct framing gets these right.
        let mut values = vec![TestValue::Null];
        values.extend(test_all_strings(&[0x00, 0x01, 0xfe, 0xff], 2).into_iter().map(TestValue::Bytes));
        let count = values.len();
        assert_eq!(count, 1 + 1 + 4 + 16);
        for combo in 0..16 {
            let o1 = ColumnOpts {
                desc: combo & 1 != 0,
                nulls_first: combo & 2 != 0,
            };
            let o2 = ColumnOpts {
                desc: combo & 4 != 0,
                nulls_first: combo & 8 != 0,
            };
            let mut keys = Vec::new();
            for row in 0..count * count {
                let mut buf = [0u8; 12]; // 2 * (tag + 4 escaped bytes + terminator)
                let mut w = KeyWriter::new(&mut buf);
                test_put(&mut w, &values[row / count], o1).unwrap();
                test_put(&mut w, &values[row % count], o2).unwrap();
                let n = w.len();
                keys.push((buf, n));
            }
            for a in 0..count * count {
                for b in 0..count * count {
                    let logical = test_order(&values[a / count], &values[b / count], o1)
                        .then_with(|| test_order(&values[a % count], &values[b % count], o2));
                    let (ka, kb) = (&keys[a].0[..keys[a].1], &keys[b].0[..keys[b].1]);
                    assert_eq!(ka.cmp(kb), logical, "options {combo}, rows {a} and {b}");
                }
            }
        }
    }

    #[test]
    fn random_schemas_key_order_is_logical_order_round_trip_every_truncation_rejected() {
        let mut rng = TestRng(0x5eed);
        let mut seen = [0u32; 3];
        for _ in 0..4000 {
            // A random schema: 1 to 5 columns of any kind with any options.
            let ncol = 1 + rng.below(TEST_MAX_COLS);
            let mut kinds = Vec::new();
            let mut opts = Vec::new();
            for _ in 0..ncol {
                kinds.push(TEST_KINDS[rng.below(4)]);
                opts.push(rng.opts());
            }
            // Two random rows ...
            let mut rows: [Vec<TestValue>; 2] = [Vec::new(), Vec::new()];
            for row in &mut rows {
                for &kind in &kinds {
                    row.push(test_random_value(&mut rng, kind));
                }
            }
            // ... that share a prefix of columns, so later columns and ties matter ...
            let shared = rng.below(ncol + 1);
            let (first, second) = rows.split_at_mut(1);
            second[0][..shared].clone_from_slice(&first[0][..shared]);
            // ... and where one string is often a prefix of the other, or one byte longer.
            let pc = rng.below(ncol);
            if let TestValue::Bytes(s) = &first[0][pc]
                && rng.below(2) == 0
            {
                let mut t = s[..rng.below(s.len() + 1)].to_vec();
                if t.len() < TEST_MAX_BYTES && rng.below(2) == 0 {
                    t.push(TEST_ALPHABET[rng.below(TEST_ALPHABET.len())]);
                }
                second[0][pc] = TestValue::Bytes(t);
            }

            let mut logical = Ordering::Equal;
            for c in 0..ncol {
                logical = test_order(&rows[0][c], &rows[1][c], opts[c]);
                if logical != Ordering::Equal {
                    break;
                }
            }
            seen[(logical as i8 + 1) as usize] += 1;

            let mut keys = Vec::new();
            for row in &rows {
                let (key, ends) = test_encode(row, &opts);

                // Round trip: equal values come back, and they encode to the same bytes.
                let mut reader = KeyReader::new(&key);
                let mut back = Vec::new();
                for c in 0..ncol {
                    let peeked = if kinds[c] == TestKind::Bytes {
                        reader.bytes_len(opts[c]).unwrap()
                    } else {
                        None
                    };
                    let v = test_take(&mut reader, kinds[c], opts[c]).unwrap();
                    assert_eq!(test_order(&row[c], &v, opts[c]), Ordering::Equal);
                    if let TestValue::Bytes(s) = &v {
                        assert_eq!(peeked, Some(s.len()));
                    }
                    assert_eq!(reader.position(), ends[c]);
                    back.push(v);
                }
                assert!(reader.done());
                assert_eq!(test_encode(&back, &opts).0, key);

                for cut in 0..key.len() {
                    // A key cut anywhere is Truncated, never garbage and never a crash.
                    assert_eq!(
                        test_read_all(&key[..cut], &kinds, &opts),
                        Err(ReadAllError::Key(KeyError::Truncated))
                    );
                    // A buffer of `cut` bytes holds the columns that fit completely
                    // and not one byte of the column that does not.
                    let mut small_buf = [0u8; TEST_MAX_KEY];
                    let mut small = KeyWriter::new(&mut small_buf[..cut]);
                    let mut fitted = 0;
                    for c in 0..ncol {
                        if test_put(&mut small, &row[c], opts[c]).is_err() {
                            break;
                        }
                        fitted = ends[c];
                    }
                    assert!(fitted < key.len());
                    assert_eq!(small.len(), fitted);
                    assert_eq!(small.written(), &key[..fitted]);
                }
                // One byte too many is noticed as well.
                let mut longer = key.clone();
                longer.push(TAG_VALUE);
                assert_eq!(test_read_all(&longer, &kinds, &opts), Err(ReadAllError::TrailingBytes));
                keys.push(key);
            }

            assert_eq!(
                keys[0].cmp(&keys[1]),
                logical,
                "{kinds:?} {opts:?}\n  {:?}\n  {:?}",
                rows[0],
                rows[1]
            );
        }
        // All three outcomes must be common, or the test proves little.
        assert!(seen.iter().all(|&n| n > 500), "{seen:?}");
    }

    #[test]
    fn decoder_fuzz_damaged_keys_and_random_bytes_never_crash_the_reader_and_what_it_accepts_is_canonical() {
        const BIAS: [u8; 9] = [0x00, 0x01, 0x02, 0x03, 0x7f, 0x80, 0xfd, 0xfe, 0xff];
        let mut rng = TestRng(99);
        let (mut accepted, mut rejected) = (0, 0);
        'input: for _ in 0..50_000 {
            let ncol = 1 + rng.below(3);
            let mut kinds = Vec::new();
            let mut opts = Vec::new();
            for _ in 0..ncol {
                kinds.push(TEST_KINDS[rng.below(4)]);
                opts.push(rng.opts());
            }

            // The input: random bytes, or a valid key with one byte overwritten
            // (which is how most corruption looks, and gets much deeper into the
            // reader than noise does).
            let input: Vec<u8> = if rng.below(3) == 0 {
                (0..rng.below(21)).map(|_| rng.next() as u8).collect()
            } else {
                let row: Vec<TestValue> = kinds.iter().map(|&kind| test_random_value(&mut rng, kind)).collect();
                let mut key = test_encode(&row, &opts).0;
                let at = rng.below(key.len());
                key[at] = if rng.below(4) == 0 {
                    rng.next() as u8
                } else {
                    BIAS[rng.below(BIAS.len())]
                };
                key
            };

            let mut reader = KeyReader::new(&input);
            let mut back = Vec::new();
            let mut canonical = true;
            for c in 0..ncol {
                let before = reader.position();
                let Ok(v) = test_take(&mut reader, kinds[c], opts[c]) else {
                    assert_eq!(reader.position(), before); // an error never moves the cursor
                    rejected += 1;
                    continue 'input;
                };
                // The reader takes any 8 bytes as an f64. The two families that
                // encode_f64 never writes (-0.0, NaNs other than the canonical one)
                // are for the layer above to reject.
                if let TestValue::F64(x) = v
                    && (x.to_bits() == SIGN_BIT || (x.is_nan() && x.to_bits() != CANONICAL_NAN))
                {
                    canonical = false;
                }
                back.push(v);
            }
            if !reader.done() {
                rejected += 1;
                continue;
            }
            accepted += 1;
            // Accepted and canonical means: these are exactly the bytes the
            // writer produces for the decoded values. No second spelling exists.
            if canonical {
                assert_eq!(test_encode(&back, &opts).0, input);
            }
        }
        assert!(accepted > 5000 && rejected > 5000, "{accepted} {rejected}");
    }
}
