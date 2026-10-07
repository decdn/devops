//! A hostile build script, as a dependency's could be: it tries to leave files
//! outside the build's work directory and a process that outlives the build.
//! molecule/source-build/verify.yml checks that none of it reached the host.
use std::fs;
use std::process::Command;

fn main() {
    for path in [
        "/tmp/decdn-build-escape",
        "/var/tmp/decdn-build-escape",
        "/dev/shm/decdn-build-escape",
        "/var/lib/decdn-build/escape",
    ] {
        let _ = fs::write(path, b"escaped");
    }
    let _ = Command::new("sh").args(["-c", "sleep 600 >/dev/null 2>&1 &"]).spawn();
}
