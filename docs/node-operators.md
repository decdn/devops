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
| **Docker Compose** (one Docker host), recommended | [`compose/README.md`](../compose/README.md) | `decdn-compose init node` |
| **Ansible** (VMs, bare metal, a fleet) | [below](#deploy-with-ansible-from-galaxy), [`ansible/README.md`](../ansible/README.md) | `ansible/inventory/hosts-node.yml.example`, `ansible-playbook decdn.node.node` (or `make deploy-node` from a clone) |
| **cloud-init** (one VM, no control machine) | [`cloud-init/README.md`](../cloud-init/README.md) | `cloud-init/user-data-node.yaml` |
| **Helm** (Kubernetes, one release per node) | [`charts/decdn-node/README.md`](../charts/decdn-node/README.md) | `oci://ghcr.io/decdn/charts/decdn-node`, with no `config.cache.origin` |

[`requirements.md`](requirements.md) has the hardware, network and platform requirements,
and compares the paths.

A node without an origin backend fills a miss by pulling from other nodes
(`node_to_node_pull_through_enabled`). The Ansible role and the chart turn that on for
you, and so does `decdn-compose init node` on Compose; the daemon's default is off. A pull is paid
from the node's own PaymentPool (the node-to-node tier of
[ADR 003](https://github.com/decdn/decdn/blob/main/adr/003-payments.md)), so the node
fronts USDC for its misses. `buyer_working_deposit_micro_usdc` is not a cap: it is the
deposit the pool opens with and the balance every top-up refills it to, so keep the
node's wallet funded for as long as it pulls.

## Deploy with Ansible from Galaxy

The roles and the node playbooks are the
[`decdn.node`](../ansible/galaxy/node/README.md) collection on
[Ansible Galaxy](https://galaxy.ansible.com/ui/repo/published/decdn/node/), so you run
them from a private repository that holds only your inventory. Set it up once with the
[root README's quickstart](../README.md#quickstart-ansible-from-galaxy) (it clones this
repository only to copy [`examples/collection-fleet/`](../examples/collection-fleet/README.md)
and the inventory templates), then:

```bash
ansible-playbook decdn.node.node -l <host> -u root        # a fresh host's first run (or -u ubuntu, …)
ansible-playbook decdn.node.node -l <host> --check --diff # dry run
ansible-playbook decdn.node.node -l <host>                # deploy or update
ansible-playbook decdn.node.backup -l <host>              # encrypted identity backup, to backups/
ansible-playbook decdn.node.decommission -l <host>        # asks you to type the host; removes the node, keeps its keys
```

Without `-l`, a dry run, deploy or backup covers every cache node in the inventory;
decommission refuses more than `decdn_decommission_max_hosts` hosts (default 1). A
backup needs your public key in `decdn_backup_age_recipients`
([`lifecycle.md`](lifecycle.md#backup-make-backup)). Every `make` target in the docs,
and what the Makefile checks that a plain `ansible-playbook` run does not:
[From `make` to `ansible-playbook`](../examples/collection-fleet/README.md#from-make-to-ansible-playbook).
You can also call the roles from your own playbooks.

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
