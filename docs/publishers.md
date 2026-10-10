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
`decdn publish revoke` (`removeOrigin`), and `decdn origin import` to seed an origin's
store. The vetting itself is governance's.

This repository deploys what a publisher runs. Node operators who only run cache nodes
should read [`node-operators.md`](node-operators.md) instead.

## What you deploy

| Service | What it is | Ansible group and playbook | Other paths |
|---------|------------|----------------------------|-------------|
| **Origin node** | `decdn-node` with an origin backend (S3/R2/B2/MinIO, NFS or local disk, or an HTTP store): the canonical source of your namespace's content | `decdn_origin_nodes`, a child of `decdn_nodes`; `playbooks/origin.yml` | cloud-init `user-data-publisher.yaml`; Compose `origin` profile; the Helm chart with `config.cache.origin` |
| **sponsord** + **sponsord-onramp** | Pays for your users' downloads: the treasury wallet that owns a PaymentPool and signs capped capabilities for clients ([ADR 003 § Capability delegation](https://github.com/decdn/decdn/blob/main/adr/003-payments.md#capability-delegation)), and its public gate (Turnstile, installers) behind Caddy | `sponsord_hosts`, `sponsord_onramp_hosts`; `playbooks/sponsord.yml` | cloud-init `user-data-publisher.yaml`; Compose `sponsord`, `onramp`, `caddy` profiles |
| **iroh relay** | NAT-traversal fallback for peers that cannot hole-punch. Relays are operational infrastructure, not an incentivized role ([Architecture § Trust Assumptions](https://github.com/decdn/decdn/blob/main/adr/architecture.md#trust-assumptions)) | `iroh_relay_hosts`; `playbooks/iroh_relay.yml` | Ansible only |
| **iroh DNS server** | The pkarr relay and DNS server nodes publish and resolve their address records through, in place of n0's ([ADR 001 § Node Discovery](https://github.com/decdn/decdn/blob/main/adr/001-network.md#node-discovery-registry)) | `iroh_dns_server_hosts`; `playbooks/iroh_dns_server.yml` | Ansible only |

Only the origin is required. With Ansible, start from
`ansible/inventory/hosts-publisher.yml.example`; `make deploy-publisher`
(`playbooks/publisher.yml`) deploys all four in that order, and each has its own target
(`deploy-origin`, `deploy-sponsord`, `deploy-relay`, `deploy-dns`). The roles also ship as
the [`decdn.publisher`](../ansible/galaxy/publisher/README.md) Galaxy collection, which
depends on [`decdn.node`](../ansible/galaxy/node/README.md) for the baseline, observability
and the origin node itself.

## Origin nodes

An origin is a deCDN node like any other: it is bonded and registered
([ADR 019](https://github.com/decdn/decdn/blob/main/adr/019-node-onboarding.md)), with the
same hardening, port and day-2 tooling as a cache node. Three things differ:

- **The backend.** Set `decdn_cache_origin_kind` (`http`, `fs` or `s3`) and its fields,
  or `decdn_cache_origins` for an ordered fallback list (`roles/decdn_node/README.md`).
  S3 keys go in `/etc/decdn/decdn.env` on the host, never in inventory or user-data.
  `playbooks/origin.yml` refuses a `decdn_origin_nodes` host without a backend, or one
  outside `decdn_nodes`.
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
details: `roles/iroh_relay/README.md`, `roles/iroh_dns_server/README.md`.

## Day 2

[`lifecycle.md`](lifecycle.md) covers backup, restore, migration and decommission for
every service above. Decommissioning an origin stops the node but leaves its operator
seated on-chain, where `OriginAssignment.getOrigins` still lists it. Unseat it with
`decdn publish revoke` (`OriginAssignment.removeOrigin`); once the operator deregisters,
anyone may also prune it as inactive
([ADR 011 § Origin Assignment Authority](https://github.com/decdn/decdn/blob/main/adr/011-content-takedown.md#origin-assignment-authority)).
