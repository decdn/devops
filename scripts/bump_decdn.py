#!/usr/bin/env python3
"""Move the decdn/decdn pin to a new release, for scripts/open-decdn-bump.sh.

    scripts/bump_decdn.py [--root <devops checkout>] <subcommand> [args]

Subcommands:
    pinned              print decdn_node_version
    compare <tag>       print how the pin relates to <tag>: same, ahead or behind
    rewrite <version> --sums-sha256 <hex> --image-digest sha256:<hex>
                        move every hand-copied pin (checklist steps 1, 3, 4 and 5 of
                        ansible/roles/decdn_node/README.md, "Bumping the decdn release")

The generated mirrors (step 2) and the vendored KEYS (step 6) are open-decdn-bump.sh's:
they come from a checkout of the tag, not from this repo. Prose that names a version
(step 7) is a reviewer's: decdn/sponsord carries version numbers too, so no rewrite
here can tell which pin a bare "0.0.2" names.

Every edit is anchored on a pattern that must match exactly once, and the result is
read back, so a reshaped file fails the command instead of reporting a bump. Files
are written as the edits go, so a failure leaves the tree part-moved: run it on a
disposable checkout (open-decdn-bump.sh uses a worktree). A digest is replaced
wherever it appears in a tracked text file (changelogs excepted): a 64-hex digest
names one artifact, so every copy of the old one is a copy of the pin.

Exit status: 0 done, 1 a bad value or a file not in the expected shape, 2 usage.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
TAG = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+)$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = r"[0-9]+\.[0-9]+\.[0-9]+"

NODE_DEFAULTS = "ansible/roles/decdn_node/defaults/main.yml"
ONRAMP_DEFAULTS = "ansible/roles/sponsord_onramp/defaults/main.yml"
ONRAMP_ENV = "compose/sponsord-onramp.env.example"
COMPOSE_ENV = "compose/.env.example"
CHART = "charts/decdn-node/Chart.yaml"
CHART_VALUES = "charts/decdn-node/values.yaml"


class ShapeError(Exception):
    """A file is not in the shape the bump expects."""


def read(root: Path, rel: str) -> str:
    try:
        return (root / rel).read_text()
    except OSError as e:
        raise ShapeError(f"{rel}: {e.strerror}") from e


def scalar(text: str, key: str, rel: str) -> str:
    """A `key: value` scalar at the start of a line, quotes and comment stripped."""
    m = re.findall(rf'^{re.escape(key)}: *"?([^"\s#]+)"?', text, re.M)
    if len(m) != 1:
        raise ShapeError(f"{rel}: {len(m)} `{key}:` lines, expected 1")
    return m[0]


def env_value(text: str, key: str, rel: str) -> str:
    m = re.findall(rf"^{re.escape(key)}=(.*)$", text, re.M)
    if len(m) != 1:
        raise ShapeError(f"{rel}: {len(m)} `{key}=` lines, expected 1")
    return m[0].strip()


def pinned(root: Path) -> str:
    return scalar(read(root, NODE_DEFAULTS), "decdn_node_version", NODE_DEFAULTS)


def compare(root: Path, tag: str) -> str:
    m = TAG.match(tag)
    if not m:
        raise ShapeError(f"{tag} is not a vX.Y.Z tag")
    current = pinned(root)
    if not VERSION.match(current):
        raise ShapeError(f"{NODE_DEFAULTS}: decdn_node_version {current!r} is not X.Y.Z")
    want = tuple(int(p) for p in m.group(1).split("."))
    have = tuple(int(p) for p in current.split("."))
    return "same" if have == want else "ahead" if have > want else "behind"


def sub_once(text: str, pattern: str, repl: str, rel: str, flags: int = re.M) -> str:
    new, n = re.subn(pattern, repl, text, flags=flags)
    if n != 1:
        raise ShapeError(f"{rel}: {n} matches for /{pattern}/, expected 1")
    return new


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True
    ).stdout.decode()
    return [f for f in out.split("\0") if f and Path(f).name != "CHANGELOG.md"]


def replace_everywhere(root: Path, old: str, new: str) -> list[str]:
    """Replace <old> with <new> in every tracked text file; return the files changed.

    A symlink is skipped (its target is tracked too), and so is a binary file (one
    with a NUL byte). Any other file that cannot be read as UTF-8 stops the bump: it
    could hold a copy of the pin.
    """
    changed = []
    for rel in tracked_files(root):
        path = root / rel
        if path.is_symlink() or not path.is_file():
            continue
        try:
            data = path.read_bytes()
        except OSError as e:
            raise ShapeError(f"{rel}: {e.strerror}") from e
        if b"\0" in data:
            continue
        try:
            text = data.decode()
        except UnicodeDecodeError as e:
            raise ShapeError(f"{rel}: not UTF-8 text") from e
        if old in text:
            path.write_text(text.replace(old, new))
            changed.append(rel)
    return changed


def rewrite(root: Path, version: str, sums: str, digest: str) -> list[str]:
    if not VERSION.match(version):
        raise ShapeError(f"{version} is not X.Y.Z")
    if not HEX64.match(sums):
        raise ShapeError(f"--sums-sha256 {sums!r} is not 64 lowercase hex")
    if not (digest.startswith("sha256:") and HEX64.match(digest[len("sha256:"):])):
        raise ShapeError(f"--image-digest {digest!r} is not sha256:<64 lowercase hex>")

    old_sums = scalar(read(root, ONRAMP_DEFAULTS), "sponsord_onramp_decdn_sums_sha256", ONRAMP_DEFAULTS)
    old_digest = env_value(read(root, COMPOSE_ENV), "DECDN_IMAGE_DIGEST", COMPOSE_ENV)
    for name, old in (("sponsord_onramp_decdn_sums_sha256", old_sums), ("DECDN_IMAGE_DIGEST", old_digest)):
        bare = old.removeprefix("sha256:")
        if not HEX64.match(bare):
            raise ShapeError(f"the current {name} {old!r} is not a digest")

    changed: set[str] = set()
    if old_sums != sums:
        changed.update(replace_everywhere(root, old_sums, sums))
    if old_digest != digest:
        changed.update(replace_everywhere(root, old_digest.removeprefix("sha256:"), digest.removeprefix("sha256:")))

    # (file, pattern, replacement): the version-bearing lines.
    edits = [
        (NODE_DEFAULTS, r'^(decdn_node_version: *")[^"]*(")', rf"\g<1>{version}\g<2>"),
        (ONRAMP_DEFAULTS, rf"^(sponsord_onramp_decdn_release: *)v{SEMVER}", rf"\g<1>v{version}"),
        (ONRAMP_DEFAULTS, rf"(Default: decdn/decdn )v{SEMVER}(\.)", rf"\g<1>v{version}\g<2>"),
        (ONRAMP_ENV, rf"^ONRAMP_DECDN_RELEASE=v{SEMVER}$", f"ONRAMP_DECDN_RELEASE=v{version}"),
        (ONRAMP_ENV, rf"(defaults to: decdn/decdn )v{SEMVER}(\.)", rf"\g<1>v{version}\g<2>"),
        (COMPOSE_ENV, rf"^# decdn/decdn v{SEMVER}(\nDECDN_IMAGE_DIGEST=)", rf"# decdn/decdn v{version}\g<1>"),
        (CHART_VALUES, rf"(e\.g\. for )v{SEMVER}(\n *# *sha256:)", rf"\g<1>v{version}\g<2>"),
        (CHART, r'^(appVersion: *")[^"]*(")', rf"\g<1>{version}\g<2>"),
        (CHART, rf"(image: ghcr\.io/decdn/decdn-node:){SEMVER}$", rf"\g<1>{version}"),
    ]
    for rel, pattern, repl in edits:
        text = read(root, rel)
        new = sub_once(text, pattern, repl, rel)
        if new != text:
            (root / rel).write_text(new)
            changed.add(rel)

    verify(root, version, sums, digest)
    return sorted(changed)


def verify(root: Path, version: str, sums: str, digest: str) -> None:
    """Read every pin back; a mismatch is a file this script does not understand."""
    onramp = read(root, ONRAMP_DEFAULTS)
    onramp_env = read(root, ONRAMP_ENV)
    chart = read(root, CHART)
    want = [
        (NODE_DEFAULTS, "decdn_node_version", pinned(root), version),
        (ONRAMP_DEFAULTS, "sponsord_onramp_decdn_release",
         scalar(onramp, "sponsord_onramp_decdn_release", ONRAMP_DEFAULTS), f"v{version}"),
        (ONRAMP_DEFAULTS, "sponsord_onramp_decdn_sums_sha256",
         scalar(onramp, "sponsord_onramp_decdn_sums_sha256", ONRAMP_DEFAULTS), sums),
        (ONRAMP_ENV, "ONRAMP_DECDN_RELEASE", env_value(onramp_env, "ONRAMP_DECDN_RELEASE", ONRAMP_ENV), f"v{version}"),
        (ONRAMP_ENV, "ONRAMP_DECDN_SUMS_SHA256",
         env_value(onramp_env, "ONRAMP_DECDN_SUMS_SHA256", ONRAMP_ENV), sums),
        (COMPOSE_ENV, "DECDN_IMAGE_DIGEST", env_value(read(root, COMPOSE_ENV), "DECDN_IMAGE_DIGEST", COMPOSE_ENV), digest),
        (CHART, "appVersion", scalar(chart, "appVersion", CHART), version),
    ]
    for rel, key, got, expected in want:
        if got != expected:
            raise ShapeError(f"{rel}: {key} is {got!r} after the rewrite, expected {expected!r}")
    images = re.findall(r"image: ghcr\.io/decdn/decdn-node:(\S+)", chart)
    if images != [version]:
        raise ShapeError(f"{CHART}: artifacthub.io/images names {images}, expected [{version!r}]")
    example = re.findall(rf"e\.g\. for v{re.escape(version)}\n *# *(sha256:[0-9a-f]{{64}})", read(root, CHART_VALUES))
    if example != [digest]:
        raise ShapeError(f"{CHART_VALUES}: the example digest for v{version} is {example}, expected [{digest!r}]")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=Path.cwd(), help="devops checkout (default: the current directory)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("pinned")
    sub.add_parser("compare").add_argument("tag")
    rw = sub.add_parser("rewrite")
    rw.add_argument("version")
    rw.add_argument("--sums-sha256", required=True)
    rw.add_argument("--image-digest", required=True)
    args = ap.parse_args()

    try:
        if args.cmd == "pinned":
            print(pinned(args.root))
        elif args.cmd == "compare":
            print(compare(args.root, args.tag))
        elif args.cmd == "rewrite":
            for rel in rewrite(args.root, args.version, args.sums_sha256, args.image_digest):
                print(f"wrote {rel}")
    except ShapeError as e:
        print(f"bump_decdn: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
