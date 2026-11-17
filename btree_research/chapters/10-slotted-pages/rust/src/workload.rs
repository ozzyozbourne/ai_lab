//! Turns the u64 keys and values of the shared operation stream (ops.rs)
//! into the variable-length byte strings a slotted page stores. Used by the
//! model test and by part 3 of the demo; the Zig twin produces the same bytes.

pub const MAX_KEY_LEN: usize = 12;
pub const MAX_VALUE_LEN: usize = 40;

/// 8 bytes big-endian (so byte order equals numeric order) followed by
/// `key % 5` bytes of 'x' (so cells have different sizes).
pub fn key_bytes(buf: &mut [u8; MAX_KEY_LEN], key: u64) -> &[u8] {
    buf[..8].copy_from_slice(&key.to_be_bytes());
    let extra = (key % 5) as usize;
    buf[8..8 + extra].fill(b'x');
    &buf[..8 + extra]
}

/// `value % 40` bytes derived from the bits of `value`.
pub fn value_bytes(buf: &mut [u8; MAX_VALUE_LEN], value: u64) -> &[u8] {
    let len = (value % MAX_VALUE_LEN as u64) as usize;
    for (i, b) in buf[..len].iter_mut().enumerate() {
        *b = (value >> (8 * (i % 8))) as u8 ^ i as u8;
    }
    &buf[..len]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_bytes_keeps_numeric_order_and_varies_the_length() {
        let mut a = [0u8; MAX_KEY_LEN];
        let mut b = [0u8; MAX_KEY_LEN];
        for k in 0..600u64 {
            assert!(key_bytes(&mut a, k) < key_bytes(&mut b, k + 1));
        }
        assert_eq!(key_bytes(&mut a, 5).len(), 8);
        assert_eq!(key_bytes(&mut a, 9).len(), 12);
    }

    #[test]
    fn value_bytes_golden() {
        let mut buf = [0u8; MAX_VALUE_LEN];
        assert_eq!(value_bytes(&mut buf, 40).len(), 0);
        assert_eq!(value_bytes(&mut buf, 43), &[0x2b, 0x01, 0x02]);
        assert_eq!(value_bytes(&mut buf, 79).len(), 39);
    }
}
