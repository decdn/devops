//! Shim for molecule/source-build: exec the Python stub with the same arguments,
//! so the process (and its PID, which systemd tracks) becomes the stub.
//! `--fixture-rev` prints FIXTURE_REV instead, which the scenario's side effect
//! bumps to prove a new commit is rebuilt and reinstalled.
use std::os::unix::process::CommandExt;
use std::process::{Command, exit};

const FIXTURE_REV: &str = "1";
const STUB: &str = "/usr/local/lib/decdn-molecule/decdn-node-stub";

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
