# decdn-node Helm chart

Deploys one **deCDN node** (`decdn-node`) on Kubernetes. It is the Kubernetes
counterpart of the Ansible [`decdn_node` role](../../ansible/roles/decdn_node/README.md)
and keeps the same guarantees:

- no secrets in git or in values
- missing required values, secret-bearing keys and chart-managed keys fail at render time
- one public hole (QUIC udp/4433)
- no baked-in protocol facts

One release is one node identity: one keystore and one data dir. To run a fleet, install
one release per node. The StatefulSet is fixed at one replica, because two pods sharing a
keystore would double-sign.

`node.toml` renders against upstream `crates/common/src/config/types.rs`. Every section
there is `deny_unknown_fields`, so an unknown key crash-loops the pod. CI renders the
chart's own fixtures (`ci/*.yaml`) and checks every emitted key against the same
committed inventory the Ansible `schema` molecule scenario uses
([`schema-keys.txt`](../../ansible/molecule/schema/files/schema-keys.txt)). Re-sync
it when bumping the decdn version. Keys and value types **you** add to `config` are
validated only by the daemon at startup (a typo is a crash-loop, not a render error),
and unlike the Ansible role there is no in-cluster `decdn config validate`, because the
image has no CLI.

## What it deploys

| Object | Purpose |
|--------|---------|
| `StatefulSet` (1 replica) | `decdn-node run` under a non-root, read-only-rootfs, all-caps-dropped pod. It includes a `prepare` init container. |
| `PersistentVolumeClaim` (`data`) | The data dir: node identity, voucher state, receipts, and the cache. |
| `ConfigMap` | The rendered `node.toml`. Its checksum rolls the pod on any change. |
| `Service` (quic) | Public UDP. The type is `LoadBalancer`, `NodePort` or `ClusterIP`, with `externalTrafficPolicy: Local`. |
| `Service` (metrics) | ClusterIP only, never public. |
| `NetworkPolicy` | Ingress allows QUIC from anywhere and metrics only from `metrics.networkPolicy.from`. Egress is open unless `networkPolicy.egress` is set. |
| `ServiceMonitor` | Optional (`metrics.serviceMonitor.enabled`). |

What it does **not** do:

- **Create Secrets.** The operator provisions them.
- **Generate keys.** The image is daemon-only, with no `decdn` CLI.
- **Stake or register on-chain** (ADR 019 Phase 2). Run `decdn setup` off-cluster.

## Prerequisites

- **Kubernetes ≥ 1.25**, with a CNI that enforces NetworkPolicy (the chart relies on it
  to keep metrics private), and a StorageClass that can provision a volume larger than
  `config.cache.cache_size_mb` + `config.cache.disk_headroom_mb` (daemon default 8192 MiB).
  With the defaults (10240 + 8192 MiB), the 20Gi `persistence.size` is tight.
- **UDP reachability.** Either a load balancer that supports UDP Services, or
  `quic.hostPort.enabled` on nodes with a public IP.
- **An image.** Upstream has not published `ghcr.io/decdn/decdn-node` yet. The chart
  refuses to render until `image.tag` or `image.digest` is set. To build one yourself,
  follow the header of the upstream `decdn/Dockerfile`: `cargo build --release -p
  decdn-node`, copy the binary to `dist/<arch>/decdn-node`, then `docker build`. The
  Dockerfile only packages that binary, on `debian:bookworm-slim` (glibc 2.36), so build
  on a system with glibc ≤ 2.36 or the binary will not start.
- **The `decdn` CLI on your workstation**, for `key-gen`, `setup`, and `node health`
  through a port-forward.

## Secrets

The chart only **references** Secrets. Create them out of band and keep the source files
off shared disks.

```bash
# 1. Node identity, generated off-cluster.
umask 077
mkdir -p ./node-1 && openssl rand -base64 32 > ./node-1/keystore.password
decdn key-gen --output-dir ./node-1 --keystore-password-file ./node-1/keystore.password

kubectl -n decdn create secret generic decdn-node-1-keys \
  --from-file=keystore.json=./node-1/keystore.json \
  --from-file=node.secret=./node-1/node.secret \
  --from-file=keystore.password=./node-1/keystore.password

# 2. The RPC endpoint (it may embed an API key): the k8s equivalent of
#    /etc/decdn/decdn.env. Use one key per variable (--from-literal), not
#    --from-file=decdn.env.
kubectl -n decdn create secret generic decdn-node-1-env \
  --from-literal=DECDN_RPC_URL='https://…'
```

Only **named** keys from the env Secret reach the node: `secrets.env.rpcUrlKey` (default
`DECDN_RPC_URL`) and anything in `secrets.env.passthroughKeys` (for example
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for an S3 origin). The chart deliberately
does not use `envFrom`: upstream lets every `DECDN_*` env var override `node.toml`, so a
stray `DECDN_BIND_PORT`, `DECDN_METRICS_BIND`, `DECDN_ETH_KEYSTORE`, `DECDN_CHAIN_ID` or
address variable would silently bypass the managed keys and the schema checks. For the
same reason `DECDN_*` names in `passthroughKeys` are refused.

