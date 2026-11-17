//! Chapter 17 entry point: `cargo run` prints expected_output.txt.
mod demo;
#[allow(dead_code)] // the copy keeps helpers this chapter does not call
mod prng;
#[cfg(test)]
mod tests;
#[allow(dead_code)] // delete, contains and the page budget are exercised by the tests only
mod tree;

use std::io::Write;

fn main() -> std::io::Result<()> {
    let mut out = String::new();
    demo::run(&mut out);
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(out.as_bytes())?;
    stdout.flush()
}
