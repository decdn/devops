#!/usr/bin/env python3
"""Check the invariants cloud-init/README.md promises for a user-data file.

Usage: lint.py <user-data.yaml>  (normally via `make lint-cloud-init`)

`cloud-init schema` checks the file's shape, including the `#cloud-config` header. This
script checks what the schema cannot:
  * no secret anywhere:
    - write_files writes only the bootstrap's own four files, as plain text;
    - no key whose name looks secret-bearing (RPC URL, password, token, keystore
      contents, private key, decdn_extra_env);
    - no `NAME=value` assignment of a secret-looking variable in any string (file
      contents, commands);
    - no credentials embedded in a URL, and only the known keys in bootstrap.env;
  * nothing mentions the test-only switch that skips the host hardening;
  * the node is installed from the release, verified against the vendored deCDN key,
    and its wallet is generated on the host. The knobs that decide this may be set
    only in decdn_nodes.vars, where this checks them; a host var would override them;
  * the inventory puts localhost in decdn_nodes (site.yml's host pattern) with a local
    connection, and names a keyed admin account (baseline's lockout guard);
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
ENV_KEYS = {"DEVOPS_REPO", "DEVOPS_REF"}
# The molecule scenario's switch for skipping baseline in a container (bootstrap.sh).
# A user-data that creates it, by write_files or a command, ships an unhardened host.
TEST_ONLY_MARKER = "TEST-ONLY-skip-baseline"

# Knobs that decide the install's trust: allowed only in decdn_nodes.vars (checked
# there), because a host var or another group could override the checked value.
PINNED_VARS = {"decdn_node_install_method", "decdn_node_generate_keystore",
               "decdn_verify_release_signature"}
# Knobs a user-data may not set at all: a different signing key would make "verified"
# meaningless, and bootstrap.sh's secret gate looks for the default env file path.
FORBIDDEN_VARS = {"decdn_release_keyring", "decdn_env_file"}

# A key whose NAME suggests it carries a secret. Public-key material is fine
# (baseline_sudo_users[].keys), so match specific fragments, not "key" alone. extra_env
# is decdn_extra_env, the role's home for AWS credentials and similar.
SECRET_KEY = re.compile(r"passw|secret|token|rpc_url|private|api_?key|keystore|chpasswd|extra_env", re.I)
# Role knobs that match SECRET_KEY but carry no secret: booleans and file paths.
SECRET_KEY_ALLOW = {
    "decdn_node_generate_keystore",
    "baseline_sudo_passwordless",
    "decdn_keystore_file",
    "decdn_keystore_password_file",
    "grafana_alloy_secret_file",
}
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
    return json.loads(r.stdout) if r.stdout.strip() else None


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

    entries = [f for f in doc.get("write_files") or [] if isinstance(f, dict)]
    files = {f.get("path"): f for f in entries}
    for p in sorted(FILE_PATHS - files.keys()):
        violation(f"write_files has no {p}")
    for p in sorted(files.keys() - FILE_PATHS, key=str):
        violation(f"write_files writes {p}; only the bootstrap's own files belong in user-data "
                  "(secrets such as decdn.env are written on the host)")
    for f in entries:
        if f.get("encoding", "text/plain") not in ("text/plain", "text"):
            violation(f"write_files {f.get('path')}: encoding {f.get('encoding')} hides its content from this check")
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
        if "DECDN_RPC_URL" in line and not line.lstrip().startswith("#"):
            violation(f"line {i}: DECDN_RPC_URL belongs in /etc/decdn/decdn.env on the host, not in user-data")

    env = {}
    for line in files.get(ENV_PATH, {}).get("content", "").splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip()
    for k in env.keys() - ENV_KEYS:
        violation(f"bootstrap.env: unexpected key {k} (allowed: {', '.join(sorted(ENV_KEYS))})")
    if not env.get("DEVOPS_REPO", "").startswith("https://"):
        violation("bootstrap.env: DEVOPS_REPO must be an https:// URL")

    # --- The node and the inventory -------------------------------------------------
    group = inventory.get("decdn_nodes") or {}
    host = (group.get("hosts") or {}).get("localhost")
    if not isinstance(host, dict) or host.get("ansible_connection") != "local":
        violation("inventory: localhost must be in decdn_nodes with ansible_connection: local")
    if set(inventory) - {"decdn_nodes"}:
        violation(f"inventory: only the decdn_nodes group belongs here, not {sorted(set(inventory) - {'decdn_nodes'})}")
    for p, k in walk_keys(inventory):
        if k in PINNED_VARS and p != f"decdn_nodes.vars.{k}":
            violation(f"inventory: {p}: set {k} only in decdn_nodes.vars, where it is checked")
        if k in FORBIDDEN_VARS:
            violation(f"inventory: {p}: {k} may not be overridden here")
    iv = group.get("vars") or {}
    if iv.get("decdn_node_install_method") != "release":
        violation("inventory: decdn_node_install_method must be release (the only method that verifies "
                  "the binaries against deCDN's signature)")
    if iv.get("decdn_node_generate_keystore") is not True:
        violation("inventory: decdn_node_generate_keystore must be true (the wallet is generated on the host)")
    if iv.get("decdn_verify_release_signature", True) is not True:
        violation("inventory: decdn_verify_release_signature must not be turned off")
    users = iv.get("baseline_sudo_users") or []
    if not users or not all(isinstance(u, dict) and u.get("name") and u.get("keys") for u in users):
        violation("inventory: baseline_sudo_users needs at least one named account, each with keys (lockout guard)")

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
