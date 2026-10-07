//! Shim for the sponsord-onramp scenario's source phase: exec the Python stub
//! with the same arguments, so the process systemd tracks becomes the stub.
//! `--fixture-rev` prints FIXTURE_REV instead.
use std::os::unix::process::CommandExt;
use std::process::{Command, exit};

const FIXTURE_REV: &str = "1";
const STUB: &str = "/usr/local/lib/decdn-molecule/sponsord-stub";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--fixture-rev") {
        println!("{FIXTURE_REV}");
        return;
    }
    let err = Command::new(STUB).args(&args).exec();
    eprintln!("exec {STUB}: {err}");
    exit(127);
}
