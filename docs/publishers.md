# Publishers

You publish content on deCDN. A **publisher** is an Ethereum address that owns at least
one namespace in the `PublisherRegistry` contract. It becomes one with its first
`createNamespace()` call. Once governance has vetted you as a publisher, you seat the
operators that serve each namespace as **origins**
([ADR 002 § Publisher Identity and Namespaces](https://github.com/decdn/decdn/blob/main/adr/002-content-addressing.md#publisher-identity-and-namespaces),
[ADR 011 § Origin Assignment Authority](https://github.com/decdn/decdn/blob/main/adr/011-content-takedown.md#origin-assignment-authority)).
You take your steps with the `decdn` CLI, not with this repository
([Appendix: Binaries](https://github.com/decdn/decdn/blob/main/adr/appendix-binaries.md)):
`decdn publish namespace create`, `decdn publish assign` (`OriginAssignment.addOrigin`),
`decdn publish revoke` (`removeOrigin`), and `decdn origin import`, which writes
content into a local directory in the layout an origin reads: point an `fs` origin at
it, or sync it to an S3 bucket (the layouts are the same). It does not write to S3 or
an HTTP store itself. The vetting itself is governance's.

This repository deploys what a publisher runs. Node operators who only run cache nodes
should read [`node-operators.md`](node-operators.md) instead.

## What you deploy

| Service | What it is | Ansible group and playbook | Other paths |
|---------|------------|----------------------------|-------------|
| **Origin node** | `decdn-node` with an origin backend (S3/R2/B2/MinIO, NFS or local disk, or an HTTP store): the canonical source of your namespace's content | `decdn_origin_nodes`, a child of `decdn_nodes`; `decdn.publisher.origin` | cloud-init `user-data-publisher.yaml`; Compose `origin` profile; the Helm chart with `config.cache.origin` (an `fs` origin also needs `origin.volume`) |
| **sponsord** + **sponsord-onramp** | Pays for your users' downloads: the treasury wallet that owns a PaymentPool and signs capped capabilities for clients ([ADR 003 § Capability delegation](https://github.com/decdn/decdn/blob/main/adr/003-payments.md#capability-delegation)), and its public gate (Turnstile, installers) behind Caddy | `sponsord_hosts`, `sponsord_onramp_hosts`; `decdn.publisher.sponsord` | cloud-init `user-data-publisher.yaml`; Compose `sponsord`, `onramp`, `caddy` profiles |
| **iroh relay** | NAT-traversal fallback for peers that cannot hole-punch. Relays are operational infrastructure, not an incentivized role ([Architecture § Trust Assumptions](https://github.com/decdn/decdn/blob/main/adr/architecture.md#trust-assumptions)) | `iroh_relay_hosts`; `decdn.publisher.iroh_relay` | Compose `relay` profile |
| **iroh DNS server** | The pkarr relay and DNS server nodes publish and resolve their address records through, in place of n0's ([ADR 001 § Node Discovery](https://github.com/decdn/decdn/blob/main/adr/001-network.md#node-discovery-registry)) | `iroh_dns_server_hosts`; `decdn.publisher.iroh_dns_server` | Compose `dns` profile |

Only the origin is required.

### Deploy with Ansible from Galaxy

The roles and playbooks are the [`decdn.publisher`](../ansible/galaxy/publisher/README.md)
collection on [Ansible Galaxy](https://galaxy.ansible.com/ui/repo/published/decdn/publisher/),
which pulls in [`decdn.node`](../ansible/galaxy/node/README.md) for the baseline,
observability and the origin node itself. You run them from a private repository that
holds only your inventory. Set it up once with the
[root README's quickstart](../README.md#quickstart-ansible-from-galaxy), with two
changes:

- Start `inventory/hosts.yml` from `hosts-publisher.yml.example`. Only the origin
  (`origin-1`) is live in it: uncomment the groups you run (sponsord and its onramp,
  iroh relays, the DNS server).
- Edit `host_vars/origin-1/` rather than `decdn-node-1/`: `decdn_region`, the origin
  backend, and `decdn_node_generate_keystore: true` if the node should make its wallet.

Then:

```bash
ansible-playbook decdn.publisher.publisher -l <host> --tags baseline -u root   # a fresh host's first run (or -u ubuntu, …)
ansible-playbook decdn.publisher.publisher -l <host> --check --diff            # dry run
ansible-playbook decdn.publisher.publisher -l <host>                           # every service the inventory gives the host
ansible-playbook decdn.publisher.origin -l <host>             # or one service: an origin node
ansible-playbook decdn.publisher.sponsord -l <host>           #   sponsord and its onramp
ansible-playbook decdn.publisher.iroh_relay -l <host>         #   an iroh relay
ansible-playbook decdn.publisher.iroh_dns_server -l <host>    #   the iroh DNS server
ansible-playbook decdn.publisher.backup -l <host>             # node identity and sponsord credentials (relays and DNS servers hold nothing to back up)
ansible-playbook decdn.publisher.decommission -l <host>       # asks you to type the host; removes every service on it, keeps the keys
```

The first run is baseline only (`--tags baseline`): it creates your admin account and
turns root login off. That matters for a relay, whose full run logs into every node in
the inventory to read its ID and would try those nodes as root too. Drop `-l` to cover
every host in the inventory. The playbooks open each service's firewall holes and refuse
a host in the wrong groups. From a clone of this repository, the same runs are
`make deploy-publisher`, `deploy-origin`, `deploy-sponsord`, `deploy-relay` and
`deploy-dns` in `ansible/`;
[From `make` to `ansible-playbook`](../examples/collection-fleet/README.md#from-make-to-ansible-playbook)
maps every target and lists what the Makefile checks that a plain `ansible-playbook`
run does not.

## Origin nodes

An origin is a deCDN node like any other: it is bonded and registered
([ADR 019](https://github.com/decdn/decdn/blob/main/adr/019-node-onboarding.md)), with the
same hardening, port and day-2 tooling as a cache node. Three things differ:

- **The backend.** Set `decdn_cache_origin_kind` (`http`, `fs` or `s3`) and its fields,
  or `decdn_cache_origins` for an ordered fallback list
  ([`decdn_node` role](../ansible/roles/decdn_node/README.md)).
  S3 keys go in `/etc/decdn/decdn.env` on the host (or in `decdn_extra_env` in a
  git-ignored `secret.yml`, beside `decdn_rpc_url`), never in tracked inventory or
  user-data.
  The origin playbook (`decdn.publisher.origin`) refuses a `decdn_origin_nodes` host
  without a backend, or one outside `decdn_nodes`.
- **What it serves.** With a backend, the node fills misses from it rather than from
  other nodes. By default it serves only what its own backend holds and declines
  everything else, even a blob already in its cache (`relay_foreign_namespaces`,
  [ADR 002 § Retrieval by namespace](https://github.com/decdn/decdn/blob/main/adr/002-content-addressing.md#retrieval-by-namespace),
  [ADR 037 § Warming is a relay-edge mechanism](https://github.com/decdn/decdn/blob/main/adr/037-regional-proxy-warming.md#warming-is-a-relay-edge-mechanism)).
  The gate is the backend's content, not the namespace's on-chain assignment.
- **Recognition is on-chain.** As the namespace's publisher, you seat the node's operator
  with `decdn publish assign` (`OriginAssignment.addOrigin`). Configuring a backend without that only means the
  node's bytes are served as cache
  ([Architecture § Origin Backends](https://github.com/decdn/decdn/blob/main/adr/architecture.md#origin-backends)).
  Multiple operators may serve one namespace, so run more than one origin for
  redundancy.

## Relays and the DNS server

A node's `decdn_relay_urls` replaces n0's relays, so deploy at least two relays before
pointing nodes at them. By default a relay admits only the nodes in the same inventory
(`iroh_relay_access: allowlist`): it reads their IDs from `decdn_nodes`, your origins
included. Other operators' nodes need their IDs in `iroh_relay_allowlist`, or
`everyone`. Clients can never be listed (they use a fresh key per fetch), so a node
behind NAT that serves clients needs its relays in `everyone` mode. The DNS server has
no replication: each DNS origin (`dns_origin`) is served by exactly one server, a single
point of failure for pkarr lookups. Give every node and client that uses it the same
`dns_origin`. Both roles' READMEs have the
details: [`iroh_relay`](../ansible/roles/iroh_relay/README.md),
[`iroh_dns_server`](../ansible/roles/iroh_dns_server/README.md).

## Day 2

Upgrades: the roles pin a release line for decdn/decdn (`decdn_node_version`) and for
decdn/sponsord (`sponsord_version` = `sponsord_onramp_version`), and each deploy installs
the line's newest release; the onramp also serves its installers the newest decdn of
the line (`sponsord_onramp_decdn_release`). Set an exact `"X.Y.Z"` (for the installers,
a `vX.Y.Z` tag with its `SHA256SUMS` digest) to hold a host on one release. Origin nodes
on the chart and Compose follow the node operators' notes
([`node-operators.md`](node-operators.md#day-2)).

[`lifecycle.md`](lifecycle.md) covers backup, restore, migration and decommission for
every service above. Decommissioning an origin stops the node but leaves its operator
seated on-chain, where `OriginAssignment.getOrigins` still lists it. Unseat it with
`decdn publish revoke` (`OriginAssignment.removeOrigin`); once the operator leaves
`CapacityBond`'s active set (it deregisters, unbonds or is ejected), anyone may also
prune it as inactive
([ADR 011 § Origin Assignment Authority](https://github.com/decdn/decdn/blob/main/adr/011-content-takedown.md#origin-assignment-authority)).
