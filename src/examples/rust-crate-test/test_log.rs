// Test using log from crates.io
use log::{info, Level};

fn main() {
    // Simple usage - just check it compiles
    if log::max_level() >= log::LevelFilter::Info {
        println!("Log crate works!");
    } else {
        println!("Log crate loaded (no logger set)");
    }
}
