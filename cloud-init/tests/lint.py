#!/usr/bin/env python3
"""Check the invariants cloud-init/README.md promises for a user-data file.

Usage: lint.py <user-data.yaml>  (normally via `make lint-cloud-init`, which checks
user-data-node.yaml, a node operator's cache node, and user-data-publisher.yaml, a
publisher's origin node with sponsord and its onramp)

`cloud-init schema` checks the file's shape, including the `#cloud-config` header. This
script checks what the schema cannot:
  * only the templates' top-level modules (package_update, packages, write_files,
    runcmd, final_message), and no YAML anchors or aliases in the file or its
    inventory, so what this reads is what cloud-init and Ansible read;
  * no secret anywhere:
    - write_files writes only the bootstrap's own four files, once each, as plain
      `content` (no encoding, append, source or defer);
    - no key whose name looks secret-bearing (RPC URL, password, token, keystore
      contents, private key, decdn_extra_env), except the onramp's public RPC URL;
    - no `NAME=value` assignment of a secret-looking variable in any string (file
      contents, commands);
    - no credentials embedded in a URL, and only the known keys in bootstrap.env;
  * nothing mentions the test-only switch that skips the host hardening;
  * every service is installed from its release, verified against the vendored key,
    and the node's wallet is generated on the host. The knobs that decide this may be
    set only in their own group's vars, where this checks them; a host var or another
    group's vars would override them. Nor may a user-data move the signing keys or the
    secret files bootstrap.sh's gate looks for;
  * the inventory holds only localhost, in decdn_nodes and/or sponsord_hosts (and
    decdn_origin_nodes only beside decdn_nodes, with an origin backend in its vars;
    sponsord_onramp_hosts only beside sponsord_hosts), with `ansible_connection: local`
    set at least once and nothing else anywhere, and names a keyed admin account
    (baseline's lockout guard). A malformed shape is a violation, not a traceback;
  * stage 1 and the login hint pass shellcheck, and runcmd runs exactly stage 1;
  * cloud-init/collections.lock.yml pins every collection in ansible/requirements.yml,
    at a version inside its range.

Exit 0 when all of that holds and 1 on a violated invariant (the message says which).
Exit 2 when the check cannot run: an unreadable or unparseable file (this one, the
embedded inventory, the lock or ansible/requirements.yml), or no yq or shellcheck.
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ENV_PATH = "/etc/decdn-bootstrap/bootstrap.env"
INVENTORY_PATH = "/etc/decdn-bootstrap/inventory.yml"
STAGE1_PATH = "/usr/local/sbin/decdn-bootstrap"
HINT_PATH = "/etc/profile.d/decdn-bootstrap.sh"
# The only files a user-data may write. Anything else (/etc/decdn/decdn.env,
# /etc/grafana-alloy.env, …) is where a secret would go, and belongs on the host.
FILE_PATHS = {ENV_PATH, INVENTORY_PATH, STAGE1_PATH, HINT_PATH}
# The only keys a write_files entry may carry. The rest change what lands on the host
# without changing the `content` this checks: encoding (b64, gzip), append (onto an
# earlier entry or a file already there), source (fetched from a URL) and defer.
FILE_KEYS = {"path", "owner", "permissions", "content"}
ENV_KEYS = {"DEVOPS_REPO", "DEVOPS_REF"}
# The only top-level cloud-config keys a user-data may use: the templates' own. Every
# other module runs commands or writes files (bootcmd, apt, salt_minion, ...) outside
# what this checks, or carries free-form YAML a check could be hidden in.
TOP_LEVEL_KEYS = {"package_update", "packages", "write_files", "runcmd", "final_message"}
# The molecule scenarios' switch for skipping baseline in a container (bootstrap.sh).
# A user-data that creates it, by write_files or a command, ships an unhardened host.
TEST_ONLY_MARKER = "TEST-ONLY-skip-baseline"

# The groups a user-data may use. site.yml (node.yml, then publisher.yml) targets them
# all, but every host is in decdn_nodes or sponsord_hosts: an origin is a node, so its
# group needs decdn_nodes too, and the onramp runs beside sponsord, so its group needs
# sponsord_hosts too. The template lists an origin in both groups as siblings (no
# `children:`, which this lint refuses); both are one level deep, so Ansible merges
# their vars by name and decdn_origin_nodes' win, which is harmless while the two set
# different keys.
GROUPS = ("decdn_nodes", "decdn_origin_nodes", "sponsord_hosts", "sponsord_onramp_hosts")
BASE_GROUPS = {"decdn_nodes", "sponsord_hosts"}

# Knobs this lint checks, by the group whose role reads them: allowed only in that
# group's vars (checked there), because a host var or another group could override the
# checked value. All but the last decide the install's trust.
PINNED_VARS = {
    "decdn_node_install_method": "decdn_nodes",
    "decdn_node_generate_keystore": "decdn_nodes",
    "decdn_verify_release_signature": "decdn_nodes",
    "sponsord_install_method": "sponsord_hosts",
    "sponsord_verify_release_signature": "sponsord_hosts",
    "sponsord_onramp_install_method": "sponsord_onramp_hosts",
    "sponsord_onramp_verify_release_signature": "sponsord_onramp_hosts",
    "sponsord_onramp_rpc_url": "sponsord_onramp_hosts",
}
# Knobs a user-data may not set at all: a different signing key would make "verified"
# meaningless, and bootstrap.sh's secret gate looks for the secrets at the roles'
# default paths. sponsord's API token is always generated on the host. A cloud-init
# sponsor runs on an operator-provisioned treasury wallet: the gate waits for
# the keystore before the role runs, so the role's own wallet generation (and the
# decdn CLI it ships for that) would never get the chance.
FORBIDDEN_VARS = {
    "decdn_release_keyring", "decdn_env_file",
    "sponsord_release_keyring", "sponsord_onramp_release_keyring",
    "sponsord_etc", "sponsord_secret_env_file", "sponsord_treasury_keystore_file",
    "sponsord_treasury_password_file", "sponsord_api_token_file", "sponsord_generate_api_token",
    "sponsord_generate_treasury_wallet", "sponsord_decdn_cli_bin_src",
    "sponsord_onramp_etc", "sponsord_onramp_api_token_file", "sponsord_onramp_turnstile_secret_file",
}

# A key whose NAME suggests it carries a secret. Public-key material is fine
# (baseline_sudo_users[].keys), so match specific fragments, not "key" alone. extra_env
# is decdn_extra_env, the role's home for AWS credentials and similar.
SECRET_KEY = re.compile(r"passw|secret|token|rpc_url|private|api_?key|keystore|chpasswd|extra_env", re.I)
# Role knobs that match SECRET_KEY but carry no secret: booleans, file paths and one
# public URL.
SECRET_KEY_ALLOW = {
    "decdn_node_generate_keystore",
    "baseline_sudo_passwordless",
    "decdn_keystore_file",
    "decdn_keystore_password_file",
    "grafana_alloy_secret_file",
    # Public by design: the onramp serves it to every user. PUBLIC_RPC_URL below holds it
    # to the role's own format check (no userinfo, query or fragment), here, before the
    # user-data ships it. A key in the URL's path cannot be told from a public path.
    "sponsord_onramp_rpc_url",
}
# The format roles/sponsord_onramp/tasks/main.yml asserts for sponsord_onramp_rpc_url.
# Run here too: by the time the role refuses a keyed URL, the user-data has already
# published the key through the instance metadata.
PUBLIC_RPC_URL = re.compile(r"https?://[^/?#@]+(/[^?#]*)?")
PUBLIC_RPC_URL_BAD_CHARS = re.compile(r"[\s'\"`$\\{}]")
# user:password@ (or token@) in any URL.
URL_CREDENTIALS = re.compile(r"[a-z][a-z0-9+.-]*://[^/\s@]+@", re.I)
# NAME=value for a secret-looking variable, in file contents or a command.
SECRET_ASSIGNMENT = re.compile(
    r"(?m)^\s*(export\s+)?[A-Z0-9_]*(TOKEN|SECRET|PASSW|API_?KEY|ACCESS_KEY|RPC_URL)[A-Z0-9_]*=")

errors = []


class ParseError(Exception):
    pass


def load_yaml(text):
    """Parse YAML via yq (mikefarah v4), as the repo's other checks do; no PyYAML needed."""
    if not shutil.which("yq"):
        print("lint.py: needs yq (mikefarah v4)", file=sys.stderr)
        sys.exit(2)
    r = subprocess.run(["yq", "-p=yaml", "-o=json", "."], input=text, text=True,
                       capture_output=True, check=False)
    if r.returncode != 0:
        raise ParseError(r.stderr.strip())
    try:
        return json.loads(r.stdout) if r.stdout.strip() else None
    except json.JSONDecodeError:
        # yq prints one JSON value per YAML document.
        raise ParseError("more than one YAML document") from None


