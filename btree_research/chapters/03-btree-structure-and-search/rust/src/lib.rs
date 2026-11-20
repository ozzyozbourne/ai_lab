//! Chapter 03: B-tree structure and search.
//!
//! ```text
//! file              content                                   needs
//! base_node.rs      the node type, NodeId, the Nodes trait    -
//! base_search.rs    lower_bound, get, in_order                base_node
//! base_validate.rs  the invariants as code                    base_node
//! base_stats.rs     shape, fill, text rendering               base_node
//! arena.rs          the typed arena: Vec<Node> + u32 ids      base_node
//! tree.rs           HandTree: build by hand, read             all of the above
//! trace.rs          explain_get: search with a narration      base_node, base_search
//! height.rs         key counts and height bounds              -
//! broken.rs         ten corrupted trees for validate          tree
//! redblack.rs       2-3-4 tree to red-black tree              base_node
//! scenario.rs       what `cargo run` prints                   everything
//! ```
//!
//! The base_* files are copies from chapter 05, which holds the complete
//! tree (with insert and delete).

pub mod arena;
pub mod base_node;
pub mod base_search;
pub mod base_stats;
pub mod base_validate;
pub mod broken;
pub mod height;
pub mod prng;
pub mod redblack;
pub mod scenario;
pub mod trace;
pub mod tree;
