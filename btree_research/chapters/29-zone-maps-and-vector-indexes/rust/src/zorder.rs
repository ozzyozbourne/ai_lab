//! Why a B-tree cannot index 2-D points for nearness: flatten the plane into
//! one sorted order and measure how far apart touching cells end up.
//!
//! Two orders over a side x side grid:
//!   row-major: position = y * side + x          (sort by y, then x)
//!   Z-order:   position = interleaved bits of x and y (Morton code)
//! For every pair of cells that touch (share an edge) we take the distance
//! between their positions in the order. In a B-tree that distance is "how
//! many keys lie between them", i.e. how long a range scan must be to reach
//! one from the other.

/// Morton code: bit i of x goes to bit 2i, bit i of y to bit 2i+1.
pub fn interleave(x: u16, y: u16) -> u32 {
    let mut z = 0u32;
    for i in 0..16 {
        z |= (u32::from(x >> i) & 1) << (2 * i);
        z |= (u32::from(y >> i) & 1) << (2 * i + 1);
    }
    z
}

pub fn row_major(side: u32, x: u16, y: u16) -> u32 {
    u32::from(y) * side + u32::from(x)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Curve {
    RowMajor,
    ZOrder,
}

impl Curve {
    pub fn name(self) -> &'static str {
        match self {
            Curve::RowMajor => "row_major",
            Curve::ZOrder => "z_order",
        }
    }

    fn position(self, side: u32, x: u16, y: u16) -> u32 {
        match self {
            Curve::RowMajor => row_major(side, x, y),
            Curve::ZOrder => interleave(x, y),
        }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct GapStats {
    /// Touching pairs: 2 * side * (side - 1).
    pub pairs: u32,
    /// Pairs whose positions differ by at least `side`.
    pub far_pairs: u32,
    pub max_gap: u32,
    pub sum_gap: u64,
}

impl GapStats {
    fn record(&mut self, side: u32, a: u32, b: u32) {
        let gap = a.abs_diff(b);
        self.pairs += 1;
        self.sum_gap += u64::from(gap);
        self.max_gap = self.max_gap.max(gap);
        if gap >= side {
            self.far_pairs += 1;
        }
    }
}

pub fn gap_stats(curve: Curve, side: u32) -> GapStats {
    assert!((2..=256).contains(&side));
    let mut stats = GapStats::default();
    for y in 0..side as u16 {
        for x in 0..side as u16 {
            let here = curve.position(side, x, y);
            if u32::from(x) + 1 < side {
                stats.record(side, here, curve.position(side, x + 1, y));
            }
            if u32::from(y) + 1 < side {
                stats.record(side, here, curve.position(side, x, y + 1));
            }
        }
    }
    stats
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interleave_known_morton_codes() {
        assert_eq!(interleave(0, 0), 0);
        assert_eq!(interleave(1, 0), 1);
        assert_eq!(interleave(0, 1), 2);
        assert_eq!(interleave(1, 1), 3);
        assert_eq!(interleave(0b011, 0b101), 0b100111);
        assert_eq!(interleave(0xFFFF, 0xFFFF), 0xFFFF_FFFF);
    }

    #[test]
    fn z_order_is_a_bijection_on_the_grid() {
        let mut seen = [false; 64];
        for y in 0..8 {
            for x in 0..8 {
                let z = interleave(x, y) as usize;
                assert!(!seen[z]);
                seen[z] = true;
            }
        }
    }

    #[test]
    fn no_order_keeps_all_touching_cells_close() {
        for side in [4, 8, 16, 32] {
            let rm = gap_stats(Curve::RowMajor, side);
            let z = gap_stats(Curve::ZOrder, side);
            assert_eq!(rm.pairs, 2 * side * (side - 1));
            assert_eq!(z.pairs, rm.pairs);
            // Row-major: every vertical pair is exactly `side` apart.
            assert_eq!(rm.max_gap, side);
            assert_eq!(rm.far_pairs, side * (side - 1));
            // Z-order: fewer far pairs, but the worst one is much worse.
            assert!(z.far_pairs < rm.far_pairs);
            assert!(z.max_gap > rm.max_gap);
            assert!(z.far_pairs > 0);
        }
    }
}