If a Secret or a named key is missing, the pod does not start: it stays in
`ContainerCreating` (a `FailedMount` event, for the keystore Secret) or
`CreateContainerConfigError` (for an env key). Check `kubectl describe pod`.

Back up `./node-1` offline. It is the node's on-chain identity. The data dir is not a
backup, because the init container overwrites the key files from the Secret on every
pod start.

**Why the init container?** Upstream refuses `keystore.json` and `node.secret` if they are
symlinks or carry any group or world permission bit, and a data dir with group or world
bits. Secret volume files are symlinks (and `fsGroup` adjusts their modes), so they can't
be used in place. On every pod start, `prepare` creates `data_dir` as a subdirectory of
the PVC (the PVC root carries `fsGroup` bits), installs those two files into it at `0600`,
and installs `keystore.password` into an in-memory volume instead. The password is never
written to the PVC, so a volume snapshot or backup does not hold both the keystore and the
password that unlocks it. The Secret itself is mounted only in the init container, never
in the daemon.

## Required values

| Value | Notes |
|-------|-------|
| `image.tag` or `image.digest` | Required until upstream publishes a release. Prefer a digest. |
| `secrets.keystore.existingSecret` | Holds the keys `keystore.json`, `node.secret` and `keystore.password`. Rename them with `secrets.keystore.keys.*`. |
| `secrets.env.existingSecret` | Holds `DECDN_RPC_URL` (key name: `secrets.env.rpcUrlKey`). |
| `config.identity.region` | ISO 3166-1 alpha-2, uppercase. |
| `config.blockchain.chain_id` | For example, `421614` (Arbitrum Sepolia). |
| `config.blockchain.{payment_pool,capacity_bond,slash_judge,content_blacklist}_address` | Non-zero `0x` addresses. |

Take chain IDs and contract addresses from the deCDN ADRs and the deployment manifest for
your chain. Never make them up. Values are validated by `values.schema.json` plus
template guards, so a missing or malformed value fails `helm install` with a message that
names it.

```yaml
# values-node-1.yaml
image:
  digest: sha256:…
secrets:
  keystore: {existingSecret: decdn-node-1-keys}
  env: {existingSecret: decdn-node-1-env}
config:
  identity: {region: DE}
  blockchain:
    chain_id: 421614
    payment_pool_address: "0x…"
    capacity_bond_address: "0x…"
    slash_judge_address: "0x…"
    content_blacklist_address: "0x…"
```

```bash
helm install decdn-node-1 charts/decdn-node -n decdn -f values-node-1.yaml
```

## Configuration (`config`)

`config` mirrors `node.toml` section for section. The role's variable names map onto it
directly: `decdn_cache_size_mb` becomes `config.cache.cache_size_mb`, and
`decdn_tinylfu_sketch_bytes` becomes `config.cache.tinylfu.sketch_bytes`. The role's
[README](../../ansible/roles/decdn_node/README.md) documents each knob. Any key you do not
set takes the daemon default, and a `null` value removes a chart default.

Chart defaults that differ from the daemon's are the same as the role's:

- `cache.max_blob_size_mb: 1024`: a deliberate cap at one tenth of the default cache (the
  daemon default is `min(51200, cache_size_mb)`). It must be at least 1: the cache engine's
  admit gate has no zero special-case, despite the CLI help, so `0` rejects every blob.
- `observability.log_format: json` (the daemon default is `pretty`).
- `cache.cache_size_mb: 10240` and `payment.rate_per_mb: 10` are pinned explicitly, at the
  daemon's own values.
- `cache.node_to_node_pull_through_enabled`: derived when unset. It is `true` with no
  `cache.origin` or `cache.origins`, and `false` when an origin is configured.

