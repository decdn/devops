# Ansible Collection — `decdn.node`

Deploy and harden a **public [deCDN](https://decdn.org) node**. This collection is
the public, reusable slice of the [`decdn/devops`](https://github.com/decdn/devops)
repository — five roles and nothing else:

| Role | Purpose |
|------|---------|
| `decdn.node.baseline` | Debian/Ubuntu host baseline — nftables default-deny inbound, fail2ban, unattended-upgrades, chrony, an admin sudo user, then DevSec OS + SSH hardening (applied last). |
| `decdn.node.decdn_node` | The `decdn-node` daemon under a hardened systemd unit — from a GPG-verified release tarball (the default), a build on the host from a git ref, or locally built binaries; public QUIC udp/4433, loopback metrics + admin RPC. `decdn_network` sets the chain from upstream's manifest; `tasks_from: backup` / `decommission` for day 2. |
| `decdn.node.grafana_alloy` | Opt-in Grafana Cloud observability agent — loopback-only Alloy receiver and hardened telemetry export; scrapes the node, `sponsord`, or both (`grafana_alloy_node_enabled` / `grafana_alloy_sponsord_enabled`), and labels the onramp's journal (`grafana_alloy_sponsord_onramp_enabled`). |
| `decdn.node.sponsord` | The `sponsord` onboarding sponsor (treasury signer + PaymentPool keeper), standalone or beside a node — local binary or GPG-verified `sponsord-v*` release, `DynamicUser` unit with the API token and treasury wallet as systemd credentials, loopback-only API, `/healthz` deploy gate. `sponsord_network` sets the chain and PaymentPool from upstream's manifest. Restarts refuse while a pool top-up is held; `tasks_from: backup` / `decommission` for day 2. |
| `decdn.node.sponsord_onramp` | `sponsord-onramp`, sponsord's public side (Turnstile gate, installers, CLI API), on the daemon's host — local binary or GPG-verified `sponsord-onramp-v*` release, `DynamicUser` unit with the daemon token and Turnstile secret as systemd credentials, loopback listener behind Caddy (distro package, ACME TLS, admin API off; or your own proxy), `/healthz` deploy gate; `tasks_from: decommission`. |

## Requirements

- **ansible-core ≥ 2.15** on the control machine.
- Target: **Debian 12/13** or **Ubuntu 24.04/26.04**, x86_64 or aarch64, over SSH with a
  sudo user. Facts must be gathered (the node role derives the release target from
  the host architecture), or set `decdn_node_target` explicitly.
- Collection dependencies (installed automatically with this collection):
  `devsec.hardening (>=10.0.0)`, `ansible.posix (>=1.5.0)`.

## Install

> **Not on Galaxy yet.** The first release (`v0.1.0`) has not been cut; see
> [RELEASING.md](https://github.com/decdn/devops/blob/main/RELEASING.md). Until then,
> build and install it from a checkout:
>
> ```bash
> git clone https://github.com/decdn/devops && cd devops/ansible
> make build
> ansible-galaxy collection install build/decdn-node-*.tar.gz
> ```

Once published:

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
        baseline_sudo_users:                               # REQUIRED — lockout guard
          - name: deploy
            keys: ["ssh-ed25519 AAAA... you@host"]
        baseline_sudo_autodetect_runner: false             # provision only the explicit admin above
        baseline_extra_inbound:
          - { proto: udp, port: 4433, comment: "deCDN QUIC" }
    - role: decdn.node.decdn_node
      vars:
        decdn_network: arbitrum-sepolia   # chain_id + every contract address, from upstream's manifest
      # Also REQUIRED per host (host_vars): decdn_region, the binaries
      # (decdn_node_version for the default release method, or
      # decdn_node_install_method: source + decdn_node_source_ref, or manual +
      # decdn_release_target_dir), and the RPC URL (host-provisioned
      # /etc/decdn/decdn.env, or decdn_rpc_url in a git-ignored secret.yml).
```

The node serves paid traffic only **after** on-chain stake + registration — an
operator step, not automated by this collection. See each role's README for the
full variable list, the eth-keystore prerequisite, and day-2 ops:

- [`roles/baseline`](https://github.com/decdn/devops/tree/main/ansible/roles/baseline)
- [`roles/decdn_node`](https://github.com/decdn/devops/tree/main/ansible/roles/decdn_node)
- [`roles/grafana_alloy`](https://github.com/decdn/devops/tree/main/ansible/roles/grafana_alloy)
- [`roles/sponsord`](https://github.com/decdn/devops/tree/main/ansible/roles/sponsord)
- [`roles/sponsord_onramp`](https://github.com/decdn/devops/tree/main/ansible/roles/sponsord_onramp)

## Security model

Backends bind `127.0.0.1`; the node opens exactly one public hole (QUIC udp/4433).
`sponsord_onramp` also listens on loopback: Caddy is its public side, so a host that
runs it opens tcp/80 and tcp/443 for Caddy in `baseline_extra_inbound` (this repo's
playbooks derive that from `sponsord_onramp_hosts`; from your own playbook, add them
yourself).
No secrets ship in the collection or are committed — the eth keystore is
operator-provisioned on the host, and `rpc_url` (which may embed an API key) renders
to a `0600` file. SSH hardening is applied last, after the admin key is in place, so
you cannot lock yourself out.

## License

MIT © deCDN Contributors. Protocol facts trace to the deCDN ADRs, never invented here.
