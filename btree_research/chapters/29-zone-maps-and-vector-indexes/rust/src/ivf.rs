//! IVF ("inverted file") index: a two-level tree whose root is not ordered.
//!
//!   root:   nlist centroids                     (B-tree: sorted separators)
//!   leaves: one flat list of vectors per centroid   (B-tree: leaf pages)
//!
//! Routing in a B-tree is a binary search that picks exactly one child. Here
//! the root has no order to search, so routing is itself a nearest-neighbour
//! scan over all centroids, and because the query's true neighbours may sit
//! just across a cell boundary, the search visits the `nprobe` nearest
//! leaves instead of one. The answer is approximate; "recall" measures it
//! against brute force.
//!
//! Everything is integer arithmetic (i32 coordinates, u64 squared distances,
//! ties broken by id), so the Zig and Rust programs agree bit for bit.
use crate::prng::SplitMix64;

/// A candidate answer. The derived ordering compares `dist` first, then
/// `id` (field order matters): the id breaks distance ties so that every
/// "nearest" in this file has exactly one answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Hit {
    pub dist: u64,
    pub id: u32,
}

/// Squared Euclidean distance. Squared, because sqrt is monotonic: it would
/// change no comparison and would bring floating point in.
pub fn dist2(a: &[i32], b: &[i32]) -> u64 {
    assert_eq!(a.len(), b.len());
    a.iter()
        .zip(b)
        .map(|(&x, &y)| {
            let d = i64::from(x) - i64::from(y);
            (d * d) as u64
        })
        .sum()
}

/// Offer `hit` to the sorted top-k buffer `out[..len]`; returns the new len.
/// k is small, so insertion into a sorted array beats a heap here.
pub fn topk_offer(out: &mut [Hit], len: usize, hit: Hit) -> usize {
    if len == out.len() && hit >= out[len - 1] {
        return len;
    }
    let mut i = if len < out.len() { len } else { len - 1 }; // slot that opens up
    while i > 0 && hit < out[i - 1] {
        out[i] = out[i - 1];
        i -= 1;
    }
    out[i] = hit;
    (len + 1).min(out.len())
}

/// Brute force ("flat index"): the exact answer and the yardstick for recall.
/// `data` holds n vectors of `dim` coordinates back to back.
pub fn flat_search(data: &[i32], dim: usize, query: &[i32], out: &mut [Hit]) -> usize {
    let mut len = 0;
    for (id, v) in data.chunks_exact(dim).enumerate() {
        len = topk_offer(
            out,
            len,
            Hit {
                dist: dist2(v, query),
                id: id as u32,
            },
        );
    }
    len
}

