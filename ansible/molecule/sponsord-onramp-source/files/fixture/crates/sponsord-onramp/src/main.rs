//! Shim for molecule/sponsord-onramp-source: exec the Python stub
//! with the same arguments, so the process systemd tracks becomes the stub.
//! `--fixture-rev` prints FIXTURE_REV instead; `--version` as root is refused.
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::process::{Command, exit};

const FIXTURE_REV: &str = "1";
const STUB: &str = "/usr/local/lib/decdn-molecule/sponsord-onramp-stub";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--fixture-rev") {
        println!("{FIXTURE_REV}");
        return;
    }
    // The roles must never run a source-built binary as root, not even for the
    // --version check: refuse, so a root run fails the scenario.
    if args.first().map(String::as_str) == Some("--version") && running_as_root() {
        eprintln!("refusing --version as root");
        exit(1);
    }
    let err = Command::new(STUB).args(&args).exec();
    eprintln!("exec {STUB}: {err}");
    exit(127);
}

/// /proc/self belongs to the process's effective uid.
fn running_as_root() -> bool {
    std::fs::metadata("/proc/self").map(|m| m.uid() == 0).unwrap_or(true)
}