**Managed keys.** The chart sets these to match the pod spec. Setting any of them in
`config` fails the render. (Their `DECDN_*` env equivalents cannot be injected either;
see [Secrets](#secrets).)

| Key | Set from |
|-----|----------|
| `identity.data_dir`, `cache.cache_dir`, `blockchain.eth_keystore` | Fixed PVC paths (`/var/lib/decdn/node`, `/var/lib/decdn/node/cache`, and `keystore.json` inside the data dir) |
| `network.bind_port` | `quic.port` |
| `observability.metrics_port` | `metrics.port` |
| `observability.metrics_bind` | Always `0.0.0.0`; see [Network](#network) |

**Forbidden keys.** `rpc_url`, `access_key_id`, `session_token`, and any key containing
`password` or `secret` (dashes count as underscores) are refused anywhere in `config`.
`config` renders to a ConfigMap, which is readable by anyone with configmap read access in
the namespace. The guard checks key names only: never embed a credential in a value
either (such as `https://user:pass@…` in an origin URL). Put secrets in the env Secret.

**Pod overrides.** `podLabels` cannot re-set a chart label (that would detach the pod from
its StatefulSet selector and Services), `podAnnotations` cannot re-set `checksum/config`,
and `podSecurityContext` / `securityContext` can be changed (for example, a different
non-root uid) but the render fails if the result runs as root, allows privilege escalation
or privileged mode, makes the root filesystem writable, adds capabilities, drops fewer than
`ALL`, or disables seccomp.

**Other render-time checks.** Every top-level `config` entry must be a table; a `null`
inside a list element is refused (omit the key instead); and whole numbers of 2^53 or more
are refused, because values files decode numbers as float64 and they would render rounded.

**Origins.** Use either `config.cache.origin` (one origin) or `config.cache.origins` (an
ordered, non-empty list), not both. For S3 credentials, use
`credentials: {source: default-chain}` and either pass the AWS variables through
`secrets.env.passthroughKeys`, or use IRSA (the role-ARN annotation in
`serviceAccount.annotations`) or an EKS Pod Identity association. Both webhooks inject
their own token volume, so they should work with the chart's
`automountServiceAccountToken: false` (not yet tested in a cluster). If you set
`networkPolicy.egress`, allow STS (or the Pod Identity agent). Never put credentials in
`config`.

## Network

- **QUIC** (`quic.port`, default 4433/udp) is the only public port.
  - `service.type: LoadBalancer` (the default) gives the node a stable public UDP
    address, and `externalTrafficPolicy: Local` preserves client source IPs for
    per-source rate limiting.
  - For bare-metal-style nodes, set `quic.hostPort.enabled: true` and
    `service.enabled: false`.
  - Without direct reachability, the node still works through iroh relays, at a latency
    cost.
- **Metrics** bind `0.0.0.0` inside the pod rather than loopback, which the Ansible role
  requires. That is how kubelet probes and Prometheus reach `/metrics`. Metrics are
  exposed only by a ClusterIP Service, and the NetworkPolicy admits TCP to that port only
  from `metrics.networkPolicy.from`. That list is empty by default, so no scraper is
  allowed. Kubelet probes are unaffected: the NetworkPolicy spec always allows traffic
  between a pod and the node it runs on.
  - The NetworkPolicy is what keeps metrics private, so `networkPolicy.enabled: false`
    fails the render unless `networkPolicy.allowUnrestrictedMetrics: true` accepts that
    every pod in the cluster can reach them.
  - With the policy enabled, `metrics.serviceMonitor.enabled` without any
    `metrics.networkPolicy.from` entry fails the render. The chart cannot check that your
    entries actually select Prometheus.
- **The admin RPC** is hardcoded to `127.0.0.1` upstream and cannot be reached from the
  pod network. Use a port-forward:

  ```bash
  kubectl -n decdn port-forward pod/decdn-node-1-0 9191
  DECDN_ADMIN_URL=http://127.0.0.1:9191 decdn node health
  ```

## Probes and lifecycle

- `/metrics` is the only HTTP route suitable for probes; there is no `/health` endpoint.
  It binds only after startup completes: RPC preflight, identity and keystore load, cache
  and endpoint build, then the chain bring-up (CapacityBond registry and slash-watcher
  enumerations, blacklist and DHT bootstrap).
  - The default `startupProbe` allows 5 minutes (5s × 60). A slow RPC delays readiness.
  - A failed bring-up, such as an unreachable RPC, exits the container and Kubernetes
    restarts it.
  - **Ready is not the same as serving.** The paid-delivery QUIC listeners open only after
    the first ContentBlacklist sync, which comes after `/metrics` binds. Check the logs
    before counting on traffic.
- **SIGTERM runs a graceful drain.** `terminationGracePeriodSeconds` defaults to 300, the
  role's `TimeoutStopSec`. Killing a pod mid-drain loses paid deliveries, so do not
  force-delete it.
- **Config changes roll the pod** through the ConfigMap checksum. Secret changes do not:
  after rotating the keystore or RPC URL, run
  `kubectl rollout restart statefulset/<release>`. The daemon's partial
  SIGHUP hot reload (`log_level`, `pinned_hashes`, `[security]`, `[content]`,
  `[load_shed]`) is not used, because a ConfigMap update reaches the mounted file with a
  delay and a restart is deterministic.

## On-chain onboarding

The node serves paid traffic only after it is staked and registered (ADR 019 Phase 2).
That is a manual operator step, as it is for the Ansible path. Run `decdn setup`, which
supports `--dry-run`, from your workstation against the same keystore you put in the
Secret.

## Development

```bash
make lint-helm       # helm lint --strict, positive/negative render tests, kubeconform, schema keys
make security-helm   # KICS over the rendered manifests (fail on HIGH)
DECDN_CLI=../decdn/target/release/decdn make lint-helm
                     # also run the real `decdn config validate` on every CI render
```

CI has no decdn binary, so it reports `SKIPPED: decdn config validate`. Run the
`DECDN_CLI` form locally whenever you bump the decdn version or change the renderer.

The `ci/*.yaml` values files mirror the three plays of the molecule `schema` scenario:
every knob with an S3 origin, the multi-origin list, and resolve-only discovery. When you
add a knob to one, add it to the other.
