//! `cargo run` prints the report that the README quotes: one split decided
//! by hand under each policy, then four workloads under four policies.

use ch14_split_policies_and_fill_factor::report;

fn main() {
    print!("{}", report::write_report());
}
