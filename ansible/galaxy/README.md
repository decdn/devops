# Ansible Collection — `decdn.node`

Deploy and harden a **public [deCDN](https://decdn.org) node**. This collection is
the public, reusable slice of the [`decdn/devops`](https://github.com/decdn/devops)
repository — two roles and nothing else:

| Role | Purpose |
|------|---------|
| `decdn.node.baseline` | Debian host baseline — nftables default-deny inbound, fail2ban, unattended-upgrades, chrony, an admin sudo user, then DevSec OS + SSH hardening (applied last). |
| `decdn.node.decdn_node` | The `decdn-node` daemon — installed from a pinned GitHub Release tarball under a hardened systemd unit; public QUIC udp/4433, loopback metrics + admin RPC. |

> The repo's internal team tooling (the anvil devnet — `anvil`, `caddy`, `contracts`
> roles) is **not** part of this collection.

## Requirements

- **ansible-core ≥ 2.15** on the control machine.
- Target: **Debian (bookworm)** or **Ubuntu (jammy/noble)** over SSH with a sudo user.
- Collection dependencies (installed automatically with this collection):
  `devsec.hardening (>=10.0.0)`, `ansible.posix (>=1.5.0)`.

## Install

```bash
ansible-galaxy collection install decdn.node
```

Or pin it in a `requirements.yml`:

```yaml
collections:
  - name: decdn.node
    version: ">=0.1.0"
```

## Usage

A minimal node playbook — baseline first (so the admin key lands before SSH
hardening), then the node:

```yaml
- name: Provision a hardened deCDN node
  hosts: decdn_nodes
  become: true
  roles:
    - role: decdn.node.baseline
      vars:
        ssh_admin_user: deploy
        ssh_admin_pubkey: "ssh-ed25519 AAAA... you@host"   # REQUIRED — lockout guard
        baseline_extra_inbound:
          - { proto: udp, port: 4433, comment: "deCDN QUIC" }
    - role: decdn.node.decdn_node
      # decdn_node_version + rpc_url + the three contract addresses + region are
      # REQUIRED — set them per host (host_vars). Contract addresses/chain-id are
      # protocol facts: source them from the deployment / an ADR, never guess.
```

The node serves paid traffic only **after** on-chain stake + registration — an
operator step, not automated by this collection. See each role's README for the
full variable list, the eth-keystore prerequisite, and day-2 ops:

- [`roles/baseline`](https://github.com/decdn/devops/tree/main/ansible/roles/baseline)
- [`roles/decdn_node`](https://github.com/decdn/devops/tree/main/ansible/roles/decdn_node)

## Security model

Backends bind `127.0.0.1`; the node opens exactly one public hole (QUIC udp/4433).
No secrets ship in the collection or are committed — the eth keystore is
operator-provisioned on the host, and `rpc_url` (which may embed an API key) renders
to a `0600` file. SSH hardening is applied last, after the admin key is in place, so
you cannot lock yourself out.

## License

MIT © deCDN Contributors. Protocol facts trace to the deCDN ADRs, never invented here.
