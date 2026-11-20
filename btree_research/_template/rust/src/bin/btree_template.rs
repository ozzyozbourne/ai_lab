use std::io::{self, Write};

use btree_template::{Arena, lower_bound};

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // Buffered, locked stdout; flushed on drop of the BufWriter, or explicitly.
    let mut out = io::BufWriter::new(io::stdout().lock());
    writeln!(out, "btree_template: {} arg(s)", args.len())?;

    let mut arena: Arena<Vec<u32>> = Arena::new();
    let leaf = arena.alloc(vec![10, 20, 30]);
    writeln!(out, "leaf {leaf:?} keys = {:?}", arena[leaf])?;
    writeln!(out, "lower_bound(25) = {}", lower_bound(&arena[leaf], &25))?;
    out.flush()?;

    eprintln!("(stderr) done");
    Ok(())
}
