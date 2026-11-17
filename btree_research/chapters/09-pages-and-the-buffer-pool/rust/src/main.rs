use std::io::{self, Write};
use std::path::Path;

use ch09_pages_and_the_buffer_pool::demo;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    // The demo database is created in the current directory and deleted again.
    demo::run(&mut stdout, Path::new("."))?;
    stdout.flush()?;
    Ok(())
}
