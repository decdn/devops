---
name: grafana-dashboards
description: Create and manage production Grafana dashboards for real-time visualization of system and application metrics. Use when building monitoring dashboards, visualizing metrics, or creating operational observability interfaces.
---

# Grafana Dashboards

Create and manage production-ready Grafana dashboards for comprehensive system observability.

## Purpose

Design effective Grafana dashboards for monitoring applications, infrastructure, and business metrics.

## When to Use

- Visualize Prometheus metrics
- Create custom dashboards
- Implement SLO dashboards
- Monitor infrastructure
- Track business KPIs

## In this repo (deCDN devops) — read first

Generic k8s / `node_exporter` / `http_requests_total` examples below are patterns, not
targets. `decdn-node` exports ~200 of its own `decdn_*` series, and this repo maintains the
four-dashboard suite and alert rules that go with them. `decdn/decdn` ships none; this is
their only home.

**The files** (the node's in `monitoring/decdn-node/`, sponsord's in `monitoring/sponsord/`,
the iroh relay's in `monitoring/iroh-relay/`):

- `grafana-dashboard.json` — "deCDN — fleet overview", uid `decdn-poc-overview`.
  Fleet status, delivery funnel, slash safety, logs and traces.
- `dashboard-delivery.json` — uid `decdn-delivery`. Serve leg, paying pull leg,
  cache, origin, warming.
- `dashboard-chain.json` — uid `decdn-chain`. Watcher liveness, registries,
  seller and buyer payments.
- `dashboard-node.json` — uid `decdn-node`. Single-node drilldown: host,
  process, iroh transport, DHT and probe, logs, traces.
- `prometheus-alerts.yml` — three groups: `decdn-slash-safety`, `decdn-liveness`,
  `decdn-delivery`. Every rule carries a `component` label. Only rules with a matching
  section in upstream's `docs/runbook.md` (20 of 51) also carry a `runbook_url`.
  `DecdnNodeDown` has promtool unit tests in `prometheus-alerts_test.yml` (the
  chart's `.helmignore` keeps that file out of the package): keep them in step.

- `monitoring/sponsord/` — the onboarding sponsor's own pair: `dashboard-sponsord.json` (uid
  `decdn-sponsord`) and `prometheus-alerts.yml` (group `sponsord`, `job="sponsord"`).
  The chart does not render this directory (sponsord has no Kubernetes path). Its
  `sponsord_*` names come from upstream `decdn/sponsord` `crates/sponsord/src/metrics.rs`
  (check them with the recipe after the node one below). Its logs are plain text,
  not JSON: select `{unit="sponsord.service"}` and filter on the `level` label the
  `grafana_alloy` role parses. The rules have promtool unit tests in
  `monitoring/sponsord/prometheus-alerts_test.yml`: keep them in step.

- `monitoring/iroh-relay/` — the self-hosted iroh relay's pair: `dashboard-iroh-relay.json`
  (uid `decdn-iroh-relay`) and `prometheus-alerts.yml` (group `iroh-relay`,
  `job="iroh-relay"`), Ansible path only, not rendered by the chart. Every series is a
  `relayserver_*_total` counter (no gauges: "connected" is `accepts − disconnects`).
  `exported-metrics.txt` is the pinned binary's `/metrics`, and `make lint-helm` fails on
  any `relayserver_*` name not in it — so this pair, unlike the others, IS name-checked
  in CI. Re-capture it on an `iroh_relay_version` bump (the command is in its header).
  Logs: `{unit="iroh-relay.service"}` with the parsed `level`. Unit tests in
  `prometheus-alerts_test.yml`.

Add a row to an existing dashboard before starting a fifth node one. The Helm chart renders
the node's files as-is (`templates/prometheusrule.yaml`, `templates/dashboards-configmap.yaml`)
through `charts/decdn-node/files/monitoring`, a symlink to `monitoring/decdn-node/`, so a
new `*.json` becomes a new ConfigMap and `charts/decdn-node/tests/render-test.sh` checks
the rule and dashboard counts against the directory. Never pass them through
`tpl`: the alert annotations carry Prometheus templates.

**All three signals are live.** Metrics reach Grafana Cloud Prometheus as `job="decdn-node"`;
logs reach Loki as `{service_name="decdn-node", unit="decdn-node.service"}`; traces
reach Tempo as `resource.service.name="decdn-node"`. The log streams keep
`job="integrations/node_exporter"` because Grafana Cloud's Linux Server integration joins logs to
host metrics on `job` + `instance`, so never select daemon logs by `job`. Dashboard log panels
select on `unit` + `instance`. The `grafana_alloy` role (`ansible/roles/grafana_alloy`) stamps
these labels; on Helm, `metrics.serviceMonitor` adds the same target labels.

**Nothing checks metric names.** No test or CI job ties these files to what `decdn-node`
exports, so a typo renders `(no data)` and a rule on a missing series never fires. Check by
hand after any edit, against a running node (or `curl` a testnet node's `/metrics`):

```bash
cd monitoring/decdn-node
# Names the files use (drop whole-line YAML comments; ignore regex stems ending in `_`).
grep -hv '^\s*#' *.json *.yml | grep -oE 'decdn_[a-z0-9_]+' | grep -v '_$' | sort -u > /tmp/used
# Names the node exports, from sample lines (not `# TYPE`: counters lose `_total` there).
# Histogram `_bucket`/`_sum`/`_count` samples stay, and also fold to the base name.
curl -s http://127.0.0.1:9090/metrics | grep -v '^#' | grep -oE '^decdn_[a-z0-9_]+' \
  | sed -E 'p; s/_(bucket|sum|count)$//' | sort -u > /tmp/exported
comm -23 /tmp/used /tmp/exported   # must print nothing
```

For sponsord, from `monitoring/` (`sponsord_log_level` in a panel description is an
Ansible variable, not a series):

```bash
cd ..
grep -hv '^\s*#' sponsord/*.json sponsord/prometheus-alerts.yml | grep -oE 'sponsord_[a-z0-9_]+' | sort -u > /tmp/used-sd
curl -s http://127.0.0.1:8090/metrics | grep -v '^#' | grep -oE '^sponsord_[a-z0-9_]+' | sort -u > /tmp/exported-sd
comm -23 /tmp/used-sd /tmp/exported-sd   # prints only sponsord_log_level
```

A code's `sponsord_request_errors_total{code}` series appears only after that code's first
error, so a fresh daemon may not export it yet; check against upstream `metrics.rs` then.

`decdn_iroh_*` series appear only once the node's endpoint is up, and a labelled family
with no child (e.g. `decdn_staker_set_active_by_region` before any staker declares a
region) emits nothing — read a stray hit with that in mind. `decdn_health` is a Prometheus
`job=` label in a commented blackbox example, not a series.

**Rules:**

1. Any exported series may be used, not only the ones upstream's
   `adr/appendix-observability.md` lists — the registry is a curated subset and says so.
   But check its **Status** column before using a name you found *there*: a `planned` row
   emits nothing, so a panel built on it is permanently empty. The exporter is the source of
   truth; the appendix is a view of it.
2. `reason`-style splits are usually **sibling counters, not labels** — one unlabeled counter per
   reason. `decdn_probe_hold_unavailable{reason}` is the single documented exception.
   Do not write a `by (reason)` query against a series that has no such label.
3. A name that resolves can still sit at a permanent zero because nothing increments it.
4. A panel or alert that names a *new* metric needs the metric in upstream
   `crates/node/src/metrics.rs` first, in a released or pinned `decdn-node`.
5. The two "Unattributed stream failures" panels (overview and delivery) subtract every
   inbound failure reason from `decdn_streams_failed_total{direction="inbound"}`. When
   upstream adds a reason to `INBOUND_FAILURE_REASONS` in `crates/node/src/metrics.rs`,
   add it to both panels, once each.
6. `region` is a scrape-side target label, and every dashboard scopes `$region` on it. The
   declared-region gauge `decdn_staker_set_active_by_region` labels by `node_region` so it
   does not clash (Prometheus would rename a metric's own `region` to `exported_region`).

**`rate()` and `increase()` drop `__name__`.** This is the trap in every family panel here:

```promql
# does not evaluate — the per-reason series collapse to identical label sets
sum by (__name__) (rate({__name__=~"decdn_serve_stream_rejected_.+_total"}[5m]))
```

Prometheus answers `vector cannot contain metrics with the same labelset`, and wrapping it in
`sum by (instance)` does not help — the duplicate exists before the aggregation runs. So:

- **Rate panels name each series explicitly**, one target per metric. Verbose, and correct, and
  it keeps every name visible to the name check above; the regex form scans as the wildcard
  token `decdn_serve_stream_rejected_` and is skipped.
- **Instant panels over a family use `label_replace` on the raw selector**, before any operator
  strips the name. The watcher-liveness table and the `DecdnWatcherTaskPanicked` rule are
  both built this way:

```promql
time() - label_replace(
  {__name__=~"decdn_.+_watcher_last_tick_timestamp_seconds"} > 0,
  "watcher", "$1", "__name__", "decdn_(.+)_watcher_last_tick_timestamp_seconds")
```

**Few histograms.** Only a handful of latencies are histograms: the serve and pull
time-to-first-byte family, probe collection latency, and chain RPC request latency. Check
for a `_bucket` sample before writing `histogram_quantile`. For any other latency, use
TraceQL: `{...} | quantile_over_time(duration, .5, .95, .99)`.

**Logs need `| json`.** The daemon writes tracing JSON to stdout and journald stamps every line
priority `info`, so Loki's `level` stream label and `detected_level` are both useless. Parse the
body instead, naming the fields so nothing collides with a stream label:

```logql
{unit="decdn-node.service", instance=~"$instance"}
  | json lvl="level", tgt="target", msg="fields.message"
  | lvl=~"WARN|ERROR"
```

**Importing.** Dashboards share a datasource variable per signal — `${DS_PROMETHEUS}`,
`${DS_LOKI}`, `${DS_TEMPO}` — that re-resolve on load, so an import into another Grafana
falls back to the picker. The `instance` variable populates from `decdn_node_uptime_seconds`.
Validate rule edits with `promtool check rules prometheus-alerts.yml`.

**Publishing.** `GRAFANA_SERVICE_ACCOUNT_TOKEN` is in the environment; dashboards go to
`POST /api/dashboards/db` with `overwrite: true`, into folder uid `dfykix7ln0gsgc` ("deCDN").
The Grafana Cloud **ruler proxy rejects writes made with a service-account token**
(`400 bad request data`) even for a valid group, so with that token alerts are provisioned
as Grafana-managed rules through `/api/v1/provisioning/alert-rules` instead. (Operators
with a Cloud Access Policy token can load the file as-is with `mimirtool rules load`
against the stack's Prometheus endpoint, as `monitoring/README.md` describes.) Each rule's PromQL already holds its own
comparison, so the surviving values are not a threshold (`up == 0` fires at value 0): the
Grafana-managed condition counts datapoints, with `noDataState: OK` as the not-firing case.

## Dashboard Design Principles

### 1. Hierarchy of Information

```
┌─────────────────────────────────────┐
│  Critical Metrics (Big Numbers)     │
├─────────────────────────────────────┤
│  Key Trends (Time Series)           │
├─────────────────────────────────────┤
│  Detailed Metrics (Tables/Heatmaps) │
└─────────────────────────────────────┘
```

### 2. RED Method (Services)

- **Rate** - Requests per second
- **Errors** - Error rate
- **Duration** - Latency/response time

### 3. USE Method (Resources)

- **Utilization** - % time resource is busy
- **Saturation** - Queue length/wait time
- **Errors** - Error count

## Dashboard Structure

### API Monitoring Dashboard

```json
{
  "dashboard": {
    "title": "API Monitoring",
    "tags": ["api", "production"],
    "timezone": "browser",
    "refresh": "30s",
    "panels": [
      {
        "title": "Request Rate",
        "type": "graph",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total[5m])) by (service)",
            "legendFormat": "{{service}}"
          }
        ],
        "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 }
      },
      {
        "title": "Error Rate %",
        "type": "graph",
        "targets": [
          {
            "expr": "(sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))) * 100",
            "legendFormat": "Error Rate"
          }
        ],
        "alert": {
          "conditions": [
            {
              "evaluator": { "params": [5], "type": "gt" },
              "operator": { "type": "and" },
              "query": { "params": ["A", "5m", "now"] },
              "type": "query"
            }
          ]
        },
        "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 }
      },
      {
        "title": "P95 Latency",
        "type": "graph",
        "targets": [
          {
            "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))",
            "legendFormat": "{{service}}"
          }
        ],
        "gridPos": { "x": 0, "y": 8, "w": 24, "h": 8 }
      }
    ]
  }
}
```

**Reference:** in this repo, see `monitoring/decdn-node/grafana-dashboard.json`
and the three dashboards beside it.

## Panel Types

### 1. Stat Panel (Single Value)

```json
{
  "type": "stat",
  "title": "Total Requests",
  "targets": [
    {
      "expr": "sum(http_requests_total)"
    }
  ],
  "options": {
    "reduceOptions": {
      "values": false,
      "calcs": ["lastNotNull"]
    },
    "orientation": "auto",
    "textMode": "auto",
    "colorMode": "value"
  },
  "fieldConfig": {
    "defaults": {
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "value": 0, "color": "green" },
          { "value": 80, "color": "yellow" },
          { "value": 90, "color": "red" }
        ]
      }
    }
  }
}
```

### 2. Time Series Graph

```json
{
  "type": "graph",
  "title": "CPU Usage",
  "targets": [
    {
      "expr": "100 - (avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)"
    }
  ],
  "yaxes": [
    { "format": "percent", "max": 100, "min": 0 },
    { "format": "short" }
  ]
}
```

### 3. Table Panel

```json
{
  "type": "table",
  "title": "Service Status",
  "targets": [
    {
      "expr": "up",
      "format": "table",
      "instant": true
    }
  ],
  "transformations": [
    {
      "id": "organize",
      "options": {
        "excludeByName": { "Time": true },
        "indexByName": {},
        "renameByName": {
          "instance": "Instance",
          "job": "Service",
          "Value": "Status"
        }
      }
    }
  ]
}
```

### 4. Heatmap

```json
{
  "type": "heatmap",
  "title": "Latency Heatmap",
  "targets": [
    {
      "expr": "sum(rate(http_request_duration_seconds_bucket[5m])) by (le)",
      "format": "heatmap"
    }
  ],
  "dataFormat": "tsbuckets",
  "yAxis": {
    "format": "s"
  }
}
```

## Variables

### Query Variables

```json
{
  "templating": {
    "list": [
      {
        "name": "namespace",
        "type": "query",
        "datasource": "Prometheus",
        "query": "label_values(kube_pod_info, namespace)",
        "refresh": 1,
        "multi": false
      },
      {
        "name": "service",
        "type": "query",
        "datasource": "Prometheus",
        "query": "label_values(kube_service_info{namespace=\"$namespace\"}, service)",
        "refresh": 1,
        "multi": true
      }
    ]
  }
}
```

### Use Variables in Queries

```
sum(rate(http_requests_total{namespace="$namespace", service=~"$service"}[5m]))
```

## Alerts in Dashboards

```json
{
  "alert": {
    "name": "High Error Rate",
    "conditions": [
      {
        "evaluator": {
          "params": [5],
          "type": "gt"
        },
        "operator": { "type": "and" },
        "query": {
          "params": ["A", "5m", "now"]
        },
        "reducer": { "type": "avg" },
        "type": "query"
      }
    ],
    "executionErrorState": "alerting",
    "for": "5m",
    "frequency": "1m",
    "message": "Error rate is above 5%",
    "noDataState": "no_data",
    "notifications": [{ "uid": "slack-channel" }]
  }
}
```

## Dashboard Provisioning

**dashboards.yml:**

```yaml
apiVersion: 1

providers:
  - name: "default"
    orgId: 1
    folder: "General"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards
```

## Common Dashboard Patterns

### Infrastructure Dashboard

**Key Panels:**

- CPU utilization per node
- Memory usage per node
- Disk I/O
- Network traffic
- Pod count by namespace
- Node status

**Reference:** in this repo, host panels live in
`monitoring/decdn-node/dashboard-node.json`, which
reads `node_exporter` series under the same `instance` and `region` labels the `decdn_*`
series carry — one node selector drives both.

### Database Dashboard

**Key Panels:**

- Queries per second
- Connection pool usage
- Query latency (P50, P95, P99)
- Active connections
- Database size
- Replication lag
- Slow queries

**Reference:** not applicable in this repo — deCDN has no database tier.

### Application Dashboard

**Key Panels:**

- Request rate
- Error rate
- Response time (percentiles)
- Active users/sessions
- Cache hit rate
- Queue length

## Best Practices

1. **Start with templates** (Grafana community dashboards)
2. **Use consistent naming** for panels and variables
3. **Group related metrics** in rows
4. **Set appropriate time ranges** (default: Last 6 hours)
5. **Use variables** for flexibility
6. **Add panel descriptions** for context
7. **Configure units** correctly
8. **Set meaningful thresholds** for colors
9. **Use consistent colors** across dashboards
10. **Test with different time ranges**

## Dashboard as Code

### Terraform Provisioning

```hcl
resource "grafana_dashboard" "api_monitoring" {
  config_json = file("${path.module}/dashboards/api-monitoring.json")
  folder      = grafana_folder.monitoring.id
}

resource "grafana_folder" "monitoring" {
  title = "Production Monitoring"
}
```

### Ansible Provisioning

```yaml
- name: Deploy Grafana dashboards
  copy:
    src: "{{ item }}"
    dest: /etc/grafana/dashboards/
  with_fileglob:
    - "dashboards/*.json"
  notify: restart grafana
```

## Related references

- `monitoring/README.md` — importing on Kubernetes and Grafana Cloud.
- Upstream `decdn/decdn` `adr/appendix-observability.md` — metric registry (name, type,
  tier, Status).
- Upstream `decdn/decdn` `crates/node/src/metrics.rs` — the exporter.
- Upstream `decdn/decdn` `docs/runbook.md` — operational responses the alerts' `runbook_url`s
  point at.
