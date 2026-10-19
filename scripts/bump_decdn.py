#!/usr/bin/env python3
"""Move the decdn/decdn pins to a new release, for scripts/open-decdn-bump.sh.

    scripts/bump_decdn.py [--root <devops checkout>] <subcommand> [args]

Subcommands:
    pinned              print decdn_node_version (the release line, X.Y)
    synced              print the release the exact copies name (X.Y.Z)
    compare <tag>       print how the synced release relates to <tag>: same, ahead
                        or behind
    kind <tag>          print patch (<tag> is in the pinned line) or line (a new one)
    rewrite <version> --sums-sha256 <hex> --image-digest sha256:<hex>
                        move every hand-copied pin (checklist steps 1, 3, 4, 5 and 7 of
                        ansible/roles/decdn_node/README.md, "Bumping the decdn release")

The roles and the chart pin a release line (decdn_node_version "0.1"): the roles
install its newest release, and the chart's default tag is the line's floating
image tag. Those copies, and AGENTS.md's "Pinned upstream releases", move only when
<version> starts a new line. What cannot resolve a line names one release, and moves
on every bump: Compose's image digest and the onramp's installer pin in its env
example, the chart's example digest, and the commented exact-pin examples in the
inventory templates and the cloud-init publisher template.

The generated mirrors (step 2) and the vendored KEYS (step 6) are open-decdn-bump.sh's:
they come from a checkout of the tag, not from this repo. Of the text that names the
version, only what is keyed to a pin moves: the comments beside the pinned values,
the commented examples, keyed by a variable name, and AGENTS.md. Docs name the pin,
never its number, so no rewrite here has to tell which pin a bare "0.0.2" names.
One decdn/decdn release ships sponsord and its onramp with the node, so the sponsord
roles' lines (sponsord_version, sponsord_onramp_version), their commented examples
and Compose's two sponsord image digests move here too.

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
LINE = re.compile(r"^[0-9]+\.[0-9]+$")
TAG = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+)$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SEMVER = r"[0-9]+\.[0-9]+\.[0-9]+"
LINE_RE = r"[0-9]+\.[0-9]+"

NODE_DEFAULTS = "ansible/roles/decdn_node/defaults/main.yml"
SPONSORD_DEFAULTS = "ansible/roles/sponsord/defaults/main.yml"
ONRAMP_DEFAULTS = "ansible/roles/sponsord_onramp/defaults/main.yml"
ONRAMP_ENV = "compose/sponsord-onramp.env.example"
COMPOSE_ENV = "compose/.env.example"
CHART = "charts/decdn-node/Chart.yaml"
CHART_VALUES = "charts/decdn-node/values.yaml"

# (file, before, after): an exact-pin example, the regex fragments on either side of
# the bare X.Y.Z. examples/collection-fleet/inventory/'s host_vars and group_vars are
# byte copies of ansible/inventory/'s (make test-scripts), so both trees move.
EXAMPLES = [
    *(
        (f"{tree}/host_vars/{host}/main.yml", before, after)
        for tree in ("ansible/inventory", "examples/collection-fleet/inventory")
        for host in ("decdn-node-1", "origin-1")
        for before, after in ((r'^# decdn_node_version: *"', '"'), (r"^# +decdn_node_source_ref: *v", "$"))
    ),
    *(
        (f"{tree}/group_vars/sponsord_hosts.yml", before, after)
        for tree in ("ansible/inventory", "examples/collection-fleet/inventory")
        for before, after in ((r'^# sponsord_version: *"', '"'), (r"^# sponsord_source_ref: *v", "$"))
    ),
    *(
        (f"{tree}/group_vars/sponsord_onramp_hosts.yml", before, after)
        for tree in ("ansible/inventory", "examples/collection-fleet/inventory")
        for before, after in (
            (r'^# sponsord_onramp_version: *"', '"'),
            (r"^# sponsord_onramp_source_ref: *v", "$"),
            (r"^# sponsord_onramp_decdn_release: *v", "$"),
        )
    ),
    ("cloud-init/user-data-publisher.yaml", r'^ *# sponsord_onramp_decdn_release: *"v', '"'),
]
# The one place prose names the pinned line (its line may wrap inside the phrase): the
# three role pins in one parenthesis, the number after the last.
AGENTS = ("AGENTS.md", r"`sponsord_onramp_version`, today\s+`", "`")
# Compose's image digests: the env key and the flag that carries the new one (each
# from the release's <stage>-image-digest.txt, which open-decdn-bump.sh verifies).
IMAGE_DIGESTS = (
    ("DECDN_IMAGE_DIGEST", "--image-digest"),
    ("SPONSORD_IMAGE_DIGEST", "--sponsord-image-digest"),
    ("SPONSORD_ONRAMP_IMAGE_DIGEST", "--onramp-image-digest"),
)


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
    """decdn_node_version, which must be a release line."""
    current = scalar(read(root, NODE_DEFAULTS), "decdn_node_version", NODE_DEFAULTS)
    if not LINE.match(current):
        raise ShapeError(f"{NODE_DEFAULTS}: decdn_node_version {current!r} is not a release line (X.Y)")
    return current


# The sponsord roles' pins, which the same release ships: (file, variable).
LINE_PINS = (
    (NODE_DEFAULTS, "decdn_node_version"),
    (SPONSORD_DEFAULTS, "sponsord_version"),
    (ONRAMP_DEFAULTS, "sponsord_onramp_version"),
)


def synced(root: Path) -> str:
    """The release the exact copies name: the one Compose's image digest is of."""
    m = re.findall(rf"^# decdn/decdn v({SEMVER})\nDECDN_IMAGE_DIGEST=", read(root, COMPOSE_ENV), re.M)
    if len(m) != 1:
        raise ShapeError(f"{COMPOSE_ENV}: {len(m)} `# decdn/decdn vX.Y.Z` lines above DECDN_IMAGE_DIGEST, expected 1")
    return m[0]


