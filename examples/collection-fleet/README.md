# A deCDN fleet from the Galaxy collections

A starting point for a **private** repository that deploys deCDN from the
[`decdn.node`](../../ansible/galaxy/node/README.md) and
[`decdn.publisher`](../../ansible/galaxy/publisher/README.md) collections alone: the
collections bring the roles and the playbooks (firewall holes, placement checks and
lifecycle guards included), and this repository holds only your inventory.

| File | What it is |
|------|------------|
| `requirements.yml` | the collections, from Ansible Galaxy (delete `decdn.publisher` for cache nodes only) |
| `ansible.cfg` | this repo's `ansible/ansible.cfg`, minus `roles_path` |
| `.gitignore` | keeps the installed collections, per-host secrets and backups out of git |

## Set up

Copy this directory into a new private repository, then add an inventory, starting
from this repository's examples:

```bash
ansible-galaxy collection install -r requirements.yml -p collections
mkdir -p inventory
cp <devops>/ansible/inventory/hosts-node.yml.example inventory/hosts.yml   # or hosts-publisher.yml.example
cp -R <devops>/ansible/inventory/group_vars <devops>/ansible/inventory/host_vars inventory/
```

Fill in `inventory/hosts.yml` and its `group_vars/` and `host_vars/` (each file says
what it needs; [`ansible/README.md`](../../ansible/README.md) has the variables and the
on-host secrets). Rename `host_vars/decdn-node-1/` (and `origin-1/`) to your hosts, and
keep secrets in the git-ignored `host_vars/<host>/secret.yml` (copied from its
`secret.yml.example`). The copied files name this repository's make targets:
[From `make` to `ansible-playbook`](#from-make-to-ansible-playbook) translates them.

## Run

```bash
ansible-playbook decdn.node.node -l <host> -u root          # first converge only; swap root for your image's bootstrap user
ansible-playbook decdn.node.node --check --diff -l <host>   # dry run
ansible-playbook decdn.node.node -l <host>                  # cache nodes
ansible-playbook decdn.publisher.site                       # everything in the inventory
ansible-playbook decdn.node.backup -l <host>                # fetched to backups/, beside ansible.cfg
ansible-playbook decdn.node.decommission -l <host>          # decdn.publisher.decommission on a host with publisher services
```

### From `make` to `ansible-playbook`

The docs elsewhere use this repository's make targets. Here, each is one
`ansible-playbook` command, run from this directory (`ansible.cfg` points at
`inventory/hosts.yml`, so no `-i`):

| In `decdn/devops/ansible/` | Here |
|----------------------------|------|
| `make check-node LIMIT=<host>` | `ansible-playbook decdn.node.node -l <host> --check --diff` |
| `make deploy-node LIMIT=<host>` | `ansible-playbook decdn.node.node -l <host>` |
| `make deploy LIMIT=<host>` | `ansible-playbook decdn.publisher.site -l <host>` |
| `make deploy-publisher LIMIT=<host>` | `ansible-playbook decdn.publisher.publisher -l <host>` |
| `make deploy-origin LIMIT=<host>` | `ansible-playbook decdn.publisher.origin -l <host>` |
| `make deploy-sponsord LIMIT=<host>` | `ansible-playbook decdn.publisher.sponsord -l <host>` |
| `make deploy-relay LIMIT=<host>` | `ansible-playbook decdn.publisher.iroh_relay -l <host>` |
| `make deploy-dns LIMIT=<host>` | `ansible-playbook decdn.publisher.iroh_dns_server -l <host>` |
| `make backup LIMIT=<host>` | `ansible-playbook decdn.node.backup -l <host>` (`decdn.publisher.backup` also covers sponsord) |
| `make decommission LIMIT=<host>` | `ansible-playbook decdn.node.decommission -l <host>` (`decdn.publisher.decommission` on a host with publisher services) |
| `ANSIBLE_ARGS='-u root -e x=y'` | `-u root -e x=y`, plain options |

Any `check` target is the same command with `--check --diff`.

The collection READMEs list every playbook and what it runs. Unlike this repository's
Makefile, nothing here refuses a run without `-l`: scope deploys and every
decommission yourself (decommission refuses more than `decdn_decommission_max_hosts`
hosts, default 1).

## Upgrade

Raise the versions in `requirements.yml` (pin `==X.Y.Z` once the fleet runs), read
each collection's CHANGELOG, then `ansible-galaxy collection install -r
requirements.yml -p collections --upgrade` and dry-run before deploying.
