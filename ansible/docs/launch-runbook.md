# Launch fleet runbook

The ops sequence for putting the launch fleet up with this project. The plan it
serves, with targets, owners and dates, is `Launch/fleet-plan.md` in the private
`decdn/internal` repo. This file records only the mechanics. Protocol and economic
facts (bond sizing, fees) come from the deCDN ADRs; nothing here restates them.

## 0. Inventory

1. Copy [`inventory/fleet.example/`](../inventory/fleet.example/hosts.yml) into a
   **private** repo or dir (see [README § Private fleet inventory](../README.md#private-fleet-inventory)).
   Never commit real IPs to this public repo.
2. For each host set `ansible_host` and `decdn_region`, then put it in exactly one
   **role** group (`decdn_seed` / `decdn_edge`) and one **billing** group
   (`decdn_metered` / `decdn_unmetered`). Hero and wow-factor traffic belongs on
   unmetered nodes.
3. In `group_vars/decdn_nodes.yml`, fill the MUST-EDIT lines: binary source and
   contract addresses copied verbatim from `decdn/contracts/deployments/421614.json`.
   Size `decdn_cache_size_mb` to each host's disk.
4. Provision each node's secret on the host, the preferred way (`0600 /etc/decdn/decdn.env`,
   [roles/decdn_node/README.md § Secrets](../roles/decdn_node/README.md#secrets)).
   Provision the keystore too, or set `decdn_node_generate_keystore: true`.
5. For every metered node, set a **billing alert** in the provider console (Hetzner /
   OVHcloud). `decdn_load_shed_egress_budget_mbps` caps throughput, and the alert makes
   the spend visible.

## 1. Deploy

```bash
cd ansible
make deps
INV=../../decdn-fleet/hosts.yml                               # your private overlay
make check  INVENTORY=$INV LIMIT=<host> ANSIBLE_ARGS='-u root'   # first converge: bootstrap user
make deploy INVENTORY=$INV LIMIT=<host> ANSIBLE_ARGS='-u root'
make deploy INVENTORY=$INV                                    # every run after bootstrap, fleet-wide
```

The role runs `decdn config validate` against the installed binary after templating,
so a key the binary doesn't know fails the deploy instead of crash-looping the node.

## 2. Stake and register each node (manual)

On-chain onboarding ([ADR 019](https://github.com/decdn/decdn/blob/main/adr/019-node-onboarding.md)
Phase 2) is an operator step, not automated here. Fund the node's eth address first
(`key-gen` printed it). Then run `decdn setup` on the node. It reads the rendered
config plus `DECDN_RPC_URL` from `decdn.env`, and `systemd-run` loads that file with
the same parser the node's unit uses, so the RPC key never lands in argv:

```bash
# Preview first: pre-flight checks and the bond it would post, no transactions.
sudo systemd-run --pty --wait --collect -p User=decdn \
  -p EnvironmentFile=/etc/decdn/decdn.env \
  /usr/local/bin/decdn --config /etc/decdn/node.toml setup \
  --mbps <declared-capacity> --region <same code as decdn_region> \
  --multiaddr /ip4/<public-ip>/udp/4433/quic-v1 \
  --keystore-password-file /etc/decdn/keystore.password --dry-run
# Then the same command without --dry-run. It shows the operator terms and the bond to confirm.
```

- `--region` is the on-chain `regionHint` ([ADR 030](https://github.com/decdn/decdn/blob/main/adr/030-node-region-self-attestation.md)).
  It must match the host's `decdn_region`, since the stats map and takedown scope read it.
- The bond is read from the on-chain `bondRequired(mbps)` curve
  ([ADR 026](https://github.com/decdn/decdn/blob/main/adr/026-tokenomics.md)). Declare
  `--mbps` for what the node can really serve; there's no flat minimum to quote.
- The flags, the `node bond` / `node register` primitives and the exit path are in
  [roles/decdn_node/README.md § On-chain onboarding](../roles/decdn_node/README.md#on-chain-onboarding).

A node counts toward launch metrics only once it is registered and serving.

## 3. Seed the catalogue (seed nodes)

On each `decdn_seed` host, run `Launch/seed-model.sh` (from `decdn/internal`) as the
service user, writing into the fs origin that group_vars configure:

```bash
sudo -u decdn OUT_DIR=/var/lib/decdn/origin ./seed-model.sh
```

It needs the `hf` CLI and disk for **both** the origin copy and the cache, on the same
`/var/lib/decdn` volume. With the template values that's about 352 GiB of origin (the
current whole-repo set, measured 2026-09-22), plus `decdn_cache_size_mb` (400 GiB), plus
`decdn_disk_headroom_mb` (8 GiB): **about 760 GiB per seed**. `hf download` also stages
a full copy before import, so allow for the largest model (~177 GiB, Mixtral) on top
while seeding, or lower the seeds' `decdn_cache_size_mb` in `group_vars/decdn_seed.yml`.
Record every BLAKE3 hash it prints: the bundle manifests plus the large blobs.

## 4. Pin and fill the edges

1. Add the recorded hashes (lowercase 64-hex, no `b3:` prefix) to
   `decdn_pinned_hashes` in the overlay's `group_vars/decdn_nodes.yml`, then
   `make deploy INVENTORY=$INV`.
2. A pin only stops eviction. Each edge still fetches a blob on its first miss, and
   it's launch-ready once the blob is resident on enough nodes per region.

## 5. Verify: the fleet part of the go/no-go

- From a cold machine near each region, pull the **largest** blob (currently the
  13.5 GiB Mistral v0.3 `consolidated.safetensors`) by hash. A `BlobTooLarge` error
  means that node's `decdn_max_blob_size_mb` is too small.
- `curl -s 127.0.0.1:9090/metrics` on a node (over SSH, since metrics are loopback)
  shows cache hits and misses. With `decdn_grafana_cloud_enabled`, watch egress and
  errors in Grafana Cloud.
- Every node shows up registered, with its region, on the explorer / stats map.

## 6. When `v0.1.0` is tagged

Switch the overlay to the signed tarballs (`decdn_node_install_method: release`,
`decdn_node_version: "0.1.0"`) and redeploy. The role verifies them against the
release's GPG-signed `SHA256SUMS`, using the vendored maintainer key. Re-check the config
schema coupling (`molecule/schema`, `make lint-helm`) against the tagged `types.rs`.
