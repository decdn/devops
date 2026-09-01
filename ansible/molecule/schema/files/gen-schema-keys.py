#!/usr/bin/env python3
"""Regenerate schema-keys.txt: every FULLY-QUALIFIED config path upstream accepts.

Run from anywhere:

    ./gen-schema-keys.py ../../../../../decdn > schema-keys.txt

Fully-qualified, not bare leaf names. An earlier version of this inventory listed
only leaf names, which let a key sitting in the WRONG table pass -- including the
exact hazard node.toml.j2's header warns about, where a scalar [cache] key emitted
below a [cache.*] sub-table header silently nests into that sub-table. `sketch_bytes`
is legal at cache.tinylfu.sketch_bytes and a startup failure at cache.sketch_bytes,
so the path is the thing that has to be checked.

Field names are parsed out of the upstream sources; the struct -> TOML path mapping
below is the one thing that cannot be derived from them, because it is expressed in
the *shape* of FileConfig rather than in any struct's own text. Keep it in step when
upstream adds a section.
"""

import re
import sys
from pathlib import Path

# struct/enum name -> the TOML path its fields live at. `None` means the type is a
# container whose own fields are other sections (FileConfig), so its field names are
# section names already covered by the entries below.
STRUCT_PATHS = {
    "FileConfig": None,
    "IdentityConfig": "identity",
    "NetworkConfig": "network",
    "DiscoveryConfig": "network.discovery",
    # Keyed by NodeId, so the concrete hop is a wildcard.
    "DiscoveryPeer": "network.discovery.peers.*",
    "BlockchainConfig": "blockchain",
    "CacheConfig": "cache",
    "TinyLfuConfig": "cache.tinylfu",
    "ServeEconomicsConfig": "cache.serve_economics",
    "RetryPolicy": "cache.origin_retry",
    "CircuitBreakerPolicy": "cache.circuit_breaker",
    "PaymentConfig": "payment",
    "ObservabilityConfig": "observability",
    "SecurityConfig": "security",
    "LoadShedConfig": "load_shed",
    "DhtConfig": "dht",
    "DhtRateLimitConfig": "dht.rate_limit",
    "ProbeConfig": "probe",
    "ProbeRateLimitConfig": "probe.rate_limit",
    "ReceiptsConfig": "receipts",
    "ContentConfig": "content",
}

# The single [cache.origin] table and the [[cache.origins]] array of tables take the
# same fields, so every origin-shaped path is emitted under both prefixes.
ORIGIN_PREFIXES = ("cache.origin", "cache.origins")

# OriginConfig is `#[serde(tag = "kind")]` over Http { url, decompress },
# Fs { path } and S3(S3OriginConfig): the tag and the variant payloads are not
# struct fields anywhere, so they are named here. S3Credentials is likewise
# `#[serde(tag = "source")]` over Static {...} and DefaultChain { profile }; only
# the default-chain arm is templated by this role (static AWS keys must never be
# written into the 0640 node.toml), so only its fields are listed.
ORIGIN_ENUM_FIELDS = ["kind", "url", "decompress", "path"]
CREDENTIAL_FIELDS = ["source", "profile"]

FIELD_RE = re.compile(r"^\s+pub\s+([a-z_0-9]+)\s*:")
TYPE_RE = re.compile(r"^pub\s+(?:struct|enum)\s+([A-Za-z0-9_]+)")


def fields_by_struct(paths):
    """Map every `pub struct`/`pub enum` name to its own `pub field:` names."""
    out, current = {}, None
    for path in paths:
        for line in Path(path).read_text().splitlines():
            type_match = TYPE_RE.match(line)
            if type_match:
                current = type_match.group(1)
                out.setdefault(current, [])
                continue
            field_match = FIELD_RE.match(line)
            if field_match and current:
                out[current].append(field_match.group(1))
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <path-to-decdn-checkout>")
    decdn = Path(sys.argv[1])
    sources = [
        decdn / "crates/common/src/config/types.rs",
        decdn / "crates/config-types/src/retry.rs",
        decdn / "crates/config-types/src/circuit_breaker.rs",
    ]
    missing = [str(s) for s in sources if not s.is_file()]
    if missing:
        sys.exit(f"not a decdn checkout -- missing: {', '.join(missing)}")

    by_struct = fields_by_struct(sources)

    unknown = sorted(
        name for name in STRUCT_PATHS if name not in by_struct
    )
    if unknown:
        sys.exit(
            "these structs are in STRUCT_PATHS but not in the upstream sources "
            f"(renamed or removed upstream?): {', '.join(unknown)}"
        )

    paths = set()
    for struct, prefix in STRUCT_PATHS.items():
        if prefix is None:
            continue
        for field in by_struct[struct]:
            paths.add(f"{prefix}.{field}")

    # S3OriginConfig's fields, plus the enum tag/payload names, under both the
    # singular and the array-of-tables prefix.
    for prefix in ORIGIN_PREFIXES:
        for field in by_struct["S3OriginConfig"] + ORIGIN_ENUM_FIELDS:
            paths.add(f"{prefix}.{field}")
        for field in CREDENTIAL_FIELDS:
            paths.add(f"{prefix}.credentials.{field}")

    print(
        "# Every FULLY-QUALIFIED config path the deCDN node accepts, one per line.\n"
        "#\n"
        "# GENERATED -- do not hand-edit. Regenerate with:\n"
        "#\n"
        "#     ./gen-schema-keys.py <path-to-decdn-checkout> > schema-keys.txt\n"
        "#\n"
        "# Paths, not bare leaf names: `sketch_bytes` is legal at\n"
        "# cache.tinylfu.sketch_bytes and a startup failure at cache.sketch_bytes, and\n"
        "# a leaf-name inventory cannot tell the two apart. See gen-schema-keys.py for\n"
        "# the struct -> path mapping and molecule/schema/README.md for why this exists.\n"
        "#\n"
        f"# Synced from decdn/decdn @ d306cc5c (crate version 0.1.1): {len(paths)} paths."
    )
    for path in sorted(paths):
        print(path)


if __name__ == "__main__":
    main()
