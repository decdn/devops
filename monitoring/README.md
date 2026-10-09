# Monitoring assets

The deCDN Grafana dashboards and reference Prometheus alert rules, maintained here:
`decdn-node/` for the node, on every deploy path, `sponsord/` for the onboarding
sponsor, on the Ansible and Compose paths, and `iroh-relay/` for the self-hosted iroh
relay, on the Ansible path. The node's metric surface is documented in
upstream `decdn/decdn`'s `adr/appendix-observability.md`. The node's assets were
imported from `decdn/decdn` (MIT OR Apache-2.0) at `20db95ef`; distributed here under
this repo's MIT license. sponsord's were written here.

| File | What it is |
|------|------------|
| `decdn-node/grafana-dashboard.json` | Fleet overview (`uid: decdn-poc-overview`): status, delivery funnel, slash safety, logs and traces. |
| `decdn-node/dashboard-delivery.json` | Delivery and cache (`uid: decdn-delivery`): serve leg, paying pull leg, cache, origin, warming. |
| `decdn-node/dashboard-chain.json` | Chain, payments and slash safety (`uid: decdn-chain`): watcher liveness, chain RPC, registries, payments. |
| `decdn-node/dashboard-node.json` | Single-node drilldown (`uid: decdn-node`): host, process, iroh transport, DHT and probe, logs, traces. |
| `decdn-node/prometheus-alerts.yml` | Rule groups `decdn-slash-safety`, `decdn-liveness`, `decdn-delivery`. A rule with a matching runbook section carries a `runbook_url` into upstream's `docs/runbook.md`. |
| `decdn-node/prometheus-alerts_test.yml` | promtool unit tests for `DecdnNodeDown` (run by `make lint-helm`; the chart's `.helmignore` keeps them out of the package). |
| `sponsord/` | The onboarding sponsor's dashboard and alert rules ([below](#sponsord)). Not rendered by the chart. |
| `iroh-relay/` | The iroh relay's dashboard and alert rules ([below](#iroh-relay)). Not rendered by the chart. |

**Editing.** Every `decdn_*` series a panel or rule names must be one `decdn-node`
exports; nothing in CI checks this. See
[`.claude/skills/grafana-dashboards/SKILL.md`](../.claude/skills/grafana-dashboards/SKILL.md)
for the name check, the query traps and the publishing steps. Run `make lint-helm`
after any edit: it runs `promtool check rules` on every `prometheus-alerts.yml`
(PromQL syntax, duplicate keys), `promtool test rules` on each
`prometheus-alerts_test.yml` beside it, and checks that every dashboard parses and has
its own uid. The chart packages everything in `decdn-node/` but what its
`.helmignore` drops (`*_test.yml`), and `make lint-helm` allows only `*.json` and
`prometheus-alerts.yml` in the package, so anything else belongs elsewhere or in
that `.helmignore`.

## The `*Down` alerts

`DecdnNodeDown`, `SponsordDown` and `IrohRelayDown` fire on `up == 0`, and also on an
instance whose `up` stopped arriving after it reported in the last day.

- **Why.** On the Ansible path the scraper is the Alloy agent on the same host, so
  when the host, its network or Alloy dies, no `up == 0` is ever written. The
  absence arm is what catches that outage. A central Prometheus (the chart's
  ServiceMonitor, or your own on Compose) writes `up == 0` itself, and there the arm
  fires once the target leaves service discovery.
- **When.** Without a staleness marker (a dead host), about 5 minutes (Prometheus's
  lookback) plus the rule's `for:` after the last sample. With one (the target left
  service discovery), after the `for:`.
- **How long.** It resolves a day after the last sample, even if the target is
  still down.
- **What it matches on.** `job` and `instance` (and `namespace` for the node). A
  changed `region`, `deployment_environment` or other label on a live target does
  not fire.
- **Silence it** before you decommission a host, move a service to a new inventory
  host, or rename its `job` (`grafana_alloy_*_job`, `metrics.serviceMonitor.jobLabel`)
  or `instance`: the old series fires for a day. On Kubernetes, the same goes for
  scaling a release to zero, or uninstalling one while another release still
  carries the rules. A pod replacement that takes longer than the `for:` (1m) pages.

## On Kubernetes

