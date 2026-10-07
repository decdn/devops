#!/usr/bin/env python3
"""Install one cargo build output as root without trusting the build user's tree.

usage: install-build-output.py <build-home> <path-under-home> <dest> <build-uid>

The build tree belongs to the unprivileged build user, and the build ran code
(dependency build scripts) as that user, so any component of the path may have
been swapped for a symlink to a root-only file or directory. A root `cp`/`copy`
would follow it. Instead, walk the path with openat(O_NOFOLLOW) from the build
home, whose parent is root-owned, refuse anything that is not a regular file
owned by the build user (which also rules out a hard link to a root file), then
copy from that open descriptor, not the path, to a temp file beside <dest> and
rename it into place (root:root 0755). There is no window between the check and
the read for a still-running build-user process to race.

Prints "changed" or "unchanged"; any refusal exits 1 with the reason on stderr.
"""
import hashlib
import os
import stat
import sys
import tempfile

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK


def refuse(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def open_output(home, rel):
    parts = rel.split("/")
    if any(p in ("", ".", "..") for p in parts):
        refuse(f"{rel}: not a plain relative path")
    try:
        fd = os.open(home, DIR_FLAGS)
    except OSError as e:
        refuse(f"{home}: {e.strerror} (a symlink is refused)")
    try:
        for part in parts[:-1]:
            nfd = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nfd
        return os.open(parts[-1], FILE_FLAGS, dir_fd=fd)
    except OSError as e:
        refuse(f"{home}/{rel}: {e.strerror} (a symlink anywhere on the path is refused)")
    finally:
        os.close(fd)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 5:
        refuse("usage: install-build-output.py <build-home> <path-under-home> <dest> <build-uid>")
    home, rel, dest, uid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

    src = open_output(home, rel)
    st = os.fstat(src)
    if not stat.S_ISREG(st.st_mode):
        refuse(f"{home}/{rel}: not a regular file")
    if st.st_uid != uid:
        refuse(f"{home}/{rel}: owned by uid {st.st_uid}, not the build user ({uid})")

    tmp = tempfile.NamedTemporaryFile(
        dir=os.path.dirname(dest), prefix="." + os.path.basename(dest) + ".", delete=False
    )
    try:
        h = hashlib.sha256()
        with os.fdopen(src, "rb") as f, tmp:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
                tmp.write(chunk)
            tmp.flush()
            os.fsync(tmp.fileno())
        try:
            cur = os.stat(dest, follow_symlinks=False)
            same = (
                stat.S_ISREG(cur.st_mode)
                and stat.S_IMODE(cur.st_mode) == 0o755
                and cur.st_uid == 0
                and cur.st_gid == 0
                and sha256_of(dest) == h.hexdigest()
            )
        except FileNotFoundError:
            same = False
        if same:
            os.unlink(tmp.name)
            print("unchanged")
            return
        os.chown(tmp.name, 0, 0)
        os.chmod(tmp.name, 0o755)
        os.rename(tmp.name, dest)
        print("changed")
    except BaseException:
        if os.path.exists(tmp.name):
            os.unlink(tmp.name)
        raise


if __name__ == "__main__":
    main()
