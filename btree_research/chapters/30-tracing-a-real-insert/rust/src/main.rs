use std::io::{self, Write};

use ch30_tracing_a_real_insert::demo;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    demo::run(&mut stdout)?;
    stdout.flush()?;
    Ok(())
}