def yaml_aliases(text):
    """How many anchors and aliases a YAML text holds. yq resolves a merge key (`<<: *x`)
    so that the alias beats a key written before it, where cloud-init's PyYAML and
    Ansible let the written key win: the same file would read one way here and
    another on the host. So none are allowed."""
    r = subprocess.run(["yq", "-p=yaml", '[.. | select(anchor != "" or kind == "alias")] | length'],
                       input=text, text=True, capture_output=True, check=False)
    if r.returncode != 0:
        print(f"lint.py: yq cannot list YAML anchors (needs mikefarah yq v4.38 or later): {r.stderr.strip()}",
              file=sys.stderr)
        sys.exit(2)
    return int(r.stdout.strip() or 0)


def violation(msg):
    errors.append(msg)


def walk_keys(node, path=""):
    """Yield (dotted path, key) for every mapping key in a parsed YAML tree."""
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{path}.{k}" if path else str(k)
            yield p, str(k)
            yield from walk_keys(v, p)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk_keys(v, f"{path}[{i}]")


def values_of(node, key):
    """Every value set for `key` anywhere in a parsed YAML tree."""
    found = []
    if isinstance(node, dict):
        for k, v in node.items():
            if str(k) == key:
                found.append(v)
            found += values_of(v, key)
    elif isinstance(node, list):
        for v in node:
            found += values_of(v, key)
    return found