def tag_version(tag: str) -> str:
    m = TAG.match(tag)
    if not m:
        raise ShapeError(f"{tag} is not a vX.Y.Z tag")
    return m.group(1)


def compare(root: Path, tag: str) -> str:
    want = tuple(int(p) for p in tag_version(tag).split("."))
    have = tuple(int(p) for p in synced(root).split("."))
    return "same" if have == want else "ahead" if have > want else "behind"


def line_of(version: str) -> str:
    return version.rsplit(".", 1)[0]


def kind(root: Path, tag: str) -> str:
    return "patch" if line_of(tag_version(tag)) == pinned(root) else "line"


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


def rewrite(root: Path, version: str, sums: str, digests: dict[str, str]) -> list[str]:
    """Move every pin to <version>; <digests> maps each IMAGE_DIGESTS env key to its new value."""
    if not VERSION.match(version):
        raise ShapeError(f"{version} is not X.Y.Z")
    if not HEX64.match(sums):
        raise ShapeError(f"--sums-sha256 {sums!r} is not 64 lowercase hex")
    if set(digests) != {key for key, _ in IMAGE_DIGESTS}:
        raise ShapeError(f"digests given for {sorted(digests)}, expected {[key for key, _ in IMAGE_DIGESTS]}")
    for key, flag in IMAGE_DIGESTS:
        digest = digests[key]
        if not (digest.startswith("sha256:") and HEX64.match(digest[len("sha256:"):])):
            raise ShapeError(f"{flag} {digest!r} is not sha256:<64 lowercase hex>")
    line = line_of(version)
    pinned(root)  # a line, or the shape is not one this script moves

    compose_env = read(root, COMPOSE_ENV)
    old_sums = env_value(read(root, ONRAMP_ENV), "ONRAMP_DECDN_SUMS_SHA256", ONRAMP_ENV)
    old_digests = {key: env_value(compose_env, key, COMPOSE_ENV) for key, _ in IMAGE_DIGESTS}
    for name, old in (("ONRAMP_DECDN_SUMS_SHA256", old_sums), *old_digests.items()):
        bare = old.removeprefix("sha256:")
        if not HEX64.match(bare):
            raise ShapeError(f"the current {name} {old!r} is not a digest")
    # Three distinct images: a digest shared between two env keys would be replaced
    # twice, so a copy of the pin could end up as the wrong image.
    if len(set(old_digests.values())) != len(old_digests):
        raise ShapeError(f"{COMPOSE_ENV}: two image digests are equal")

    changed: set[str] = set()
    if old_sums != sums:
        changed.update(replace_everywhere(root, old_sums, sums))
    for key, _ in IMAGE_DIGESTS:
        if old_digests[key] != digests[key]:
            changed.update(replace_everywhere(
                root, old_digests[key].removeprefix("sha256:"), digests[key].removeprefix("sha256:")))

    # (file, pattern, replacement): the version-bearing lines. The line copies first.
    agents_file, agents_before, agents_after = AGENTS
    edits = [
        *((rel, rf'^({var}: *")[^"]*(")', rf"\g<1>{line}\g<2>") for rel, var in LINE_PINS),
        (ONRAMP_DEFAULTS, rf"^(sponsord_onramp_decdn_release: *)v{LINE_RE}( )", rf"\g<1>v{line}\g<2>"),
        (CHART, r'^(appVersion: *")[^"]*(")', rf"\g<1>{line}\g<2>"),
        (CHART, rf"(image: ghcr\.io/decdn/decdn-node:){LINE_RE}$", rf"\g<1>{line}"),
        (agents_file, rf"({agents_before}){LINE_RE}({agents_after})", rf"\g<1>{line}\g<2>"),
        (ONRAMP_ENV, rf"^ONRAMP_DECDN_RELEASE=v{SEMVER}$", f"ONRAMP_DECDN_RELEASE=v{version}"),
        (ONRAMP_ENV, rf"(last moved:\n# decdn/decdn )v{SEMVER}(\.)", rf"\g<1>v{version}\g<2>"),
        (COMPOSE_ENV, rf"^# decdn/decdn v{SEMVER}(\nDECDN_IMAGE_DIGEST=)", rf"# decdn/decdn v{version}\g<1>"),
        (CHART_VALUES, rf"(e\.g\. for )v{SEMVER}(\n *# *sha256:)", rf"\g<1>v{version}\g<2>"),
        *((rel, rf"({before}){SEMVER}({after})", rf"\g<1>{version}\g<2>") for rel, before, after in EXAMPLES),
    ]
    for rel, pattern, repl in edits:
        text = read(root, rel)
        new = sub_once(text, pattern, repl, rel)
        if new != text:
            (root / rel).write_text(new)
            changed.add(rel)

    verify(root, version, sums, digests)
    return sorted(changed)


