# grafana_alloy

Opt-in Grafana Cloud observability for an Ansible-deployed deCDN node
([decdn/devops#55](https://github.com/decdn/devops/issues/55)): a dedicated,
loopback-only [Grafana Alloy](https://grafana.com/docs/alloy/) agent that

- scrapes the node's `/metrics` (Prometheus exposition on loopback port 9090)
  and pushes it to your Grafana Cloud Prometheus, stamped with low-cardinality
  identity labels,
- scrapes **the machine itself** — CPU, memory, disk, filesystem, network, load,
  PSI saturation and the state of the units that matter — through Alloy's
  in-process `node_exporter`, labelled so Grafana Cloud's prebuilt **Linux
  Server** dashboards and alert rules work with no dashboard wiring,
- ships **journald** (host and services) to your Grafana Cloud Loki with the same
  `job`/`instance` pair, so logs and metrics correlate in those dashboards,
- reports **its own** health (`prometheus.exporter.self`), which is what
  distinguishes "the node went quiet" from "the agent reporting on the node is
  wedged", and
- receives the daemon's OTLP span exports (`otlp_endpoint`) on gRPC `127.0.0.1:4317`
  and HTTP `127.0.0.1:4318`, probabilistically samples traces (default keep-ratio 0.25),
  batches them, and exports via OTLP/HTTP to your Grafana Cloud org.

Everything except the node's public QUIC port stays on loopback: the exporters
run *inside* the agent, so machine monitoring adds no listener and no firewall
hole.

The Helm-chart path is separate and deliberately untouched by this role — on
Kubernetes, host-level telemetry is the cluster's job.

## Opt in

Set ONE variable — mirrored into both roles, so it must be overridden at group or
host level only:

```yaml
# e.g. inventory/group_vars/<group>.yml or host_vars/<host>.yml
decdn_grafana_cloud_enabled: true
```

Machine metrics, agent self-metrics and journald come with it (each has its own
`grafana_alloy_*_enabled` sub-knob, all defaulting to `true`).

### Credentials: one secret per host, the rest in inventory

Only the **API token** is a secret. The endpoint URLs and the three numeric
instance IDs are not, so they belong in inventory — written once for the fleet
rather than typed on every host:

```yaml
# group_vars/<group>.yml — non-secret, safe to commit
grafana_alloy_prom_url: https://prometheus-prod-13-prod-us-east-0.grafana.net/api/prom/push
grafana_alloy_prom_username: "1234567"          # Prometheus instance ID
grafana_alloy_otlp_endpoint: https://otlp-gateway-prod-us-east-0.grafana.net/otlp
grafana_alloy_otlp_username: "2345678"          # STACK instance ID, shown on the OTLP page
grafana_alloy_loki_url: https://logs-prod-006.grafana.net/loki/api/v1/push
grafana_alloy_loki_username: "7654321"          # Loki instance ID — a DIFFERENT number
```

Each of those three IDs is its own number in the portal. Copy each from the page
that names it (**Prometheus → Username / Instance ID**, **OTLP Endpoint →
Instance ID**, **Loki → User**) rather than assuming one value covers all three:
where the OTLP ID differs and is left unset, traces 401 while metrics and logs
keep flowing, which reads as "tracing is broken" rather than "auth is wrong".

Then the only thing to provision **on the target host** is the token (it never
transits the control machine):

```bash
umask 077
printf 'GC_API_TOKEN=glc_…\n' > grafana-alloy.env
sudo install -m 600 -o root -g root grafana-alloy.env /etc/grafana-alloy.env
```

Every one of those variables is optional: left empty, its value is read from the
matching `GC_…` key in the env file exactly as before, and preflight requires the
key only then. Any mix of the two halves is valid.
`roles/grafana_alloy/files/grafana-alloy.env.example` shows the full key set.

> **Upgrading an existing host.** Logs are on by default, and Loki needs an
> endpoint + instance ID that the pre-existing four-key env file does not have.
> Preflight fails loudly, naming both the missing key and the inventory variable
> that satisfies it. Pick one: set `grafana_alloy_loki_url` /
> `grafana_alloy_loki_username` in inventory (recommended — nothing to do per
> host), append `GC_LOKI_URL` / `GC_LOKI_USERNAME` to `/etc/grafana-alloy.env`,
> or set `grafana_alloy_logs_enabled: false` to keep shipping exactly what you
> shipped before. The other four keys are untouched by this change.
>
> Host metrics need no new credential (they ride the existing Prometheus
> remote-write), but note that the daemon's own series now carry
> `job="decdn-node"` instead of the implicit `job="prometheus.scrape.decdn_node"`.
> Set `grafana_alloy_node_job: ""` to keep the old value if dashboards or alert
> rules already hard-code it.
>
> **Traces 401 after an upgrade?** The OTLP gateway wants the stack instance ID,
> and earlier versions of this role reused the Prometheus one. Where your org's
> two IDs differ, set `grafana_alloy_otlp_username` (or add `GC_OTLP_USERNAME` to
> the env file); where they coincide, nothing changes and nothing is needed.
> `GC_OTLP_USERNAME` is the one credential key that may be absent — but if it is
> present, preflight checks its shape, because a malformed value outranks the
> Prometheus fallback at runtime and 401s traces just the same.

`GC_API_TOKEN` has **no** inventory variable by design: the rendered
`/etc/alloy/config.alloy` is world-readable, and preflight rejects a value that
looks like a token (or a URL with embedded credentials) in any of the six
variables above.

The credential path is intentionally restricted to a **direct child of `/etc`**. A
nested override (including the old `/etc/decdn/grafana-alloy.env`) is rejected:
write access to any ancestor is enough to replace a root-owned `0600` file. Both
cloud URLs must be `https://`, whichever half they come from.
`config.alloy` reads each env-provided value at load time with `sys.env("GC_…")`
— Alloy has **no** `--config.expand-env` flag, so a `${GC_…}` placeholder would be
a literal string, not an expansion. The file on disk stays free of secret
literals, and the role only ever greps shapes on the host rather than reading
values back.

With the flag off, the role removes the unit, rendered config, state directory
and service account **it installed** — identified by the managed-by marker in
`/etc/systemd/system/alloy.service`. An Alloy installed by anything else (the
upstream apt repo, another role, by hand) carries no marker and is left strictly
alone, which matters because the flag is `false` by default on every host.
Binary/package removal is manual.

## What lands in Grafana Cloud

| Signal | Job label | Where it shows up |
| --- | --- | --- |
| Node `/metrics` | `decdn-node` | your own dashboards/queries |
| Machine metrics | `integrations/node_exporter` | Grafana Cloud's **Linux Server** integration dashboards + alerts, unmodified |
| journald | `integrations/node_exporter` | the same integration's logs dashboards (correlated by `instance`) |
| Alloy self-metrics | `integrations/alloy` | agent health |
| Traces | — | Application Observability |

Changing `grafana_alloy_host_job` / `grafana_alloy_logs_job` away from
`integrations/node_exporter` silently un-wires the prebuilt dashboards; that is
why they are knobs with a warning rather than hard-coded literals.

## Machine monitoring: what it costs and how to bound it

Grafana Cloud bills on active series and log volume, so the defaults are
deliberately lean and every lever is a variable:

- `grafana_alloy_host_collectors` is a **hand-picked replacement** for
  node_exporter's ~45-collector default set (Alloy's `set_collectors`: anything
  not listed is off). Widen with `grafana_alloy_host_extra_collectors`, veto with
  `grafana_alloy_host_disable_collectors` — the veto is applied to both lists at
  render time, because upstream applies its own `disable_collectors` *before*
  `enable_collectors` and would otherwise leave a vetoed collector running. Names
  are checked against a committed inventory (`vars/main.yml`): an unknown
  collector is not a startup error, it is silently ignored, so a typo would ship
  fewer metrics forever with nothing to show for it.
- `systemd` is the one non-default collector enabled, and it is scoped by
  `grafana_alloy_host_systemd_unit_include` to the units that matter rather than
  every unit on the box. It answers "is `decdn-node` actually running" — which
  the daemon's own `/metrics` cannot, because a dead daemon serves nothing.
- Host metrics scrape at `60s`, not the node's `30s`.
- The `filesystem` / `netdev` / `disk` exclude regexes drop virtual filesystems
  and container/virtual interfaces.
- journald drops `debug` priority and a noisy-unit list
  (`grafana_alloy_logs_drop_priority_regex` / `_drop_unit_regex`, `""` disables
  either), and `grafana_alloy_logs_max_age` bounds the catch-up burst after an
  outage — without it a restart can replay days of journal in one go.

## Hardening: the two relaxations machine monitoring requires

The unit is stricter than Grafana's own shipped unit (which has no `Protect*`
directives at all), but two directives are incompatible with host telemetry and
are relaxed **only** when the matching signal is enabled:

| Directive | Condition | Why |
| --- | --- | --- |
| `ProtectHome=read-only` (instead of `true`) | host metrics on | `ProtectHome=true` replaces `/home`, `/root` and `/run/user` with empty tmpfs mounts inside the unit's namespace, so the filesystem collector measures the overlay instead of the disk — a full `/home` would never raise an alert. `read-only` keeps the privilege boundary: the agent still cannot write there. |
| `SupplementaryGroups=systemd-journal adm` | logs on, and the groups exist | Reading the journal as a non-root user requires **both**. Without them `loki.source.journal` starts without error and collects **nothing** — the worst failure mode there is. The role joins the `alloy` account to the same groups, and lists only groups that exist, because systemd refuses to start a unit naming one that does not. |

Everything else stands: `NoNewPrivileges`, `ProtectSystem=strict`,
`SystemCallFilter=@system-service`, `PrivateDevices`, `RestrictNamespaces`, the
dedicated unprivileged account. The default collector set deliberately excludes
the collectors that would need capabilities or a widened syscall filter (`perf`,
`processes`, the netlink-based ones). `AF_UNIX` — already allowed for journald —
is also what the `systemd` collector uses to reach the D-Bus system bus.

## Variables

All prefixed `grafana_alloy_*` (see `defaults/main.yml` for comments and pinned
upstream version/sha256). Highlights:

| Variable | Default | Notes |
| --- | --- | --- |
| `decdn_grafana_cloud_enabled` | `false` | THE opt-in switch (mirrored in `decdn_node`) |
| `grafana_alloy_install_method` | `release` | `manual` copies a control-machine binary (CI stubs) |
| `grafana_alloy_version` / `grafana_alloy_sha256` | pin | Bump together from upstream release digests |
| `grafana_alloy_trace_sampling_ratio` | `0.25` | Trace keep-ratio, validated to `[0,1]` |
| `grafana_alloy_otlp_grpc_port` | `4317` | Hard-coupled to the literal emitted into node.toml |
| `grafana_alloy_region` | `decdn_region` | Required identity attribute; derived from the node region |
| `grafana_alloy_host_metrics_enabled` | `true` | Machine metrics (Alloy's in-process `node_exporter`) |
| `grafana_alloy_host_collectors` | 13 collectors | Replacement set; `_host_extra_collectors` adds, `_host_disable_collectors` vetoes |
| `grafana_alloy_host_scrape_interval` | `60s` | Host metrics only; the node keeps `30s` |
| `grafana_alloy_host_systemd_unit_include` | `(decdn-node\|alloy\|ssh\|sshd)\.service` | Scope of the per-unit `systemd` collector |
| `grafana_alloy_logs_enabled` | `true` | journald → Grafana Cloud Loki |
| `grafana_alloy_logs_max_age` | `12h` | Bounds the catch-up burst after an outage |
| `grafana_alloy_self_metrics_enabled` | `true` | Alloy's own health |
| `grafana_alloy_prom_url` / `_prom_username` / `_otlp_endpoint` / `_otlp_username` / `_loki_url` / `_loki_username` | `""` | Non-secret connection settings; empty ⇒ read the matching `GC_…` env key (`_otlp_username` then falls back to the Prometheus ID) |
| `grafana_alloy_node_job` / `_host_job` / `_self_job` / `_logs_job` | see table above | Job labels; the `integrations/…` ones are what Grafana Cloud's dashboards match |

Label variables (`service_name`, `service_namespace`, `instance_id`,
`deployment_environment`, `region`) ship on EVERY series/span/log line — keep
them low-cardinality; unique label sets are what your Grafana Cloud bill scales
with. Guardrails: one scrape interval per fleet (`30s` node / `60s` host),
sampling above zero for spans, the curated collector set, the journald drops, and
no per-request/per-hash label values.

## Couplings & guards

Two couplings between roles are pinned by constants plus molecule assertions:

1. This role's `prometheus.scrape` targets `127.0.0.1:<decdn_metrics_port>`, using
   the node role's configured metrics port directly.
2. `decdn_node` injects `otlp_endpoint = "http://127.0.0.1:4317"` when the flag
   flips on — the port constant here.

If you move either default, update BOTH sides and the molecule guard in
`ansible/molecule/grafana-cloud/`.

## Testing

Three layers, because the first one cannot prove correctness on its own:

1. **`grafana-cloud` molecule scenario** — the role end-to-end against a *stub*
   binary (plumbing, rendered content, hardened unit, group membership, teardown
   scope), plus negative preflight cases in `validation` and disabled-path
   assertions in `default`. The stub exits 0 for every subcommand, so a green run
   says nothing about whether Alloy can load the config. It also runs in a
   container with no D-Bus and no real journal, so the `systemd` collector and
   journald collect nothing there — expected, and not what this layer proves.
2. **`make lint-alloy`** (CI job `alloy-config`) — renders these templates in
   eight variable combinations (defaults, minimal identity, fully overridden,
   host-metrics-only, logs-only, every sub-knob off, inventory-supplied
   endpoints, vetoed collector + blanked node job) and feeds them to the REAL pinned Alloy binary: `alloy validate`
   (component graph, not just syntax), a check that every `ExecStart` flag exists
   in `alloy run --help`, and greps proving each Jinja branch actually switched —
   including that "every sub-knob off" reproduces the pre-machine-monitoring
   pipeline and that no token is ever rendered as a literal. See
   `ansible/tests/alloy-config/`.
3. **Deploy time** — the role runs `alloy validate` against the just-rendered
   file with the installed binary before any restart.

Only a real host proves *collection*: check `journalctl -u alloy -e` and Alloy's
loopback UI (`127.0.0.1:12345`) after the first deploy.

Re-run `make lint-alloy` whenever `grafana_alloy_version` is bumped: the harness
downloads the same digest-pinned `.deb` the role installs, so a version bumped
without its sha256 fails there rather than on a host.
