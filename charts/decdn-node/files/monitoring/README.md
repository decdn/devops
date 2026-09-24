# Vendored monitoring assets

Copies of upstream [`decdn/decdn`](https://github.com/decdn/decdn)'s
`monitoring/` directory: four Grafana dashboards and the reference Prometheus alert
rules (companion to upstream's `adr/appendix-observability.md`). `SOURCE` records the
upstream commit and a sha256 per file. Upstream licenses them MIT OR Apache-2.0.

**Do not edit these files here.** Change them upstream, then re-vendor:

```bash
scripts/sync-monitoring.sh <path-to-decdn-checkout>            # default ref origin/main
scripts/sync-monitoring.sh <path-to-decdn-checkout> --check    # what CI's weekly drift job runs
```

## On Kubernetes

The chart renders them when asked (see the chart README, "Monitoring"):
`metrics.prometheusRule.enabled` creates a `PrometheusRule`, and
`metrics.grafanaDashboards.enabled` creates one sidecar-labelled ConfigMap per
dashboard. `metrics.serviceMonitor` adds the target labels they select on (`job`,
`region`, `deployment_environment`, `instance`).

## On the Ansible path (Grafana Cloud)

The `grafana_alloy` role already stamps the labels these assets expect: the node's
metrics carry `job="decdn-node"`, `region` and `deployment_environment`; machine
metrics and logs carry `job="integrations/node_exporter"`. So:

- **Dashboards:** in Grafana, *Dashboards → New → Import*, upload each `*.json`, and
  pick your Prometheus, Loki and Tempo datasources for the `DS_*` variables. Loki and
  Tempo panels stay empty unless logs and traces are shipped.
- **Alerts:** load `prometheus-alerts.yml` as a rule group, e.g. with
  `mimirtool rules load prometheus-alerts.yml` against your Grafana Cloud Prometheus
  endpoint, or through *Alerting → Alert rules → Import*.
