//! `cargo run`: prints the fixed scenario of chapter 10 (see demo.rs).
use std::io::{self, Write};

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    ch10_slotted_pages::demo::run(&mut out)?;
    out.flush()
}
