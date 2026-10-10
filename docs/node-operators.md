# Node operators

You run deCDN **cache nodes**: you bond stake, serve the content clients ask for, and are
paid per megabyte. You hold no content of your own. A miss is filled from other nodes,
and an origin is the canonical source. The cache role is permissionless: any bonded
operator may re-serve any blob it holds
([ADR 001](https://github.com/decdn/decdn/blob/main/adr/001-network.md),
[ADR 002 § Publisher Identity and Namespaces](https://github.com/decdn/decdn/blob/main/adr/002-content-addressing.md#publisher-identity-and-namespaces)).

If you publish content and run its origins, read [`publishers.md`](publishers.md)
instead.

## What you deploy

One service per host: `decdn-node`, with no origin backend. Every path deploys it the same
way: a non-root daemon, public QUIC on **udp/4433**, metrics and the admin RPC on
loopback, and the chain's contract addresses taken from upstream's deployment manifest.

| Path | Start here | Entry point |
|------|------------|-------------|
| **Ansible** (VMs, bare metal, a fleet) | [`ansible/README.md`](../ansible/README.md) | `inventory/hosts-node.yml.example`, `make deploy-node` (`playbooks/node.yml`) |
| **cloud-init** (one VM, no control machine) | [`cloud-init/README.md`](../cloud-init/README.md) | `cloud-init/user-data-node.yaml` |
| **Docker Compose** (one Docker host) | [`compose/README.md`](../compose/README.md) | `decdn-compose init node` |
| **Helm** (Kubernetes, one release per node) | [`charts/decdn-node/README.md`](../charts/decdn-node/README.md) | the chart, with no `config.cache.origin` |

[`requirements.md`](requirements.md) has the hardware, network and platform requirements,
and compares the paths. The Galaxy collection for your own playbooks is
[`decdn.node`](../ansible/galaxy/node/README.md).

A node without an origin backend fills a miss by pulling from other nodes
(`node_to_node_pull_through_enabled`). The Ansible role and the chart turn that on for
you, and so does `decdn-compose init node` on Compose; the daemon's default is off. A pull is paid
from the node's own PaymentPool (the node-to-node tier of
[ADR 003](https://github.com/decdn/decdn/blob/main/adr/003-payments.md)), so the node
fronts USDC for its misses. `buyer_working_deposit_micro_usdc` is not a cap: it is the
deposit the pool opens with and the balance every top-up refills it to, so keep the
node's wallet funded for as long as it pulls.

## Before it earns

The node serves paid traffic only after its on-chain stake and registration
([ADR 019, Phase 2](https://github.com/decdn/decdn/blob/main/adr/019-node-onboarding.md#phase-2--on-chain-setup)).
That is your step on every path: upstream's `decdn setup` walks it end to end, and
[`lifecycle.md`](lifecycle.md#running-on-chain-commands) shows how to run it on each
path. This repository stops at host preparation and startup.

## Day 2

- Backups, restores, host migration and decommissioning: [`lifecycle.md`](lifecycle.md).
- Dashboards and alert rules: [`monitoring/`](../monitoring/README.md). Grafana Cloud
  shipping is opt-in on Ansible (`decdn_grafana_cloud_enabled`).
- Relays and discovery: a node uses n0's iroh relays and DNS discovery by default. To
  move to self-hosted ones, set `decdn_relay_urls` and the `decdn_discovery_*` knobs on
  Ansible (`network.relay_urls` and `[network.discovery]` in `node.toml` or the chart's
  `config`). Two caveats ([`iroh_relay`](../ansible/roles/iroh_relay/README.md),
  [`iroh_dns_server`](../ansible/roles/iroh_dns_server/README.md)):
  a publisher's relay admits only listed node IDs by default, so ask for yours to be
  added; and your own discovery settings drop the n0 leg, so clients must use the same
  `dns_origin` to find your node.
