use std::io::{self, Write};

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    ch21_durability_primitives::run(&mut out)?;
    out.flush()
}
