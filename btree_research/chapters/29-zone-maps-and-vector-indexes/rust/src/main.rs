//! `cargo run`: print the chapter's fixed scenario (see lib.rs).
use std::io::{self, Write};

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    out.write_all(ch29_zone_maps_and_vector_indexes::run_scenario().as_bytes())?;
    out.flush()
}
