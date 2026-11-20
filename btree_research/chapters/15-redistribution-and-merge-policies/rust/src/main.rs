//! Chapter 15: redistribution and merge policies. `cargo run` prints the
//! report that is stored in ../expected_output.txt.
mod experiments;
#[cfg(test)]
mod ops;
mod pages;
#[allow(dead_code)] // the copy keeps functions this chapter does not call
mod prng;

use std::io::Write;

fn main() -> std::io::Result<()> {
    let mut report = String::new();
    experiments::write_report(&mut report);
    std::io::stdout().lock().write_all(report.as_bytes())
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_report_is_exactly_expected_output_txt() {
        let mut report = String::new();
        crate::experiments::write_report(&mut report);
        assert_eq!(report, include_str!("../../expected_output.txt"));
    }
}
