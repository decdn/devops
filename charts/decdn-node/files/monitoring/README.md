# Monitoring assets

The deCDN Grafana dashboards and reference Prometheus alert rules, maintained here. The
node's metric surface is documented in upstream `decdn/decdn`'s
`adr/appendix-observability.md`. Imported from `decdn/decdn` (MIT OR Apache-2.0) at
`20db95ef`; distributed here under this repo's MIT license.

| File | What it is |
|------|------------|
| `grafana-dashboard.json` | Fleet overview (`uid: decdn-poc-overview`): status, delivery funnel, slash safety, logs and traces. |
| `dashboard-delivery.json` | Delivery and cache (`uid: decdn-delivery`): serve leg, paying pull leg, cache, origin, warming. |
| `dashboard-chain.json` | Chain, payments and slash safety (`uid: decdn-chain`): watcher liveness, chain RPC, registries, payments. |
| `dashboard-node.json` | Single-node drilldown (`uid: decdn-node`): host, process, iroh transport, DHT and probe, logs, traces. |
| `prometheus-alerts.yml` | Rule groups `decdn-slash-safety`, `decdn-liveness`, `decdn-delivery`. A rule with a matching runbook section carries a `runbook_url` into upstream's `docs/runbook.md`. |

**Editing.** Every `decdn_*` series a panel or rule names must be one `decdn-node`
exports; nothing in CI checks this. See
[`.claude/skills/grafana-dashboards/SKILL.md`](../../../../.claude/skills/grafana-dashboards/SKILL.md)
for the name check, the query traps and the publishing steps. Run `make lint-helm`
after any edit: it runs `promtool check rules` on `prometheus-alerts.yml` (PromQL syntax,
duplicate keys) and checks that every dashboard parses and has its own uid.

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
