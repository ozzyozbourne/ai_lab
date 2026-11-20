//! Prints the fixed scenario of chapter 16 (see lib.rs for the map of files).

fn main() {
    let mut out = String::new();
    ch16_bulk_loading::report::write(&mut out).expect("the scenario has no node budget");
    print!("{out}");
}
