# Changelog — `decdn-node` Helm chart

All notable changes to the chart are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the chart adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The chart and the
`decdn.node` Ansible collection share one repo version: a `vX.Y.Z` tag releases
both (see [RELEASING.md](../../RELEASING.md)).

## [Unreleased]

### Added

- `ServiceMonitor`: the `job`, `region`, `deployment_environment` and `instance`
  target labels the dashboards and alerts select on, configurable through
  `metrics.serviceMonitor.jobLabel`, `.deploymentEnvironment` and `.relabelings`.
- Optional `PrometheusRule` with the deCDN reference alert rules
  (`metrics.prometheusRule`), and the deCDN Grafana dashboards as sidecar-labelled
  ConfigMaps (`metrics.grafanaDashboards`). Both are packaged in `files/monitoring/`;
  in the repo that is a symlink to the top-level `monitoring/decdn-node/`, which this
  repo maintains for every deploy path; `decdn/decdn` no longer ships them.
- The repo's `monitoring/sponsord/` (not part of the chart): a Grafana dashboard
  (`uid: decdn-sponsord`) and alert rules for the onboarding sponsor (down, keeper
  failing, stale pool read, a held top-up, an empty pool, request errors), with
  promtool unit tests. sponsord has no Kubernetes path, so the chart neither renders
  nor packages them; they are for import on the Ansible and Compose paths.

### Fixed

- Delivery dashboard: recency seed failures get their own stat panel, which reads the
  raw `decdn_cache_recency_seed_failures_total` like the `DecdnCacheRecencySeedFailed`
  alert. The counter is set once at cache open, before the first scrape, so the
  `rate()` it was plotted with read 0 even after a failure (#99).

## [0.1.0] — unreleased

Initial chart. Not yet published (pre-1.0; the values shape may still change).

### Added

- One-replica `StatefulSet` running the upstream daemon-only image
  (`ghcr.io/decdn/decdn-node`, `image.tag` or `image.digest` required), non-root,
  read-only root filesystem, every capability dropped, `RuntimeDefault` seccomp.
- `PersistentVolumeClaim` data dir. A `prepare` init container installs the node
  identity from an operator-provisioned `existingSecret` at `0600`, and the keystore
  password into an in-memory volume, never onto the PVC.
- `values.config` mirrors `node.toml`; the chart injects the path and port keys,
  refuses secret-bearing keys, and checks the rendered key set against the upstream
  config schema (`make lint-helm`).
- `DECDN_RPC_URL` and named passthrough keys via `secretKeyRef` only, never
  `envFrom`.
- Public QUIC over a `LoadBalancer`, `NodePort` or `ClusterIP` Service, or `hostPort`.
- Metrics bound `0.0.0.0` in the pod behind a ClusterIP-only Service and a
  `NetworkPolicy` that admits only `metrics.networkPolicy.from`; disabling the policy
  needs `networkPolicy.allowUnrestrictedMetrics: true`.
- Optional `ServiceMonitor` (`metrics.serviceMonitor`).