/// How many of `got` also appear in the exact answer `want`.
pub fn overlap(got: &[Hit], want: &[Hit]) -> u32 {
    got.iter()
        .filter(|g| want.iter().any(|w| w.id == g.id))
        .count() as u32
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SearchStats {
    pub lists_probed: u32,
    /// Distance computations against stored vectors (not centroids).
    pub vectors_scanned: u32,
    pub hits: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Invalid;

#[derive(Debug)]
pub struct Ivf {
    pub dim: usize,
    pub nlist: usize,
    /// nlist * dim coordinates: the "root node".
    pub centroids: Vec<i32>,
    /// List c owns positions list_offsets[c] .. list_offsets[c + 1] of `ids`
    /// and `vecs` (CSR layout: no pointer per list, no pointer per vector).
    pub list_offsets: Vec<u32>,
    pub ids: Vec<u32>,
    /// Vectors copied next to their list, so scanning a list is one
    /// sequential pass over memory, like scanning a leaf page.
    pub vecs: Vec<i32>,
    /// id -> list, kept for validate() and for explaining misses.
    pub assign: Vec<u32>,
    /// Centroid updates performed before assignments stopped changing.
    pub iterations: u32,
}

impl Ivf {
    /// Train with k-means (Lloyd's algorithm) and fill the lists.
    ///
    /// Memory: the five `Vec`s of the result live as long as the index.
    /// Everything k-means needs only while it runs (`perm`, `sums`, `counts`,
    /// `cursor`) is a local `Vec` that is dropped on return: Rust's scopes do
    /// the job of the arena in the Zig version.
    pub fn build(data: &[i32], dim: usize, nlist: usize, seed: u64, max_iter: u32) -> Ivf {
        assert!(dim > 0 && data.len().is_multiple_of(dim));
        let n = data.len() / dim;
        assert!(nlist > 0 && nlist <= n);
        let row = |i: usize| &data[i * dim..(i + 1) * dim];

        // 1. Starting centroids: nlist distinct data points, chosen by a
        //    seeded shuffle of the ids.
        let mut perm: Vec<u64> = (0..n as u64).collect();
        SplitMix64::new(seed).shuffle(&mut perm);
        let mut centroids = Vec::with_capacity(nlist * dim);
        for &src in &perm[..nlist] {
            centroids.extend_from_slice(row(src as usize));
        }

        // 2. Lloyd iterations: assign every vector to its nearest centroid,
        //    then move each centroid to the mean of its vectors. The loop
        //    always exits right after an assignment step, so on exit every
        //    vector is in the list of its nearest centroid (see validate).
        let mut sums = vec![0i64; nlist * dim];
        let mut counts = vec![0u32; nlist];
        let mut assign = vec![u32::MAX; n];
        let mut iterations = 0;
        loop {
            let mut changed = 0usize;
            for (i, slot) in assign.iter_mut().enumerate() {
                let c = nearest_centroid(&centroids, dim, row(i));
                if *slot != c {
                    changed += 1;
                }
                *slot = c;
            }
            if changed == 0 || iterations == max_iter {
                break;
            }
            sums.fill(0);
            counts.fill(0);
            for (i, &c) in assign.iter().enumerate() {
                let c = c as usize;
                counts[c] += 1;
                for (j, &x) in row(i).iter().enumerate() {
                    sums[c * dim + j] += i64::from(x);
                }
            }
            for c in 0..nlist {
                if counts[c] == 0 {
                    continue; // empty cell: leave its centroid where it is
                }
                let cnt = i64::from(counts[c]);
                // Mean rounded to the nearest integer, in integers only.
                // div_euclid by a positive number is floor division.
                for j in 0..dim {
                    centroids[c * dim + j] =
                        (2 * sums[c * dim + j] + cnt).div_euclid(2 * cnt) as i32;
                }
            }
            iterations += 1;
        }

        // 3. Counting sort of the ids by list: offsets first, then fill.
        //    Ids stay ascending inside each list.
        let mut list_offsets = vec![0u32; nlist + 1];
        for &c in &assign {
            list_offsets[c as usize + 1] += 1;
        }
        for c in 0..nlist {
            list_offsets[c + 1] += list_offsets[c];
        }
        let mut cursor = list_offsets[..nlist].to_vec();
        let mut ids = vec![0u32; n];
        let mut vecs = vec![0i32; n * dim];
        for (i, &c) in assign.iter().enumerate() {
            let pos = cursor[c as usize] as usize;
            cursor[c as usize] += 1;
            ids[pos] = i as u32;
            vecs[pos * dim..(pos + 1) * dim].copy_from_slice(row(i));
        }

        Ivf {
            dim,
            nlist,
            centroids,
            list_offsets,
            ids,
            vecs,
            assign,
            iterations,
        }
    }

    pub fn centroid(&self, c: usize) -> &[i32] {
        &self.centroids[c * self.dim..(c + 1) * self.dim]
    }

    pub fn list_len(&self, c: usize) -> u32 {
        self.list_offsets[c + 1] - self.list_offsets[c]
    }

    /// Rank all centroids by distance to `query` into `order` (cleared
    /// first). This is the routing step. Compare with a B-tree: there it is a
    /// binary search over sorted separators; here it is a scan, because
    /// centroids have no order that a query could be compared against.
    pub fn rank_lists(&self, query: &[i32], order: &mut Vec<Hit>) {
        order.clear();
        order.extend((0..self.nlist).map(|c| Hit {
            dist: dist2(self.centroid(c), query),
            id: c as u32,
        }));
        order.sort_unstable(); // (dist, id) pairs are all different
    }

    /// Approximate k nearest neighbours (k = out.len()): scan the `nprobe`
    /// lists whose centroids are nearest to the query. `scratch` is the
    /// ranking buffer; reuse one `Vec` across queries and it stops allocating
    /// after the first (the Zig version resets an arena for the same effect).
    pub fn search(
        &self,
        scratch: &mut Vec<Hit>,
        query: &[i32],
        nprobe: usize,
        out: &mut [Hit],
    ) -> SearchStats {
        self.rank_lists(query, scratch);
        let mut stats = SearchStats::default();
        for list in &scratch[..nprobe.min(self.nlist)] {
            stats.lists_probed += 1;
            let c = list.id as usize;
            for pos in self.list_offsets[c] as usize..self.list_offsets[c + 1] as usize {
                let d = dist2(&self.vecs[pos * self.dim..(pos + 1) * self.dim], query);
                stats.vectors_scanned += 1;
                stats.hits = topk_offer(
                    out,
                    stats.hits,
                    Hit {
                        dist: d,
                        id: self.ids[pos],
                    },
                );
            }
        }
        stats
    }

    /// Invariants: the lists partition the ids (each id once, ascending
    /// inside a list); each stored vector is a copy of the original; and each
    /// vector is in the list of its nearest centroid.
    pub fn validate(&self, data: &[i32]) -> Result<(), Invalid> {
        let n = self.ids.len();
        let dim = self.dim;
        if data.len() != n * dim
            || self.list_offsets[0] != 0
            || self.list_offsets[self.nlist] as usize != n
        {
            return Err(Invalid);
        }
        for c in 0..self.nlist {
            let (start, end) = (
                self.list_offsets[c] as usize,
                self.list_offsets[c + 1] as usize,
            );
            if start > end {
                return Err(Invalid);
            }
            for pos in start..end {
                let id = self.ids[pos] as usize;
                if id >= n || self.assign[id] as usize != c {
                    return Err(Invalid);
                }
                if pos > start && self.ids[pos - 1] as usize >= id {
                    return Err(Invalid);
                }
                let v = &self.vecs[pos * dim..(pos + 1) * dim];
                if v != &data[id * dim..(id + 1) * dim] {
                    return Err(Invalid);
                }
                if nearest_centroid(&self.centroids, dim, v) as usize != c {
                    return Err(Invalid);
                }
            }
        }
        // Why this proves "each id exactly once": an id can only sit in list
        // assign[id], at most once there (strictly ascending), and there are
        // exactly n positions for n possible ids.
        Ok(())
    }
}

/// Index of the centroid nearest to `v`; the lowest index wins a tie.
fn nearest_centroid(centroids: &[i32], dim: usize, v: &[i32]) -> u32 {
    centroids
        .chunks_exact(dim)
        .enumerate()
        .map(|(c, cen)| Hit {
            dist: dist2(cen, v),
            id: c as u32,
        })
        .min()
        .expect("at least one centroid")
        .id
}

#[cfg(test)]
mod tests {
    use super::*;

    fn random_data(rng: &mut SplitMix64, n: usize, dim: usize, limit: u64) -> Vec<i32> {
        (0..n * dim).map(|_| rng.below(limit) as i32).collect()
    }

    #[test]
    fn dist2_and_topk_offer() {
        assert_eq!(dist2(&[0, 0], &[3, 4]), 25);
        assert_eq!(dist2(&[-1, 5], &[1, 5]), 4);
        let mut out = [Hit { dist: 0, id: 0 }; 3];
        let mut len = 0;
        for (id, d) in [50, 10, 40, 10, 60, 5].into_iter().enumerate() {
            len = topk_offer(
                &mut out,
                len,
                Hit {
                    dist: d,
                    id: id as u32,
                },
            );
        }
        assert_eq!(len, 3);
        // Sorted by distance; the tie at 10 is broken by the smaller id.
        assert_eq!(
            out,
            [
                Hit { dist: 5, id: 5 },
                Hit { dist: 10, id: 1 },
                Hit { dist: 10, id: 3 }
            ]
        );
    }

    #[test]
    fn one_d_the_nearest_neighbour_is_the_predecessor_or_the_successor() {
        // With one dimension a sorted array answers nearest-neighbour exactly by
        // looking at two slots. This is the last dimension where that works.
        let mut rng = SplitMix64::new(1);
        let data = random_data(&mut rng, 300, 1, 10_000);
        let mut sorted = data.clone();
        sorted.sort_unstable();
        for _ in 0..200 {
            let q = rng.below(10_000) as i32;
            let mut best = [Hit { dist: 0, id: 0 }];
            flat_search(&data, 1, &[q], &mut best);
            let i = sorted.partition_point(|&x| x < q);
            let mut d = u64::MAX;
            if i < sorted.len() {
                d = d.min(dist2(&[sorted[i]], &[q]));
            }
            if i > 0 {
                d = d.min(dist2(&[sorted[i - 1]], &[q]));
            }
            assert_eq!(d, best[0].dist);
        }
    }

    #[test]
    fn model_test_probing_every_list_equals_brute_force_recall_grows_with_nprobe() {
        let mut rng = SplitMix64::new(2929);
        let mut scratch = Vec::new();
        for round in 0..12 {
            let dim = 1 + rng.below(6) as usize;
            let n = 20 + rng.below(300) as usize;
            let nlist = 1 + rng.below(12) as usize;
            // Small coordinate range on some rounds forces duplicate points,
            // equal distances and empty cells.
            let data = random_data(&mut rng, n, dim, if round % 3 == 0 { 4 } else { 500 });
            let index = Ivf::build(&data, dim, nlist, rng.next_u64(), 20);
            index.validate(&data).unwrap();

            let mut want = [Hit { dist: 0, id: 0 }; 7];
            let mut got = want;
            for _ in 0..20 {
                let query = random_data(&mut rng, 1, dim, 500);
                let want_len = flat_search(&data, dim, &query, &mut want);
                let (mut prev_overlap, mut prev_scanned) = (0, 0);
                for nprobe in 1..=nlist {
                    let stats = index.search(&mut scratch, &query, nprobe, &mut got);
                    let o = overlap(&got[..stats.hits], &want[..want_len]);
                    assert!(o >= prev_overlap); // more lists never hurt
                    assert!(stats.vectors_scanned >= prev_scanned);
                    prev_overlap = o;
                    prev_scanned = stats.vectors_scanned;
                    if nprobe == nlist {
                        // All lists probed: the index degenerates to brute force.
                        assert_eq!(stats.vectors_scanned as usize, n);
                        assert_eq!(&got[..stats.hits], &want[..want_len]);
                    }
                }
            }
        }
    }

    #[test]
    fn validate_catches_a_vector_filed_under_the_wrong_centroid() {
        let mut rng = SplitMix64::new(5);
        let data = random_data(&mut rng, 100, 2, 1000);
        let mut index = Ivf::build(&data, 2, 4, 7, 20);
        index.validate(&data).unwrap();
        // Move centroid 0 far away: its vectors are now nearer to other centroids.
        index.centroids[0] += 100_000;
        assert_eq!(index.validate(&data), Err(Invalid));
    }

    #[test]
    fn search_scratch_is_reused_without_growing() {
        // Mirror of the Zig allocation-failure test's intent: after the first
        // query the search path needs no new memory.
        let mut rng = SplitMix64::new(9);
        let data = random_data(&mut rng, 60, 2, 100);
        let index = Ivf::build(&data, 2, 5, 3, 10);
        let mut scratch = Vec::new();
        let mut out = [Hit { dist: 0, id: 0 }; 3];
        index.search(&mut scratch, &[10, 10], 2, &mut out);
        let capacity = scratch.capacity();
        for q in 0..50 {
            index.search(&mut scratch, &[q, 2 * q], 2, &mut out);
        }
        assert_eq!(scratch.capacity(), capacity);
    }
}