The chart renders `decdn-node/` when asked (see the
[chart README](../charts/decdn-node/README.md#monitoring)); it reads the files through
`charts/decdn-node/files/monitoring`, a symlink to `decdn-node/` that `helm package`
turns into regular files. `metrics.prometheusRule.enabled` creates a `PrometheusRule`, and
`metrics.grafanaDashboards.enabled` creates one sidecar-labelled ConfigMap per
dashboard. `metrics.serviceMonitor` adds the target labels they select on (`job`,
`region`, `deployment_environment`, `instance`).

## On the Ansible path (Grafana Cloud)

The `grafana_alloy` role already stamps the labels these assets expect: the node's
metrics carry `job="decdn-node"`, `region` and `deployment_environment`; machine
metrics and logs carry `job="integrations/node_exporter"`. So:

- **Dashboards:** in Grafana, *Dashboards → New → Import*, upload each
  `decdn-node/*.json`, and
  pick your Prometheus, Loki and Tempo datasources for the `DS_*` variables. Loki and
  Tempo panels stay empty unless logs and traces are shipped.
- **Alerts:** load `decdn-node/prometheus-alerts.yml` as a rule group, e.g. with
  `mimirtool rules load decdn-node/prometheus-alerts.yml` against your Grafana Cloud Prometheus
  endpoint, or through *Alerting → Alert rules → Import*.

## sponsord

`sponsord/` holds the same pair for the deCDN onboarding sponsor (`decdn/sponsord`),
which runs on the Ansible and Compose paths only. The chart never renders it: its
`files/monitoring` symlink reaches `decdn-node/` alone, and `make lint-helm` checks that
the packaged chart carries nothing else.

| File | What it is |
|------|------------|
| `sponsord/dashboard-sponsord.json` | `uid: decdn-sponsord`: pool balance, the top-up hold, keeper reads and top-ups, capabilities issued, errors by code, the daemon's and the onramp's logs. |
| `sponsord/prometheus-alerts.yml` | Rule group `sponsord`: down, keeper failing, a stale pool read (or none since start), a held top-up (and one held over 2 h), an empty pool, sponsord's own request errors. `runbook_url` points at upstream's `docs/operator.md`, "Monitor". |

They select `job="sponsord"`, which the `grafana_alloy` role stamps on sponsord's
`/metrics` (`grafana_alloy_sponsord_job`); log panels select `unit="sponsord.service"`
and `unit="sponsord-onramp.service"` with the `level` label the role parses. Import
them as above, e.g. `mimirtool rules load sponsord/prometheus-alerts.yml`. Every
`sponsord_*` series they name must be one upstream's `crates/sponsord/src/metrics.rs`
exports; `make lint-helm` runs `promtool check rules` on the rules and the unit tests
in `sponsord/prometheus-alerts_test.yml`, and checks the dashboard's uid.

The treasury wallet's own USDC and gas balance, which pays every top-up, is not
covered: sponsord does not export it. Watch that address with a balance exporter of
your own; `SponsordKeeperFailing` is the symptom when it runs dry.

## iroh relay

`iroh-relay/` holds the same pair for the self-hosted iroh relays
([`roles/iroh_relay`](../ansible/roles/iroh_relay/README.md)), which run on the Ansible
path only. The chart never renders it.

| File | What it is |
|------|------------|
| `iroh-relay/dashboard-iroh-relay.json` | `uid: decdn-iroh-relay`: up, connected clients, connections per day, open QAD connections, relayed bandwidth and packets (and drops), connects, https connections and errors, QUIC address discovery, rate limiting, the relay's log. |
| `iroh-relay/prometheus-alerts.yml` | Rule group `iroh-relay`: down, most https connections erroring, most QAD handshakes failing (both point at the certificate), dropping relayed packets, rate limiting (info). |
| `iroh-relay/exported-metrics.txt` | The `/metrics` of the pinned `iroh-relay` release. `make lint-helm` fails on a `relayserver_*` name the dashboard or rules use that is not in it. |

They select `job="iroh-relay"`, which the `grafana_alloy` role stamps on the relay's
`/metrics` (`grafana_alloy_iroh_relay_job`); the log panel selects
`unit="iroh-relay.service"` with the parsed `level`. Import them as above, e.g.
`mimirtool rules load iroh-relay/prometheus-alerts.yml`. `make lint-helm` also runs
`promtool check rules` and the unit tests in `iroh-relay/prometheus-alerts_test.yml`.

The certificate's expiry is not covered: iroh-relay renews it itself but exports
nothing about it. Watch `https://<hostname>/healthz` with a blackbox or synthetic check
of your own.
