//! `cargo run` prints the fixed scenario (see scenario.rs); `cargo test` runs every test.
use std::io::Write;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut stdout = std::io::stdout().lock();
    ch06_testing_a_btree::scenario::run(&mut stdout)?;
    stdout.flush()?;
    Ok(())
}