def verify(root: Path, version: str, sums: str, digests: dict[str, str]) -> None:
    """Read every pin back; a mismatch is a file this script does not understand."""
    line = line_of(version)
    onramp = read(root, ONRAMP_DEFAULTS)
    onramp_env = read(root, ONRAMP_ENV)
    compose_env = read(root, COMPOSE_ENV)
    chart = read(root, CHART)
    want = [
        (NODE_DEFAULTS, "decdn_node_version", pinned(root), line),
        *((rel, var, scalar(read(root, rel), var, rel), line) for rel, var in LINE_PINS[1:]),
        (ONRAMP_DEFAULTS, "sponsord_onramp_decdn_release",
         scalar(onramp, "sponsord_onramp_decdn_release", ONRAMP_DEFAULTS), f"v{line}"),
        (ONRAMP_ENV, "ONRAMP_DECDN_RELEASE", env_value(onramp_env, "ONRAMP_DECDN_RELEASE", ONRAMP_ENV), f"v{version}"),
        (ONRAMP_ENV, "ONRAMP_DECDN_SUMS_SHA256",
         env_value(onramp_env, "ONRAMP_DECDN_SUMS_SHA256", ONRAMP_ENV), sums),
        *((COMPOSE_ENV, key, env_value(compose_env, key, COMPOSE_ENV), digests[key]) for key, _ in IMAGE_DIGESTS),
        (COMPOSE_ENV, "the release above DECDN_IMAGE_DIGEST", synced(root), version),
        (CHART, "appVersion", scalar(chart, "appVersion", CHART), line),
    ]
    for rel, key, got, expected in want:
        if got != expected:
            raise ShapeError(f"{rel}: {key} is {got!r} after the rewrite, expected {expected!r}")
    # A line takes no digest: the role reads it from the release it resolves to.
    if re.search(r'^sponsord_onramp_decdn_sums_sha256: *"" ', onramp, re.M) is None:
        raise ShapeError(f"{ONRAMP_DEFAULTS}: sponsord_onramp_decdn_sums_sha256 is not \"\" beside a release line")
    images = re.findall(r"image: ghcr\.io/decdn/decdn-node:(\S+)", chart)
    if images != [line]:
        raise ShapeError(f"{CHART}: artifacthub.io/images names {images}, expected [{line!r}]")
    example = re.findall(rf"e\.g\. for v{re.escape(version)}\n *# *(sha256:[0-9a-f]{{64}})", read(root, CHART_VALUES))
    if example != [digests["DECDN_IMAGE_DIGEST"]]:
        raise ShapeError(f"{CHART_VALUES}: the example digest for v{version} is {example}, "
                         f"expected [{digests['DECDN_IMAGE_DIGEST']!r}]")
    for rel, before, after in EXAMPLES:
        found = re.findall(rf"{before}({SEMVER}){after}", read(root, rel), re.M)
        if found != [version]:
            raise ShapeError(f"{rel}: /{before}X.Y.Z{after}/ names {found}, expected [{version!r}]")
    rel, before, after = AGENTS
    found = re.findall(rf"{before}({LINE_RE}){after}", read(root, rel))
    if found != [line]:
        raise ShapeError(f"{rel}: /{before}X.Y{after}/ names {found}, expected [{line!r}]")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=Path.cwd(), help="devops checkout (default: the current directory)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("pinned")
    sub.add_parser("synced")
    sub.add_parser("compare").add_argument("tag")
    sub.add_parser("kind").add_argument("tag")
    rw = sub.add_parser("rewrite")
    rw.add_argument("version")
    rw.add_argument("--sums-sha256", required=True)
    for key, flag in IMAGE_DIGESTS:
        rw.add_argument(flag, required=True, dest=key, metavar="sha256:HEX", help=f"the release's {key}")
    args = ap.parse_args()

    try:
        if args.cmd == "pinned":
            print(pinned(args.root))
        elif args.cmd == "synced":
            print(synced(args.root))
        elif args.cmd == "compare":
            print(compare(args.root, args.tag))
        elif args.cmd == "kind":
            print(kind(args.root, args.tag))
        elif args.cmd == "rewrite":
            digests = {key: getattr(args, key) for key, _ in IMAGE_DIGESTS}
            for rel in rewrite(args.root, args.version, args.sums_sha256, digests):
                print(f"wrote {rel}")
    except ShapeError as e:
        print(f"bump_decdn: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