# The onramp's installer pins: a tag and its SHA256SUMS digest per release, which only
# make sense together (the role defaults pin all four).
ONRAMP_PINS = ("sponsord_onramp_decdn_release", "sponsord_onramp_decdn_sums_sha256",
               "sponsord_onramp_cli_release", "sponsord_onramp_cli_sums_sha256")


def walk_strings(node, path=""):
    """Yield (dotted path, value) for every string scalar in a parsed YAML tree."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk_strings(v, f"{path}.{k}" if path else str(k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk_strings(v, f"{path}[{i}]")
    elif isinstance(node, str):
        yield path, node


def shellcheck(name, text, shell):
    if not shutil.which("shellcheck"):
        print("lint.py: needs shellcheck", file=sys.stderr)
        sys.exit(2)
    sc = subprocess.run(["shellcheck", "-s", shell, "-"], input=text, text=True,
                        capture_output=True, check=False)
    if sc.returncode != 0:
        violation(f"{name} fails shellcheck:\n{sc.stdout}{sc.stderr}")


def version_tuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def satisfies(version, spec):
    """Check a Galaxy-style spec made of comma-separated >=, >, <=, <, ==, != and *."""
    ops = {
        ">=": lambda a, b: a >= b, ">": lambda a, b: a > b,
        "<=": lambda a, b: a <= b, "<": lambda a, b: a < b,
        "==": lambda a, b: a == b, "!=": lambda a, b: a != b,
    }
    for part in str(spec).split(","):
        part = part.strip()
        if part in ("", "*"):
            continue
        m = re.fullmatch(r"(>=|<=|==|!=|>|<)?\s*(\S+)", part)
        op, ver = (m.group(1) or "=="), m.group(2)
        if not ops[op](version_tuple(version), version_tuple(ver)):
            return False
    return True


def check_lock():
    try:
        wanted = load_yaml((REPO / "ansible/requirements.yml").read_text())["collections"]
        lock = load_yaml((REPO / "cloud-init/collections.lock.yml").read_text())["collections"]
    except (OSError, ParseError, KeyError, TypeError) as e:
        print(f"lint.py: cannot read the collection requirements or lock: {e}", file=sys.stderr)
        sys.exit(2)
    pinned = {c["name"]: str(c.get("version", "")) for c in lock}
    for name, v in pinned.items():
        if not re.fullmatch(r"\d+\.\d+\.\d+", v):
            violation(f"collections.lock.yml: {name} must be pinned to an exact version, not {v!r}")
    for c in wanted:
        name, spec = c["name"], c.get("version", "*")
        if name not in pinned:
            violation(f"collections.lock.yml does not pin {name} (listed in ansible/requirements.yml)")
        elif not satisfies(pinned[name], spec):
            violation(f"collections.lock.yml pins {name} {pinned[name]}, outside ansible/requirements.yml's {spec}")


def check_inventory(inventory):
    """The inventory's shape, groups and pinned knobs.

    A shape this does not expect is reported, and the checks that read it are skipped,
    so a malformed inventory is a violation and not a traceback."""
    if not isinstance(inventory, dict):
        violation(f"inventory: must be a mapping of groups, not a {type(inventory).__name__}")
        return
    present = [g for g in GROUPS if g in inventory]
    if set(inventory) - set(GROUPS):
        violation(f"inventory: only the {', '.join(GROUPS)} groups belong here, "
                  f"not {sorted(set(inventory) - set(GROUPS))}")
    if not BASE_GROUPS & set(present):
        violation("inventory: localhost must be in decdn_nodes or sponsord_hosts (site.yml's host patterns)")
    if "decdn_origin_nodes" in present and "decdn_nodes" not in present:
        violation("inventory: decdn_origin_nodes needs decdn_nodes too (an origin is a deCDN node)")
    if "sponsord_onramp_hosts" in present and "sponsord_hosts" not in present:
        violation("inventory: sponsord_onramp_hosts needs sponsord_hosts too (the onramp runs beside the daemon)")
    groups = {}
    for g in present:
        group = inventory.get(g) or {}
        if not isinstance(group, dict):
            violation(f"inventory: {g} must be a mapping of hosts and vars")
            group = {}
        # Only what this lint inspects. A `children:` group would add hosts and drop
        # pinned knobs where nothing below looks.
        if set(group) - {"hosts", "vars"}:
            violation(f"inventory: {g} may hold only hosts and vars, not {sorted(set(group) - {'hosts', 'vars'}, key=str)}")
        if group.get("vars") is not None and not isinstance(group["vars"], dict):
            violation(f"inventory: {g}.vars must be a mapping")
        groups[g] = group
    # Ansible merges a host's variables across groups in an order this lint does not
    # model, so every group that sets the connection must set it to local.
    connections = []
    for g, group in groups.items():
        hosts = group.get("hosts") or {}
        if not isinstance(hosts, dict) or set(hosts) != {"localhost"}:
            violation(f"inventory: {g} must hold exactly localhost, not {sorted(hosts, key=str) if isinstance(hosts, dict) else hosts}")
            continue
        host = hosts.get("localhost")
        if host is not None and not isinstance(host, dict):
            violation(f"inventory: {g}.hosts.localhost must be a mapping of host vars, or empty")
        elif isinstance(host, dict) and "ansible_connection" in host:
            connections.append((g, host["ansible_connection"]))
    if not connections:
        violation("inventory: localhost needs ansible_connection: local")
    for g, c in connections:
        if c != "local":
            violation(f"inventory: {g}.hosts.localhost.ansible_connection is {c!r}; every group must use local")
    for p, k in walk_keys(inventory):
        if k in PINNED_VARS and p != f"{PINNED_VARS[k]}.vars.{k}":
            violation(f"inventory: {p}: set {k} only in {PINNED_VARS[k]}.vars, where it is checked")
        if k in FORBIDDEN_VARS:
            violation(f"inventory: {p}: {k} may not be overridden here")
    gv = {g: group.get("vars") if isinstance(group.get("vars"), dict) else {} for g, group in groups.items()}
    if "decdn_nodes" in gv:
        iv = gv["decdn_nodes"]
        if iv.get("decdn_node_install_method") != "release":
            violation("inventory: decdn_node_install_method must be release (the only method that verifies "
                      "the binaries against deCDN's signature)")
        if iv.get("decdn_node_generate_keystore") is not True:
            violation("inventory: decdn_node_generate_keystore must be true (the wallet is generated on the host)")
        if iv.get("decdn_verify_release_signature", True) is not True:
            violation("inventory: decdn_verify_release_signature must not be turned off")
    if "decdn_origin_nodes" in gv:
        # playbooks/origin.yml refuses an origin without a backend, but only after the
        # host waited for its secrets; say so before it boots. A placeholder is the
        # template's (the bootstrap refuses a CHANGE_ME left anywhere).
        ov = gv["decdn_origin_nodes"]
        kind, origins = ov.get("decdn_cache_origin_kind"), ov.get("decdn_cache_origins")
        if not (isinstance(kind, str) and kind) and not (isinstance(origins, list) and origins):
            violation("inventory: decdn_origin_nodes.vars needs an origin backend: decdn_cache_origin_kind "
                      "(http, fs or s3) and its fields, or decdn_cache_origins")
    for g, prefix in (("sponsord_hosts", "sponsord"), ("sponsord_onramp_hosts", "sponsord_onramp")):
        if g not in gv:
            continue
        if gv[g].get(f"{prefix}_install_method") != "release":
            violation(f"inventory: {prefix}_install_method must be release (the only method that verifies "
                      "the binary against its signature)")
        if gv[g].get(f"{prefix}_verify_release_signature", True) is not True:
            violation(f"inventory: {prefix}_verify_release_signature must not be turned off")
    if "sponsord_onramp_hosts" in gv:
        # Unset is the role's to refuse (it is required); the placeholder is the template's.
        url = gv["sponsord_onramp_hosts"].get("sponsord_onramp_rpc_url", "CHANGE_ME")
        if url != "CHANGE_ME" and (not isinstance(url, str) or not PUBLIC_RPC_URL.fullmatch(url)
                                   or PUBLIC_RPC_URL_BAD_CHARS.search(url)):
            violation("inventory: sponsord_onramp_rpc_url must be a public http(s) URL with no userinfo, query "
                      "or fragment (the onramp serves it to every user; a keyed URL belongs to sponsord)")
    # decdn/sponsord ships both daemons in one release, so a user-data that moves one
    # version off the role default must move the other with it.
    if "sponsord_onramp_hosts" in groups:
        sv = values_of(inventory, "sponsord_version")
        ov = values_of(inventory, "sponsord_onramp_version")
        if (sv or ov) and not (len(sv) == len(ov) == 1 and str(sv[0]) == str(ov[0])):
            violation("inventory: set sponsord_version and sponsord_onramp_version together, once each and "
                      "equal (one decdn/sponsord release ships both)")
        pins = [k for k in ONRAMP_PINS if values_of(inventory, k)]
        if pins and len(pins) != len(ONRAMP_PINS):
            violation(f"inventory: set all of {', '.join(ONRAMP_PINS)} or none (a release tag without its "
                      f"SHA256SUMS digest fails every installer); set: {', '.join(pins)}")
    # Ansible applies one baseline_sudo_users list, the one from the highest-precedence
    # place that sets it, not the union. So it may be set once, and that list is checked.
    sudo_lists = {}
    for g, group in groups.items():
        hosts = group.get("hosts")
        host = hosts.get("localhost") if isinstance(hosts, dict) else None
        for where, scope in ((f"{g}.vars", gv[g]), (f"{g}.hosts.localhost", host)):
            if isinstance(scope, dict) and "baseline_sudo_users" in scope:
                sudo_lists[where] = scope["baseline_sudo_users"]
    if len(sudo_lists) > 1:
        violation(f"inventory: set baseline_sudo_users in one place, not {sorted(sudo_lists)}: Ansible applies "
                  "one of the lists, not their union, so the other accounts would not exist")
    users = next(iter(sudo_lists.values()), None) or []
    if not isinstance(users, list) or not users \
            or not all(isinstance(u, dict) and u.get("name") and u.get("keys") for u in users):
        violation("inventory: baseline_sudo_users needs at least one named account, each with keys (lockout guard)")


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    path = Path(sys.argv[1])
    try:
        raw = path.read_text()
        doc = load_yaml(raw)
    except (OSError, ParseError) as e:
        print(f"lint.py: cannot parse {path}: {e}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(doc, dict):
        print(f"lint.py: {path} is not a YAML mapping", file=sys.stderr)
        sys.exit(2)
    for k in sorted(set(doc) - TOP_LEVEL_KEYS, key=str):
        violation(f"{k}: only the top-level keys {', '.join(sorted(TOP_LEVEL_KEYS))} are allowed; "
                  "other modules run commands or write files that this does not check")
    if yaml_aliases(raw):
        violation("the user-data uses YAML anchors or aliases; yq and cloud-init can resolve them differently")

    entries = doc.get("write_files") or []
    if not isinstance(entries, list):
        violation("write_files must be a list of files")
        entries = []
    files = {}
    for i, f in enumerate(entries):
        if not isinstance(f, dict):
            violation(f"write_files[{i}] must be a mapping with a path and its content")
            continue
        p = f.get("path")
        if not isinstance(p, str):
            violation(f"write_files[{i}]: path must be a string, not {p!r}")
            continue
        for k in sorted(set(f) - FILE_KEYS, key=str):
            violation(f"write_files {p}: {k} is not allowed (only {', '.join(sorted(FILE_KEYS))}), so the "
                      "content checked here is what lands on the host")
        if not isinstance(f.get("content"), str) or not f["content"].strip():
            violation(f"write_files {p}: content must be non-empty text")
            f = {**f, "content": ""}
        if p in files:
            violation(f"write_files writes {p} twice; cloud-init would apply both, and only the first is checked")
            continue
        files[p] = f
    for p in sorted(FILE_PATHS - files.keys()):
        violation(f"write_files has no {p}")
    for p in sorted(files.keys() - FILE_PATHS, key=str):
        violation(f"write_files writes {p}; only the bootstrap's own files belong in user-data "
                  "(secrets such as decdn.env are written on the host)")
    for p in (ENV_PATH, INVENTORY_PATH):
        if p in files and str(files[p].get("permissions")) != "0600":
            violation(f"{p} must be written 0600")
    if TEST_ONLY_MARKER in raw:
        violation(f"the user-data mentions {TEST_ONLY_MARKER}, the test-only switch that skips host hardening")

    # --- No secrets ---------------------------------------------------------------
    try:
        inventory = load_yaml(files.get(INVENTORY_PATH, {}).get("content", "")) or {}
    except ParseError as e:
        print(f"lint.py: the embedded {INVENTORY_PATH} does not parse: {e}", file=sys.stderr)
        sys.exit(2)
    if yaml_aliases(files.get(INVENTORY_PATH, {}).get("content", "")):
        violation("inventory: uses YAML anchors or aliases; yq and Ansible can resolve them differently")
    for where, tree in (("user-data", doc), ("inventory", inventory)):
        for p, k in walk_keys(tree):
            if SECRET_KEY.search(k) and k not in SECRET_KEY_ALLOW:
                violation(f"{where}: {p} looks secret-bearing; secrets never go in user-data")
    for where, tree in (("user-data", doc), ("inventory", inventory)):
        for p, v in walk_strings(tree):
            if SECRET_ASSIGNMENT.search(v):
                violation(f"{where}: {p} assigns a secret-looking variable; secrets never go in user-data")
    for i, line in enumerate(raw.splitlines(), 1):
        if URL_CREDENTIALS.search(line):
            violation(f"line {i}: a URL with embedded credentials")
        if not line.lstrip().startswith("#"):
            for var, home in (("DECDN_RPC_URL", "/etc/decdn/decdn.env"),
                              ("SPONSORD_RPC_URL", "/etc/sponsord/secret.env")):
                if var in line:
                    violation(f"line {i}: {var} belongs in {home} on the host, not in user-data")

    env = {}
    for line in files.get(ENV_PATH, {}).get("content", "").splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip()
    for k in env.keys() - ENV_KEYS:
        violation(f"bootstrap.env: unexpected key {k} (allowed: {', '.join(sorted(ENV_KEYS))})")
    if not env.get("DEVOPS_REPO", "").startswith("https://"):
        violation("bootstrap.env: DEVOPS_REPO must be an https:// URL")

    check_inventory(inventory)

    # --- Stage 1 --------------------------------------------------------------------
    # Exactly stage 1, so nothing masks its exit status (`|| true`) from cloud-init.
    if doc.get("runcmd") not in ([[STAGE1_PATH]], [STAGE1_PATH]):
        violation(f"runcmd must be exactly [[{STAGE1_PATH}]], so a failure shows in cloud-init status")
    if files.get(STAGE1_PATH, {}).get("content"):
        shellcheck(STAGE1_PATH, files[STAGE1_PATH]["content"], "bash")
    if files.get(HINT_PATH, {}).get("content"):
        shellcheck(HINT_PATH, files[HINT_PATH]["content"], "sh")

    check_lock()

    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    if errors:
        print(f"{path} violates an invariant (see cloud-init/tests/lint.py)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
