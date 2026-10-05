#!/usr/bin/env python3
"""Regenerate the roles' network profiles from upstream deployment manifests.

    scripts/sync-network-profiles.py <path-to-decdn-checkout> [--ref origin/main] [--check]

Writes ansible/roles/decdn_node/vars/main/networks.yml: one entry per chain upstream's
`decdn config init --chain <name>` knows, holding the contract addresses that command
would bake into node.toml. Operators then set `decdn_network: <name>` instead of
hand-copying eight addresses that change wholesale on every upstream redeploy.

Also writes the subsets two other roles need, from the same parsed data, so the roles
can never disagree about a chain: ansible/roles/sponsord/vars/main/networks.yml
(chain_id + the PaymentPool address) and ansible/roles/sponsord_onramp/vars/main/
networks.yml (chain_id + CapacityBond and SlashJudge, which the onramp hands to users'
decdn). --check covers all three files.

Everything is read from git at --ref (default origin/main), never from the working
tree, so a checkout sitting on a feature branch still yields main's deployment. Two
upstream files are the source, and both the chain list AND the manifest-key mapping
are parsed from the first, so this script holds no hand-written copy of either:

  crates/cli/src/known_chains.rs     KNOWN_CHAINS (name + chain_id) and
                                     KnownChain::addresses() (field <- manifest key)
  contracts/deployments/<id>.json    that chain's manifest (the CLI embeds a
                                     byte-identical copy under crates/cli/deployments/)

What it cannot derive is which role variable each upstream field feeds; that is
FIELDS below. If upstream adds, drops or renames an address field, the script stops
rather than guess, because the role and its node.toml template need the same change.

Exit status: 0 current/written, 1 stale (--check), 2 could not run (git, parse or
manifest errors), so the drift job can tell drift from breakage.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "ansible/roles/decdn_node/vars/main/networks.yml"
SPONSORD_OUT = REPO / "ansible/roles/sponsord/vars/main/networks.yml"
ONRAMP_OUT = REPO / "ansible/roles/sponsord_onramp/vars/main/networks.yml"

# Upstream ChainAddresses field -> decdn_node variable suffix (decdn_<suffix>).
# Order is the output order.
FIELDS = {
    "payment_pool": "payment_pool_address",
    "capacity_bond": "capacity_bond_address",
    "slash_judge": "slash_judge_address",
    "content_blacklist": "content_blacklist_address",
    "slash_appeal": "slash_appeal_address",
    "origin_assignment": "origin_assignment_address",
    "publisher_registry": "publisher_registry_address",
    "usdc": "usdc_address",
}

# The FIELDS values sponsord's profile keeps (its role variables are
# sponsord_<suffix>). Order is the output order.
SPONSORD_FIELDS = ["payment_pool_address"]
# Likewise for sponsord_onramp (variables sponsord_onramp_<suffix>).
ONRAMP_FIELDS = ["capacity_bond_address", "slash_judge_address"]

ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
REGISTRY = re.compile(r"KNOWN_CHAINS\s*:\s*&\[\s*KnownChain\s*\]\s*=\s*&\[(?P<body>.*?)\];", re.S)
ENTRY = re.compile(r"KnownChain\s*\{(?P<body>.*?)\}", re.S)
NAME = re.compile(r"\bname:\s*\"(?P<v>[^\"]+)\"")
CHAIN_ID = re.compile(r"\bchain_id:\s*(?P<v>[0-9_]+)\s*,")
ADDRESSES_FN = re.compile(r"fn addresses\(.*?Ok\(ChainAddresses\s*\{(?P<body>.*?)\}\)", re.S)
FROM_CONTRACT = re.compile(r"(?P<field>\w+):\s*contract\(\"(?P<key>\w+)\"\)\?")
FROM_EXTERNAL = re.compile(r"(?P<field>\w+):\s*manifest\.external_deps\.(?P<key>\w+)")


def die(msg: str) -> None:
    print(f"sync-network-profiles: {msg}", file=sys.stderr)
    sys.exit(2)


def git(upstream: Path, *args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(upstream), *args], check=True, capture_output=True, text=True
        ).stdout
    except subprocess.CalledProcessError as e:
        die(f"git {' '.join(args)} failed: {e.stderr.strip() or e}")
    except FileNotFoundError:
        die("git not found")


def parse_registry(source: str) -> list[tuple[str, int]]:
    registry = REGISTRY.search(source)
    if not registry:
        die("KNOWN_CHAINS not found in known_chains.rs")
    entries = ENTRY.findall(registry.group("body"))
    if not entries:
        die("KNOWN_CHAINS is empty")
    chains = []
    for body in entries:
        name, chain_id = NAME.search(body), CHAIN_ID.search(body)
        # Every entry must parse: a skipped chain would make --check pass vacuously.
        if not (name and chain_id):
            die(f"could not read name/chain_id from a KNOWN_CHAINS entry:\n{body.strip()}")
        chains.append((name.group("v"), int(chain_id.group("v").replace("_", ""))))
    return chains


def parse_mapping(source: str) -> dict[str, tuple[str, str]]:
    """Upstream field -> ("contracts" | "externalDeps", manifest key)."""
    fn = ADDRESSES_FN.search(source)
    if not fn:
        die("KnownChain::addresses() not found in known_chains.rs")
    mapping = {m["field"]: ("contracts", m["key"]) for m in FROM_CONTRACT.finditer(fn.group("body"))}
    mapping |= {m["field"]: ("externalDeps", m["key"]) for m in FROM_EXTERNAL.finditer(fn.group("body"))}
    if set(mapping) != set(FIELDS):
        die(
            "upstream's address fields changed: "
            f"added {sorted(set(mapping) - set(FIELDS))}, removed {sorted(set(FIELDS) - set(mapping))}. "
            "Update FIELDS here, the role's defaults and node.toml.j2 together."
        )
    return mapping


def load(upstream: Path, ref: str) -> tuple[str, list[dict]]:
    """(commit, [{name, chain_id, <FIELDS values>..., deploy_block}]) from upstream at ref."""
    commit = git(upstream, "rev-parse", "--verify", f"{ref}^{{commit}}").strip()
    source = git(upstream, "show", f"{ref}:crates/cli/src/known_chains.rs")
    chains = parse_registry(source)
    mapping = parse_mapping(source)

    profiles = []
    for name, chain_id in chains:
        raw = git(upstream, "show", f"{ref}:contracts/deployments/{chain_id}.json")
        try:
            manifest = json.loads(raw)
        except json.JSONDecodeError as e:
            die(f"{chain_id}.json is not valid JSON: {e}")
        if manifest.get("chainId") != chain_id:
            die(f"{chain_id}.json chainId {manifest.get('chainId')} != registry {chain_id} for {name}")
        profile = {"name": name, "chain_id": chain_id}
        for field, var in FIELDS.items():
            section, key = mapping[field]
            value = manifest.get(section, {}).get(key)
            if not isinstance(value, str) or not ADDRESS.match(value):
                die(f"{name}: {section}.{key} is {value!r} in {chain_id}.json, not a 0x address")
            profile[var] = value
        profile["deploy_block"] = int(manifest["deployBlock"])
        profiles.append(profile)
    return commit, profiles


def render(commit: str, profiles: list[dict]) -> str:
    lines = [
        "---",
        "# GENERATED by scripts/sync-network-profiles.py -- do not hand-edit.",
        f"# Source: decdn/decdn @ {commit}",
        "#   crates/cli/src/known_chains.rs (KNOWN_CHAINS, KnownChain::addresses)",
        "#   + contracts/deployments/<chainId>.json",
        "#",
        "# The addresses `decdn config init --chain <name>` bakes into node.toml. The role's",
        "# address defaults read this map lazily when decdn_network is set, so an explicit",
        "# inventory value still wins. Protocol facts: upstream's deployment manifests are",
        "# the source, this file only mirrors them.",
        "_decdn_network_profiles:",
    ]
    for p in profiles:
        lines += [f"  {p['name']}:", f"    chain_id: {p['chain_id']}"]
        lines += [f'    {var}: "{p[var]}"' for var in FIELDS.values()]
        lines.append(f"    deploy_block: {p['deploy_block']}")
    return "\n".join(lines) + "\n"


def render_subset(commit: str, profiles: list[dict], role: str, fields: list[str]) -> str:
    lines = [
        "---",
        "# GENERATED by scripts/sync-network-profiles.py -- do not hand-edit.",
        f"# Source: decdn/decdn @ {commit}",
        "#   crates/cli/src/known_chains.rs (KNOWN_CHAINS, KnownChain::addresses)",
        "#   + contracts/deployments/<chainId>.json",
        "#",
        f"# The subset of roles/decdn_node/vars/main/networks.yml {role} needs. The role's",
        f"# chain defaults read this map lazily when {role}_network is set, so an explicit",
        "# inventory value still wins. Protocol facts: upstream's deployment manifests are",
        "# the source, this file only mirrors them.",
        f"_{role}_network_profiles:",
    ]
    for p in profiles:
        lines += [f"  {p['name']}:", f"    chain_id: {p['chain_id']}"]
        lines += [f'    {var}: "{p[var]}"' for var in fields]
    return "\n".join(lines) + "\n"


def strip_commit(text: str) -> str:
    return re.sub(r"^# Source: .*$", "", text, flags=re.M)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("upstream", type=Path, help="path to a decdn/decdn git checkout")
    ap.add_argument("--ref", default="origin/main", help="git ref to read (default: origin/main)")
    ap.add_argument("--check", action="store_true", help="exit 1 if the committed file is stale")
    args = ap.parse_args()

    commit, profiles = load(args.upstream, args.ref)
    outputs = [
        (OUT, render(commit, profiles)),
        (SPONSORD_OUT, render_subset(commit, profiles, "sponsord", SPONSORD_FIELDS)),
        (ONRAMP_OUT, render_subset(commit, profiles, "sponsord_onramp", ONRAMP_FIELDS)),
    ]
    if args.check:
        stale = False
        for out, text in outputs:
            current = out.read_text() if out.exists() else ""
            if strip_commit(current) != strip_commit(text):
                print(f"{out.relative_to(REPO)} is stale against {args.ref}; re-run without --check", file=sys.stderr)
                stale = True
            else:
                print(f"{out.relative_to(REPO)} is current against {args.ref}")
        if stale:
            sys.exit(1)
        return
    for out, text in outputs:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print(f"wrote {out.relative_to(REPO)}")

if __name__ == "__main__":
    main()
