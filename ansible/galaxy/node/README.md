# Ansible Collection — `decdn.node`

Deploy and harden a **public [deCDN](https://decdn.org) node**: what a **node
operator** runs, and the origin nodes a **publisher** runs. This collection is part of
the public, reusable slice of the [`decdn/devops`](https://github.com/decdn/devops)
repository: three roles, and the playbooks that deploy, back up and decommission
nodes with them (see [Usage](#usage)). A publisher's other services (the
`sponsord` sponsor and its onramp, an iroh relay, an iroh DNS server) are the
[`decdn.publisher`](https://github.com/decdn/devops/tree/main/ansible/galaxy/publisher)
collection, which depends on this one.

| Role | Purpose |
|------|---------|
| `decdn.node.baseline` | Debian/Ubuntu host baseline — nftables default-deny inbound, fail2ban, unattended-upgrades, chrony, an admin sudo user, then DevSec OS + SSH hardening (applied last). |
| `decdn.node.decdn_node` | The `decdn-node` daemon (a cache node, or an origin with `decdn_cache_origin_kind` / `decdn_cache_origins`) under a hardened systemd unit — from a GPG-verified release tarball (the default), a build on the host from a git ref, or locally built binaries; public QUIC udp/4433, loopback metrics + admin RPC. `decdn_network` sets the chain from upstream's manifest; `tasks_from: backup` / `decommission` for day 2. |
| `decdn.node.grafana_alloy` | Opt-in Grafana Cloud observability agent — loopback-only Alloy receiver and hardened telemetry export; scrapes the node, `sponsord`, or both (`grafana_alloy_node_enabled` / `grafana_alloy_sponsord_enabled`), labels the onramp's journal (`grafana_alloy_sponsord_onramp_enabled`), and scrapes an iroh relay (`grafana_alloy_iroh_relay_enabled`) and an iroh DNS server (`grafana_alloy_iroh_dns_server_enabled`). |

## Requirements

- **ansible-core ≥ 2.15** on the control machine.
- Target: **Debian 12/13** or **Ubuntu 24.04/26.04**, x86_64 or aarch64, over SSH with a
  sudo user. Facts must be gathered (the node role derives the release target from
  the host architecture), or set `decdn_node_target` explicitly.
- Collection dependencies (installed automatically with this collection):
  `devsec.hardening (>=10.0.0)`, `ansible.posix (>=1.5.0)`.

## Install

From [Ansible Galaxy](https://galaxy.ansible.com/ui/repo/published/decdn/node/):

```bash
ansible-galaxy collection install decdn.node
```

Or pin it in a `requirements.yml`:

```yaml
collections:
  - name: decdn.node
    version: ">=0.2.0"     # the first release with the playbooks
```

Each release is listed in the
[CHANGELOG](https://github.com/decdn/devops/blob/main/ansible/galaxy/node/CHANGELOG.md)
and as a `node-collection-vX.Y.Z`
[GitHub Release](https://github.com/decdn/devops/releases) with the tarball and its
`SHA256SUMS`. To run changes not released yet, build it from a checkout. The build
carries the last release's version until the next one, so `--force` replaces an
installed release:

```bash
git clone https://github.com/decdn/devops && cd devops/ansible
make build-node
ansible-galaxy collection install --force build/decdn-node-*.tar.gz
```

## Usage

### The shipped playbooks

The collection ships the node playbooks `decdn/devops` deploys its own fleets with
([`ansible/playbooks/`](https://github.com/decdn/devops/tree/main/ansible/playbooks)),
roles qualified:

| Playbook | Runs |
|----------|------|
| `decdn.node.node` | `decdn_nodes` outside `decdn_origin_nodes`: baseline, then Grafana Alloy (opt-in, off by default), then the node |
| `decdn.node.backup` | an encrypted backup of each node's identity (or, with `-e decdn_backup_scope=full`, its state), one node at a time |
| `decdn.node.decommission` | stops the node and removes its unit, then the Alloy agent, after one typed confirmation of the run's hosts; keeps the keys, never touches the chain |

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/hosts.yml decdn.node.node --check --diff
ansible-playbook -i inventory/hosts.yml decdn.node.node
ansible-playbook -i inventory/hosts.yml decdn.node.decommission -l <host>
```

Start the inventory from
[`hosts-node.yml.example`](https://github.com/decdn/devops/blob/main/ansible/inventory/hosts-node.yml.example)
and the `group_vars/` and `host_vars/` beside it. The playbooks open the node's QUIC
port in the baseline firewall themselves (`baseline_extra_inbound`, from their own
`group_vars/`, which ship beside them), and `decommission` refuses more hosts than
`decdn_decommission_max_hosts` (default 1).

- **Overrides.** The playbooks' `group_vars/decdn_nodes.yml` sets
  `baseline_extra_inbound`, and playbook group vars beat every inventory group var:
  change it per host, in `host_vars` (or with `-e`). The Alloy toggles come from their
  `group_vars/all.yml`, which beats the inventory's `group_vars/all.yml` and group vars
  written inline in `hosts.yml` but not its `group_vars/<group>.yml` or `host_vars`.
  Importing a shipped playbook from one of your own changes none of this: its plays
  read the collection's `group_vars/`, not those beside your playbook.
- **Backups.** `decdn.node.backup` fetches each identity archive to `backups/` beside
  your project's `ansible.cfg` (never into the installed collection). Without a
  project `ansible.cfg`, set `decdn_backup_local_dir`.
- **Scope.** The repository's Makefile guards (a `LIMIT` preflight, a required `LIMIT`
  for decommission) do not ship: scope a run with `-l` yourself.
- **Publisher hosts.** A publisher's origin nodes, sponsord, relays and DNS servers
  are `decdn.publisher`'s playbooks. Decommission a host that also runs one of them
  with `decdn.publisher.decommission`: `decdn.node.decommission` would tear down the
  Alloy agent they share and leave them running.

### Your own playbook

To compose the roles yourself, a minimal node playbook — baseline first (so the admin
key lands before SSH hardening), then the node:

```yaml
- name: Provision a hardened deCDN node
  hosts: decdn_nodes
  become: true
  roles:
    - role: decdn.node.baseline
      vars:
        baseline_sudo_users:                               # REQUIRED — lockout guard
          - name: deploy
            keys: ["ssh-ed25519 AAAA... you@host"]
        baseline_sudo_autodetect_runner: false             # provision only the explicit admin above
        baseline_extra_inbound:
          - { proto: udp, port: 4433, comment: "deCDN QUIC" }
    - role: decdn.node.decdn_node
      vars:
        decdn_network: arbitrum-sepolia   # chain_id + every contract address, from upstream's manifest
      # Also REQUIRED per host (host_vars): decdn_region, the binaries (nothing
      # for the default release method, which installs the pinned
      # decdn_node_version; decdn_node_install_method: source +
      # decdn_node_source_ref, or manual + decdn_release_target_dir), and the RPC URL (host-provisioned
      # /etc/decdn/decdn.env, or decdn_rpc_url in a git-ignored secret.yml).
```

The node serves paid traffic only **after** on-chain stake + registration — an
operator step, not automated by this collection. See each role's README for the
full variable list, the eth-keystore prerequisite, and day-2 ops:

- [`roles/baseline`](https://github.com/decdn/devops/tree/main/ansible/roles/baseline)
- [`roles/decdn_node`](https://github.com/decdn/devops/tree/main/ansible/roles/decdn_node)
- [`roles/grafana_alloy`](https://github.com/decdn/devops/tree/main/ansible/roles/grafana_alloy)

## Security model

Backends bind `127.0.0.1`; the node opens exactly one public hole (QUIC udp/4433),
an origin node included. The publisher-side services open their own; see
`decdn.publisher`'s README.
No secrets ship in the collection or are committed — the eth keystore is
operator-provisioned on the host, and `rpc_url` (which may embed an API key) renders
to a `0600` file. SSH hardening is applied last, after the admin key is in place, so
you cannot lock yourself out.

## License

MIT © deCDN Contributors. Protocol facts trace to the deCDN ADRs, never invented here.
