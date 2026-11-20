//! Chapter 28 program: prints the fixed scenario (see scenario.rs). The
//! output must equal ../expected_output.txt byte for byte.
use std::io::{self, Write};

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    out.write_all(ch28_radix_trees_and_hash_indexes::scenario::run().as_bytes())?;
    out.flush()
}
