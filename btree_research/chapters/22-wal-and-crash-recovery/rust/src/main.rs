use std::io::{self, Write};

use ch22_wal_and_crash_recovery::demo;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    demo::run(&mut stdout)?;
    stdout.flush()?;
    Ok(())
}
