use std::io::{self, Write};
use std::path::Path;

use ch13_overflow_and_free_space::demo;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    // The demo database is created in the current directory and deleted again.
    demo::run(&mut stdout, Path::new("."))?;
    stdout.flush()?;
    Ok(())
}
