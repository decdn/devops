# A deCDN fleet from the Galaxy collections

A starting point for a **private** repository that deploys deCDN from the
[`decdn.node`](../../ansible/galaxy/node/README.md) and
[`decdn.publisher`](../../ansible/galaxy/publisher/README.md) collections alone: the
collections bring the roles and the playbooks (firewall holes, placement checks and
lifecycle guards included), and this repository holds only your inventory.

| File | What it is |
|------|------------|
| `requirements.yml` | the collections, from Ansible Galaxy (delete `decdn.publisher` for cache nodes only) |
| `ansible.cfg` | decdn/devops's `ansible/ansible.cfg`, minus `roles_path`, failing on an inventory that does not parse |
| `.gitignore` | keeps the installed collections, per-host secrets and backups out of git |
| `inventory/` | the inventory templates: `hosts-node.yml.example` and `hosts-publisher.yml.example`, with their `group_vars/` and `host_vars/` |
| `.github/workflows/ci.yml` | CI: the pre-commit hooks; a fresh Galaxy install that loads your inventory and syntax-checks the playbooks against it; actionlint ([Checks](#checks)) |
| `.pre-commit-config.yaml`, `.yamllint`, `.markdownlint-cli2.yaml` | the lint gate: hygiene, shellcheck, yamllint over `inventory/` and `requirements.yml`, markdownlint, the vars-shadowing check, and the vault files' encryption |
| `scripts/check-vars-shadowing.sh` | refuses two vars sources of the same name in `group_vars/` or `host_vars/`, which Ansible would silently reduce to one |
| `scripts/check-vault-encrypted.sh` | refuses a committed `vault.yml` that is not ansible-vault encrypted ([Encrypted secrets](#encrypted-secrets-optional)) |
| `.github/dependabot.yml` | weekly bumps of the pinned actions and hook revs (not of the collections) |
| `AGENTS.md`, `CLAUDE.md` | guidance for AI coding agents; fill in its *This fleet* section |

The `inventory/` templates are decdn/devops's `ansible/inventory/` ones, with the hosts
examples' headers written for this layout (decdn/devops's `make test-scripts` keeps
everything else identical). Their comments name files by their path in decdn/devops:
`roles/<role>/…` and `playbooks/…` ship in the collections, under
`collections/ansible_collections/decdn/{node,publisher}/` once installed.

## Set up

Copy this directory into a new private repository, then, in that copy (never in a
decdn/devops checkout, which is public), start your inventory from the template for
your role:

```bash
ansible-galaxy collection install -r requirements.yml -p collections
cp inventory/hosts-node.yml.example inventory/hosts.yml   # or hosts-publisher.yml.example
```

Fill in `inventory/hosts.yml` and its `group_vars/` and `host_vars/` (each file says
what it needs; [`ansible/README.md`](../../ansible/README.md) has the variables and the
on-host secrets), and commit them. In `hosts-publisher.yml.example` only the origin is
live: uncomment the groups you run. Rename `host_vars/decdn-node-1/` (and `origin-1/`)
to your hosts, and keep secrets in the git-ignored `host_vars/<host>/secret.yml`
(copied from its `secret.yml.example`).

A secret every host of a group shares (one `decdn_rpc_url` for every node, say) can go
once in the git-ignored `group_vars/<group>/secret.yml` instead, and one for every host
(a `grafana_alloy_api_token` the sponsord and relay hosts use too) in
`group_vars/all/secret.yml`. Move the group's file into that directory first:

```bash
mkdir inventory/group_vars/decdn_nodes
git mv inventory/group_vars/decdn_nodes.yml inventory/group_vars/decdn_nodes/main.yml
```

Ansible reads a `group_vars/<group>/` directory *in place of* a `group_vars/<group>.yml`
beside it and never says so, so keeping both silently drops every setting in the file
(the same holds for `host_vars/`, and for a `.yml` beside a `.yaml`).
`scripts/check-vars-shadowing.sh` refuses such a pair, from the pre-commit hook and
from CI. A host's own `secret.yml` still wins over the group's for the same variable.

### Encrypted secrets (optional)

A git-ignored `secret.yml` lives on one machine: a teammate or a second control machine
rebuilds it by hand. To share the secrets through this repository instead, commit them
encrypted with [ansible-vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html)
as `vault.yml`, beside where `secret.yml` would go (`host_vars/<host>/vault.yml`, or
`group_vars/<group>/vault.yml` after moving the group's file as above). `secret.yml` stays
git-ignored, and a fleet with no `vault.yml` works exactly as before. Writing the secret
files on the hosts themselves (each `secret.yml.example` names them) still keeps them off
your control machine altogether, and remains the first choice.

```bash
mkdir -p ~/.config && (umask 077 && openssl rand -base64 32 >~/.config/decdn-vault-pass)
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/decdn-vault-pass   # for this repository only (see below)
ansible-vault create inventory/group_vars/decdn_nodes/vault.yml # the same keys as secret.yml.example
ansible-vault edit inventory/group_vars/decdn_nodes/vault.yml   # change it later
ansible-vault view inventory/group_vars/decdn_nodes/vault.yml
```

- **The password** never goes in the repository. Generate a long random one, as above:
  anyone with a copy of the repository can try passwords against the file offline.
  `ANSIBLE_VAULT_PASSWORD_FILE` may instead name an executable script that prints the
  password (one that runs `pass show decdn/vault` or `op read op://…`, say, with its
  executable bit set), so it never sits in a file. Set the variable for this repository
  only (direnv's `.envrc`, or by hand per shell): set globally, every Ansible run on the
  machine reads it and fails if the file is gone. Never set `vault_password_file` in
  `ansible.cfg` either: Ansible then fails for anyone without that file, vault or not.
- **Without the password**, a run that reaches a host with a vault file among its vars
  fails as its play starts ("Attempting to decrypt but no vault secrets found"); one
  that reaches only other hosts runs as before.
- **Never decrypt in place** (`ansible-vault decrypt`), and never append to the file:
  change it with `edit`. The `vault-encrypted` pre-commit hook
  (`scripts/check-vault-encrypted.sh`) refuses a `vault.yml`, `.yaml` or `.json` that is
  not the vault header followed by ciphertext only, at any depth under a group or host
  directory, and CI runs it on every file.
- **One file per variable.** Ansible loads a vars directory's files in name order, so
  for the same variable `vault.yml` beats `secret.yml`, which beats `main.yml`. Keep each
  secret in exactly one of them.
- **Readable diffs:** `echo 'inventory/**/vault.* diff=ansible-vault' >>.gitattributes`
  (commit it), then on each machine
  `git config diff.ansible-vault.textconv 'ansible-vault view'`. `git diff` and
  `git log -p` then print the secrets in plaintext to your terminal, and need
  `ANSIBLE_VAULT_PASSWORD_FILE` set (without it they prompt per file, or fail when not
  interactive).
- **When someone leaves**, `ansible-vault rekey` every `vault.yml` with a new password,
  *and* rotate the secrets themselves: git history keeps every earlier ciphertext, and
  the old password still opens it.
- **CI**, when the repository has an `ANSIBLE_VAULT_PASSWORD` Actions secret, decrypts
  every committed vault file with it (even one of a host the inventory no longer
  names) and fails on any that does not open. Without the secret, and on pull requests
  from forks and from Dependabot, which do not get Actions secrets (Dependabot reads
  its own Dependabot secrets: add it there too to have those decrypt), it replaces each
  vault file with an empty mapping, warns, and checks the rest of the inventory
  ([Checks](#checks)).

## Run

```bash
ansible-playbook decdn.publisher.site -l <host> --tags baseline -u root   # a fresh host's first run; swap root for your image's bootstrap user
ansible-playbook decdn.publisher.site -l <host> --check --diff            # dry run
ansible-playbook decdn.publisher.site -l <host>                           # everything the inventory gives the host
ansible-playbook decdn.publisher.backup -l <host>                         # fetched to backups/, beside ansible.cfg
ansible-playbook decdn.publisher.decommission -l <host>                   # asks you to type the host; keeps the keys
```

`decdn.publisher.site` runs whichever playbooks the host's groups call for: a cache
node, an origin, sponsord, a relay or a DNS server. The first run is baseline only: it
creates your admin account and turns root login off, after which a relay's full run
can read the nodes' IDs over SSH as that account. Installed `decdn.node` alone, for
cache nodes? Use `decdn.node.node`, `decdn.node.backup` and `decdn.node.decommission`
in their place.

### From `make` to `ansible-playbook`

The docs elsewhere use this repository's make targets. Here, each is one
`ansible-playbook` command, run from this directory (`ansible.cfg` points at
`inventory/hosts.yml`, so no `-i`):

| In `decdn/devops/ansible/` | Here |
|----------------------------|------|
| `make deps` | `ansible-galaxy collection install -r requirements.yml -p collections` |
| `make deploy-node LIMIT=<host>` | `ansible-playbook decdn.node.node -l <host>` |
| `make deploy LIMIT=<host>` | `ansible-playbook decdn.publisher.site -l <host>` (with `decdn.node` alone: `decdn.node.node`) |
| `make deploy-publisher LIMIT=<host>` | `ansible-playbook decdn.publisher.publisher -l <host>` |
| `make deploy-origin LIMIT=<host>` | `ansible-playbook decdn.publisher.origin -l <host>` |
| `make deploy-sponsord LIMIT=<host>` | `ansible-playbook decdn.publisher.sponsord -l <host>` |
| `make deploy-relay LIMIT=<host>` | `ansible-playbook decdn.publisher.iroh_relay -l <host>` |
| `make deploy-dns LIMIT=<host>` | `ansible-playbook decdn.publisher.iroh_dns_server -l <host>` |
| `make deploy-gateway LIMIT=<host>` | `ansible-playbook decdn.publisher.decdn_gateway -l <host>` |
| `make backup LIMIT=<host>` | `ansible-playbook decdn.publisher.backup -l <host>` (with `decdn.node` alone: `decdn.node.backup`, nodes only) |
| `make decommission LIMIT=<host>` | `ansible-playbook decdn.publisher.decommission -l <host>` (with `decdn.node` alone: `decdn.node.decommission`, for a host that runs only a node) |
| `make check…` (any) | the same command with `--check --diff` |
| `INVENTORY=<path>` | `-i <path>` |
| `ANSIBLE_ARGS='-u root -e x=y'` | `-u root -e x=y`, plain options |

Never use `decdn.node.decommission` on a host that also runs sponsord, a relay, a
DNS server or a gateway: it removes the Grafana Alloy agent they share and leaves them running. The
collection READMEs list every playbook and what it runs.

**What the Makefile checks and a plain `ansible-playbook` does not.** Each of these
runs exits 0 here, having done nothing or not what you meant, so pass `-l`, use the
playbook for the host's group, and read the PLAY RECAP:

- a run with no `-l` reaches every host the playbook targets (decommission still
  refuses more than `decdn_decommission_max_hosts` hosts, default 1);
- a `-l` that matches no host of the playbook, such as an origin under
  `decdn.node.node` (origins are `decdn.publisher.origin`'s).

The Makefile's third check, an inventory that fails to parse, is `ansible.cfg`'s
`unparsed_is_failed` here.

## Checks

```bash
pip install pre-commit && pre-commit install   # once: the hooks run on every commit
pre-commit run --all-files                     # hygiene, yamllint, markdownlint, vault files encrypted
```

CI (`.github/workflows/ci.yml`) runs on pull requests and pushes to `main`: the same
hooks, and beside them an `ansible` job that installs the collections fresh from
Galaxy, runs the vars-shadowing check, loads the inventory with every vars file
(`ansible-inventory --list`) and syntax-checks `decdn.publisher.site`, `.backup` and
`.decommission` against it (swap in the `decdn.node.*` ones if you installed
`decdn.node` alone). Committed `vault.yml` files must decrypt with the
`ANSIBLE_VAULT_PASSWORD` secret if you set one, and are replaced by an empty mapping if not
([Encrypted secrets](#encrypted-secrets-optional)). That job fails until `inventory/hosts.yml` is committed. It
installs the newest releases the floors allow, so a collection release whose playbooks
no longer load fails your next PR. What a role makes of your variables (a renamed or
newly required one) only a run shows: dry-run with `--check --diff` after an upgrade.

## Upgrade

The floors in `requirements.yml` are the newest tagged release of each collection when
this directory was copied, so a fresh install takes the newest anyway. (A floor is
raised when its release is tagged, a little before Galaxy publishes it: if the install
cannot find that version, lower the floor to the newest one on Galaxy.) Once the fleet runs,
pin exact versions (`==X.Y.Z`) and raise them deliberately: read each collection's
[CHANGELOG](https://github.com/decdn/devops/tree/main/ansible/galaxy) (a release can
move the default decdn or sponsord release line, or roll out host changes), then
`ansible-galaxy collection install -r requirements.yml -p collections --upgrade` and
dry-run before deploying.
