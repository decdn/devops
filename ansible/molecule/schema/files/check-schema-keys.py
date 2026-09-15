#!/usr/bin/env python3
"""Flag any config PATH in a rendered node.toml that upstream rejects.

    check-schema-keys.py [<node.toml>] [<schema-keys.txt>]

Defaults: /etc/decdn/node.toml, and schema-keys.txt next to this file.

Shared by both deploy paths: the Ansible `schema` molecule scenario runs it on the
role's render, and `make lint-helm` runs it on the Helm chart's renders. One key
inventory guards both.
"""
import os
import sys
import tomllib

config_path = sys.argv[1] if len(sys.argv) > 1 else "/etc/decdn/node.toml"
keys_path = (
    sys.argv[2] if len(sys.argv) > 2
    else os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema-keys.txt")
)
with open(config_path, "rb") as fh:
    config = tomllib.load(fh)
with open(keys_path, encoding="utf-8") as fh:
    known = {
        line.strip() for line in fh
        if line.strip() and not line.startswith("#")
    }


def _lookup(root, dotted):
    """Resolve a dotted path back to its value, for leaf/table triage."""
    node = root
    for part in dotted.split("."):
        if isinstance(node, list):
            node = node[0] if node else {}
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def walk(node, path=""):
    """Yield the dotted path of every key in every table."""
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else key
            yield here
            yield from walk(value, here)
    elif isinstance(node, list):
        # [[cache.origins]] is an array of tables. Every element shares one
        # schema, so they collapse onto the same path -- an index would make
        # the inventory depend on how many origins an operator configured.
        for item in node:
            if isinstance(item, dict):
                yield from walk(item, path)


def normalize(dotted):
    """Collapse the one path hop that is data rather than a schema field.

    [network.discovery.peers.<NodeId>] is keyed by a 64-char NodeId, so the
    hop itself is never in the inventory; the DiscoveryPeer fields BELOW it
    are (as network.discovery.peers.*). Only that single hop is rewritten,
    so a bogus key beside relay_url/addrs is still caught.
    """
    prefix = "network.discovery.peers."
    if dotted.startswith(prefix):
        rest = dotted[len(prefix):].split(".", 1)
        return prefix + "*" + ("." + rest[1] if len(rest) > 1 else "")
    return dotted


def is_table(value):
    """A table or an array of tables: a section, not a field.

    Arrays of SCALARS (relay_urls, pinned_hashes, ...) and empty arrays are
    fields like any other and must be checked -- treating every list as a table
    once let a misspelled list key through.
    """
    if isinstance(value, dict):
        return True
    return isinstance(value, list) and bool(value) and all(isinstance(i, dict) for i in value)


emitted = list(walk(config))
if not emitted:
    print(f"{config_path} is empty: nothing to check, which proves nothing",
          file=sys.stderr)
    sys.exit(1)

# A table header is itself a path (`cache.tinylfu`), and intermediate tables
# are not fields of anything -- they are the sections the inventory is keyed
# BY. Only leaf paths are checked; a bogus TABLE surfaces as its children
# being unknown, or (if empty) as the section-set assertion in the caller.
unknown = sorted({
    normalize(dotted) for dotted in emitted
    if not is_table(_lookup(config, dotted))
    and normalize(dotted) not in known
})
# An empty table has no leaves, so it would otherwise pass unseen.
unknown += sorted({
    normalize(dotted) for dotted in emitted
    if _lookup(config, dotted) == {} and normalize(dotted) not in known
    and not any(k.startswith(normalize(dotted) + ".") for k in known)
})

if unknown:
    print(f"{config_path} emits paths absent from the upstream config schema:",
          file=sys.stderr)
    for path in unknown:
        print(f"  {path}", file=sys.stderr)
    print(
        "\nEvery config section upstream is deny_unknown_fields with no "
        "serde aliases, so each of these is a daemon startup failure. Note "
        "a path can be wrong because the KEY is unknown or because a known "
        "key landed in the wrong TABLE -- a scalar [cache] key emitted below "
        "a [cache.*] header nests into it silently. Re-sync the renderer "
        "(ansible/roles/decdn_node/templates/node.toml.j2 or charts/decdn-node), then "
        "regenerate ansible/molecule/schema/files/schema-keys.txt (see gen-schema-keys.py).",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"schema OK ({config_path}): {len(known)} known paths, "
      f"{len(emitted)} emitted, all recognised")
