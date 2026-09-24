# Requirements and choosing a deploy path

What a deCDN node needs from its host and network, and which of this repo's four
deploy paths fits. Protocol facts (bond sizing, fees) are not here: they come from the
deCDN ADRs.

## Choosing a path

| | Ansible | cloud-init | Docker Compose | Helm |
|---|---|---|---|---|
| Target | VMs, bare metal | one cloud VM, no control machine | one host running Docker | Kubernetes |
| Host hardening (firewall, SSH, patching) | yes, `baseline` | yes, `baseline` | no, yours | no, the cluster's |
| Fleets | yes, one inventory | one user-data per VM | one host per compose project | one release per node |
| Secrets | host file or git-ignored inventory | host file, written over SSH | host file | operator-created Secrets |
| Install source | signed release tarball, or local build | signed release tarball | image by digest (enforced) | image by digest (recommended) or tag |
| Chain config | `decdn_network` profile | `decdn_network` profile | `decdn config init --chain` | explicit values |
| Monitoring | opt-in Grafana Cloud agent | opt-in Grafana Cloud agent (token in a host file) | bring your own | ServiceMonitor, PrometheusRule, dashboards |
| Backup / decommission | `make backup` / `make decommission` | the Ansible targets, from a workstation inventory | manual commands | PVC snapshot |
| Guide | [ansible/README.md](../ansible/README.md) | [cloud-init/README.md](../cloud-init/README.md) | [compose/README.md](../compose/README.md) | [charts/decdn-node/README.md](../charts/decdn-node/README.md) |

If you are unsure: a VPS or dedicated server you control end to end is the Ansible
path, or cloud-init for a single VM when you would rather not run Ansible from a
workstation. They are the only two that harden the host as well as installing the node,
and they run the same roles.

## Platforms

| | Supported | How it is tested |
|---|---|---|
| OS | Debian 12 (bookworm), Debian 13 (trixie), Ubuntu 24.04 (noble), Ubuntu 26.04 (resolute) | molecule converges `decdn_node` on all four in systemd containers; `grafana_alloy`'s install path on Debian 12 only (its disabled path on all four); `baseline` on real hosts |
| Architecture | x86_64, aarch64 | upstream builds both; the Ansible role derives the target from the host |
| Ansible (control machine) | ansible-core ≥ 2.15 | CI runs the current release |
| cloud-init | the provider image's own; the bootstrap installs its pinned ansible-core on the host | the user-data is booted with the distro's cloud-init in Debian 12 and Ubuntu 26.04 containers, to a running node |
| Kubernetes | ≥ 1.25 | rendered and validated with kubeconform against 1.30 |
| Docker Compose | v2 with `env_file.required` support (2.24+) | rendered in CI |

On Ubuntu 25.10 and later, `sudo` is sudo-rs; see the `ansible_become_exe` note in
`ansible/inventory/hosts.yml.example`.

## Network

- **Inbound: udp/4433 (QUIC)** from anywhere. This is the node's only public port. Open
  it in the host firewall (the Ansible `baseline` does this) **and** in your cloud
  provider's security group or firewall, which the host cannot see.
- **Outbound:** HTTPS to your RPC provider and to any cache origin; QUIC/UDP to peers;
  HTTPS to the iroh relays (upstream's defaults unless you set your own).
- **NAT:** a node without direct inbound reachability still works through iroh relays,
  at a latency cost. A node that serves paid traffic should be directly reachable, and
  the multiaddr it registers on-chain must be its public address
  (`/ip4/<public-ip>/udp/4433/quic-v1`).
- **IPv6:** supported alongside IPv4. Since decdn/decdn#2144 (`869141e9`) the node's
  QUIC listener binds both `0.0.0.0:4433` and `[::]:4433`, and a dual-stack node
  registers both its `/ip4/` and `/ip6/` multiaddrs; older builds are IPv4-only on
  4433. On Ansible, `baseline_preserve_ipv6_autoconf` (default `true`) keeps SLAAC
  addresses alive under DevSec hardening; set it `false` on static-IPv6 hosts.
  Multi-homed hosts may need `baseline_rp_filter_loose: true`.
- **Loopback only, never exposed:** metrics `127.0.0.1:9090`, admin RPC
  `127.0.0.1:9191`. Reach them over SSH, or ship metrics with the monitoring options.
- **Clock:** keep NTP running (`baseline` installs chrony). `decdn setup`'s pre-flight
  checks clock skew.
- **Bandwidth:** the node serves what it is asked for. On metered bandwidth, cap egress
  with `[load_shed] egress_budget_mbps` in `node.toml`
  (`decdn_load_shed_egress_budget_mbps` on Ansible, `config.load_shed.egress_budget_mbps`
  on Helm), and set a billing alert with your provider.

## Disk

Everything lives on the data volume (`/var/lib/decdn`, or the PVC):

```
cache_size_mb                    the cache (role default 10 GiB)
+ disk_headroom_mb               free space the daemon keeps on the volume (default 8 GiB)
+ receipts                       rotated download-receipt log, bounded by its [receipts] settings
+ daemon state (redb stores)     small, grows with activity; no published bound
+ an fs origin, if the node holds one
```

`max_blob_size_mb` must be ≤ `cache_size_mb`: the node rejects any blob larger than it
(`BlobTooLarge`), so size it to the largest single object you expect to serve (role
default 1 GiB). Put `/var/lib/decdn` on the fast disk.

## CPU and memory

Upstream publishes no minimum figures yet, so this repo quotes none. Watch the node's
own metrics (`decdn node top`, the upstream dashboards) under real load and size from
that.

## Accounts and keys

- An **RPC endpoint** for the chain (Arbitrum Sepolia today). The public endpoint that
  `config init` writes works for light use; production nodes should use their own
  provider. Keep the URL secret if it embeds an API key.
- An **operator wallet**: the eth keystore `decdn key-gen` creates, funded for gas and
  the bond before `decdn setup`. The bond comes from the on-chain
  `bondRequired(mbps)` curve (ADR 026).
- Optional: a **Grafana Cloud** stack (Ansible `grafana_alloy`), and an **age key pair**
  for encrypted backups ([docs/lifecycle.md](lifecycle.md)).
