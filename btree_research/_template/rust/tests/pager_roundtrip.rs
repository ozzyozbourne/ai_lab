//! Integration test: only the public API is visible here.

use std::collections::BTreeMap;
use std::path::PathBuf;

use btree_template::rng::SplitMix64;
use btree_template::{PAGE_SIZE, Page, Pager, lower_bound};

/// Unique temp dir without external crates; removed on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn new(name: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("btree_template-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp dir");
        Self(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn pager_round_trip() -> std::io::Result<()> {
    let tmp = TempDir::new("pager");
    let path = tmp.0.join("test.db");

    {
        let mut pager = Pager::open(&path)?;
        assert_eq!(pager.page_count(), 0);
        let mut page: Page = [0; PAGE_SIZE];
        page[..5].copy_from_slice(b"hello");
        pager.write_page(3, &page)?; // sparse: pages 0..3 read back as zeroes
        pager.sync()?;
        assert_eq!(pager.alloc_page()?, 4);
    }

    let pager = Pager::open(&path)?;
    assert_eq!(pager.page_count(), 5);
    let mut page: Page = [0xFF; PAGE_SIZE];
    pager.read_page(3, &mut page)?;
    assert_eq!(&page[..5], b"hello");
    pager.read_page(0, &mut page)?;
    assert!(page.iter().all(|&b| b == 0));
    let err = pager.read_page(99, &mut page).unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::UnexpectedEof);

    std::fs::remove_file(&path)?;
    Ok(())
}

/// Differential fuzz test: sorted `Vec` (stand-in for the tree) vs `BTreeMap` as the model.
#[test]
fn fuzz_against_model() {
    let mut rng = SplitMix64::new(0xB7EE);
    let mut sorted: Vec<(u32, u32)> = Vec::new();
    let mut model: BTreeMap<u32, u32> = BTreeMap::new();

    for step in 0..5_000u32 {
        let key = rng.below(500) as u32;
        let keys: Vec<u32> = sorted.iter().map(|&(k, _)| k).collect();
        let i = lower_bound(&keys, &key);
        let present = sorted.get(i).is_some_and(|&(k, _)| k == key);
        assert_eq!(present, model.contains_key(&key), "step {step}, key {key}");

        if rng.below(3) != 0 {
            if present {
                sorted[i].1 = step;
            } else {
                sorted.insert(i, (key, step));
            }
            model.insert(key, step);
        } else {
            if present {
                sorted.remove(i);
            }
            model.remove(&key);
        }
    }
    assert!(
        sorted
            .iter()
            .copied()
            .eq(model.iter().map(|(&k, &v)| (k, v)))
    );
}
