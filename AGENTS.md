# AGENTS.md — decdn-devops

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in the deCDN
DevOps repo. Each component has a README that holds its mechanics; this file holds the
map, the rules, the couplings between components, and what only an agent editing the
repo needs to know.

## What this repo is

The official DevOps project for deploying deCDN. It serves **two kinds of operator**,
and every entry point is split along that line:

- **Node operators** run cache nodes (`decdn-node`, no origin backend): `node.yml` /
  `make deploy-node`, `cloud-init/user-data-node.yaml`, Compose's `node` profile, the
  chart, the `decdn.node` collection. Front door: `docs/node-operators.md`.
- **Publishers** own namespaces in `PublisherRegistry` and run **origin nodes** (the
  same daemon with an origin backend, seated on-chain via `OriginAssignment.addOrigin`,
  ADR 002/011), and optionally `sponsord` + its onramp, iroh relays, an iroh DNS
  server and a public gateway: `publisher.yml` / `make deploy-publisher`, `cloud-init/user-data-publisher.yaml`,
  Compose's `origin`/`onramp`/`relay`/`dns`/`gateway` profiles, the chart (an origin node only),
  the `decdn.publisher` collection. Front door: `docs/publishers.md`.

Four deploy paths: **Ansible** (`ansible/`, VMs/bare metal and fleets; with cloud-init
the only path that hardens the host; also the two Galaxy collections), **cloud-init**
(`cloud-init/`, one VM that runs the playbook on itself), **Docker Compose** (`compose/`,
one Docker host, the recommended quickstart) and a **Helm chart** (`charts/decdn-node/`).

This repo is **infrastructure only**, not a source of truth for protocol or economic
claims — those trace to the deCDN ADRs. The only protocol facts it carries are the
contract addresses in the generated `vars/main/networks.yml` mirrors; never hand-copy
them into inventory or docs.

## Hard rules

1. **Never commit secrets.** No passwords, private keys, API tokens or keystores in any
   tracked file. Secrets are generated on, or operator-provisioned to, the target host
   under `/etc/<svc>/` at `0600` with a dedicated owner; the repo ships `*.example`
   templates for secret files only. `.gitignore` is a backstop, not the design. The Helm
   chart never creates a Secret: it references `existingSecret`, injects named env keys
   only (never `envFrom`: `DECDN_*` env overrides `node.toml`), keeps the keystore
   password off the PVC, and refuses secret-bearing keys in `config`.
2. **Localhost-only by default.** Daemons bind `127.0.0.1`; a public service declares
   its holes via `baseline_extra_inbound`, and an HTTP service sits behind a reverse
   proxy with the backend on loopback. Never bind a *backend* to `0.0.0.0`. The
   exceptions, each public by design and each asserting its metrics onto loopback:
   - `sponsord-onramp` behind the role's nginx (tcp/80 + tcp/443): Turnstile guards the
     one spending action (`POST /v1/fund`), per-address rate limits cover the rest;
     nginx sets `X-Forwarded-For` to the client it saw, never appends a client's.
   - `decdn gateway` behind the role's nginx (tcp/80 + tcp/443): every request spends
     its pool, bounded by the gateway's own daily allowance; nginx's per-address
     `limit_req` covers `PUT /_pointer`, since the gateway reads no `X-Forwarded-*`.
   - `iroh-relay` (tcp/80, tcp/443, udp/7842) and `iroh-dns-server` (tcp/443, udp/53 +
     tcp/53) terminate their own TLS (TLS-ALPN-01; QUIC address discovery needs the
     certificate in-process), so no proxy. On Compose they run as uid 0 holding
     `NET_BIND_SERVICE` and nothing else (host networking gives a non-root process no
     way to bind 443); `compose/tests/invariants.jq` allows uid 0 only for its
     `root_allowed` list with `cap_add` exactly `[NET_BIND_SERVICE]` — never extend it
     for another reason.
   - The chart binds the node's metrics `0.0.0.0` inside the pod, only behind a
     ClusterIP Service and the NetworkPolicy (`metrics.networkPolicy.from`); disabling
     the policy fails the render unless `networkPolicy.allowUnrestrictedMetrics=true`.
     Never front metrics with a LoadBalancer/NodePort/Ingress.
3. **Role templates render to their target paths** (`templates/decdn-node.service.j2` →
   `/etc/systemd/system/`), with secrets generated on the host at `0600`.
4. **Scripts are idempotent and fail loud.** `set -euo pipefail`, re-runnable, refuse to
   overwrite existing secrets, typed confirmation before destructive ops.
5. **Show before installing.** Present the files; the playbook run on the target
   (`make deploy`) is what mutates a host — it runs there, not here.

## Layout

```
ansible/                # the deployment project (DevSec-hardened, lean roles); see ansible/README.md
  playbooks/            # site.yml = node.yml + publisher.yml (origin.yml, sponsord.yml (+ onramp), iroh_relay.yml, iroh_dns_server.yml, decdn_gateway.yml); backup.yml, decommission.yml
  roles/                # baseline, decdn_node, grafana_alloy, sponsord, sponsord_onramp, iroh_relay, iroh_dns_server, decdn_gateway — each with a README
  inventory/ galaxy/ molecule/
cloud-init/             # user-data-{node,publisher}.yaml + on-host bootstrap.sh; pinned ansible-core/collections (README.md)
compose/                # one-host Docker Compose path (README.md)
  compose.yaml          # profiles: node / origin (one decdn-node), sponsord, onramp (+ sponsord), relay, dns, gateway, alloy
  alloy/config.alloy    # GENERATED from roles/grafana_alloy's config.alloy.j2 (scripts/render-compose-alloy.sh)
  decdn-compose         # the operator's wrapper: init, check, guarded up/stop/restart/down, health, cli, backup
  tests/*.jq            # lint-compose: bind-sources, invariants, inline-env, fail-closed
  tests/test_decdn_compose.py  # the wrapper's unit tests (make test-scripts)
charts/decdn-node/      # Helm chart (README.md); ci/ values mirror molecule/schema's three plays; files/monitoring -> ../../../monitoring/decdn-node (symlink); tests/render-test.sh (make lint-helm); artifacthub-repo.yml
monitoring/             # Grafana dashboards + Prometheus rules, maintained here by hand: decdn-node/ (rendered by the chart), sponsord/, iroh-relay/, iroh-dns-server/, decdn-gateway/ (the last three + exported-metrics.txt); README.md
docs/                   # cross-path operator docs: node-operators.md, publishers.md, requirements.md, lifecycle.md
examples/collection-fleet/  # consumer project for the collections, with its own CI, pre-commit and AGENTS.md; its inventory/ mirrors ansible/inventory/'s templates byte for byte except the hosts-*.yml.example comment headers (make test-scripts checks both parse to the same inventory): change both. release.sh moves its requirements.yml floors; its action SHAs and hook revs track this repo's (make test-scripts); galaxy/check-playbooks.sh runs it against the built collections
scripts/                # upstream mirrors (sync-network-profiles.py, gen-schema-keys.py), render-compose-alloy.sh, the decdn bump (open-decdn-bump.sh, bump_decdn.py), fetch-decdn-cli.sh, release.sh (+ cliff.toml, chart-artifacthub-changes.py), molecule.sh, limit-guard.sh
```

**Generated — regenerate, never hand-edit.** From upstream, at the tag of the newest
decdn/decdn release in the line `decdn_node_version` pins: the four
`roles/*/vars/main/networks.yml` mirrors (`scripts/sync-network-profiles.py`; the file
carries its upstream commit) and `ansible/molecule/schema/files/schema-keys.txt`
(`gen-schema-keys.py`). From this repo: `compose/alloy/config.alloy`, the
`grafana_alloy` template rendered in its `compose` runtime
(`scripts/render-compose-alloy.sh`); `make test-scripts` fails while it differs from a
fresh render, `make lint-alloy` runs it. The weekly `upstream-drift` workflow flags
stale mirrors and a new upstream release line.

**Pinned upstream releases.** One decdn/decdn release line is pinned across every
path, by four role defaults that must agree (`decdn_node_version` = `sponsord_version`
= `sponsord_onramp_version` = `decdn_gateway_version`, today `0.3`): one decdn/decdn
release (`vX.Y.Z`, the whole workspace, no per-crate tags) ships `decdn-node`,
`decdn`, `sponsord` and `sponsord-onramp`, their four images and one `SHA256SUMS`. A line, `X.Y`, is what the
role defaults, the onramp's installer pin (`sponsord_onramp_decdn_release`, `vX.Y`) and
the chart's `appVersion` name: the roles install its newest finished `vX.Y.N` on every
run (`tasks/resolve-release.yml`, copied into all four roles: GitHub's release list,
then the same signed `SHA256SUMS` and exact `--version` check against the resolved
version; the onramp reads the installers' digest from that release's verified
`SHA256SUMS`), and the chart's default image tag is the line's floating tag, pulled
`Always`. An exact `X.Y.Z` in inventory (or `image.tag`/`image.digest`) holds a host on
one release. So an upstream patch release needs no release of the collections or the
chart; a new line does. What cannot resolve a line names one release of it and moves
on every upstream release, repo-only: `compose/.env.example`'s three image digests, the
onramp's installer pin in `compose/sponsord-onramp.env.example` (tag + `SHA256SUMS`
digest), the chart's example digest, the commented exact-pin examples, and the
generated mirrors (which a patch is not expected to change; when one does, the bump PR
says so and the collections need a release). cloud-init takes the role defaults at
`DEVOPS_REF`. Docs name the pin (`decdn_node_version`, `sponsord_version`), never its
number: besides this paragraph, only the commented examples and the comments beside a
pinned value name a number, and they move with the pin (`bump_decdn.py` moves all of
them). `make test-scripts` checks the pins agree with each other, the Compose example (a
release of the line), `appVersion`, the chart's `artifacthub.io/images` tag and this
paragraph, and that the vendored KEYS (four byte copies of decdn's) hold the keys
SECURITY.md publishes; the weekly `upstream-drift` job checks the exact copies and the
mirrors against the line's newest release and flags a newer upstream line. Bump with
the checklist in `roles/decdn_node/README.md`; `scripts/open-decdn-bump.sh` opens the
bump's PR (decdn's `sign-release.sh` runs it after each release). Upstream is public
and also publishes the binaries as crates (`decdn-node`, `decdn-cli`, `sponsord`,
`sponsord-onramp`); the roles do not install from crates.io (no maintainer signature).

**Monitoring assets** (`monitoring/`, see its README and
`.claude/skills/grafana-dashboards/SKILL.md`): upstream ships none. Every `decdn_*` /
`sponsord_*` series a panel or rule names must be one the daemon exports (the node's
`/metrics` and upstream's `adr/appendix-observability.md` registry, where a `planned`
row emits nothing; decdn/decdn's `crates/sponsord/src/metrics.rs`) — nothing in CI
checks those names, so a typo renders `(no data)` or a rule that never fires. The
relay's `relayserver_*`, the DNS server's `dns_server_*` and the gateway's
`decdn_gateway_*` names *are* checked, against each one's `exported-metrics.txt`, the
metrics of the pinned `iroh-relay`, `iroh-dns-server` and decdn: re-capture the relay's
when bumping `iroh_relay_version`, the DNS server's when bumping
`iroh_dns_server_version`, the gateway's when the decdn line moves.
The chart renders `monitoring/decdn-node/` through the `files/monitoring` symlink
(`.Files` cannot read outside the chart), never through `tpl` (the alert annotations
carry Prometheus templates), so copy a chart tree with `cp -RL`. Alert rules have
promtool unit tests (`prometheus-alerts_test.yml`, run by `make lint-helm`).

## Components: where the detail is, and what only this file says

The README beside each component is the reference for what it installs, its
variables, gates and day-2 operations. Below is only what crosses component
boundaries or exists nowhere else.

### `ansible/` and `roles/decdn_node` (`ansible/README.md`, `roles/decdn_node/README.md`)

- Entry point per persona: `playbooks/node.yml` (`make deploy-node`),
  `playbooks/publisher.yml` (`make deploy-publisher`), `site.yml` (`make deploy`) for
  both. **Origin nodes** are `decdn_origin_nodes`, a child of `decdn_nodes` (they
  inherit the firewall hole, backup, decommission, relay allowlist and Alloy scrape),
  deployed by `origin.yml`; node.yml's play is `decdn_nodes:!decdn_origin_nodes`, so
  each node runs once under site.yml. Group-membership checks (an origin outside
  `decdn_nodes` or without a backend, a backend outside `decdn_origin_nodes`, an onramp
  host outside `sponsord_hosts`) live in the playbooks' `pre_tasks`, **never in a
  role**, so collection users keep their own group names.
- Install methods (`decdn_node_install_method`: `release` default, `source`, `manual`)
  and the host-side source-build sandbox are in the role README. What is shared:
  `tasks/source.yml` and `files/install-build-output.py` are copied into both sponsord
  roles and kept identical, with the `decdn_build_*`/`decdn_rustup_*` defaults, by
  `make test-scripts`; so are the `decdn_decommission_*` cap and timeout in all five
  roles' defaults. Decommission asks one typed confirmation per run, in the first play
  that reaches a host, listing every service it covers
  (`_decdn_decommission_confirmed`).
- **Config-schema coupling.** `templates/node.toml.j2` renders against
  `decdn/crates/common/src/config/types.rs`, where every section is
  `#[serde(deny_unknown_fields)]` with no aliases: a key the installed binary does not
  know is a startup crash-loop. Two guards: the role runs `decdn config validate`
  against the real binary after templating, and `molecule/schema` checks the rendered
  key set against `schema-keys.txt` (`gen-schema-keys.py` refuses a config struct its
  `STRUCT_PATHS` does not map). Re-sync both when bumping decdn. `make lint-helm` runs
  the same check on the chart's rendered ConfigMap.
- `[self_update]` is CLI-only: the role and `decdn-compose init` render `check = false`
  and `decdn-compose cli` sets `DECDN_SELF_UPDATE_CHECK=0`, so a managed host never
  hears "run `decdn self-update`", which would replace the CLI outside the signed
  install and fail the role's version check.

### `roles/grafana_alloy` (its README, § Couplings & guards)

- **`make lint-alloy` is the gate that matters**: the molecule stub exits 0 for
  everything, so only the real pinned binary proves a rendered config loads, and it is
  the only thing that evaluates OTTL and `sys.env` (`alloy validate` does neither).
- **One template, two runtimes.** `config.alloy.j2` also renders Compose's
  `compose/alloy/config.alloy` when `_ga_runtime` is `compose` (set by the render
  playbook, never an operator knob): identity comes from `sys.env(...)` through the
  `ga_str` macro (a `sys.env:` prefix renders as a lookup), each daemon's scrape is
  gated on `DECDN_COMPOSE_PROFILES` (`_ga_compose_profiles`; the wrapper's unit tests
  check it matches `PROFILES`), and journal lines get `unit` from `CONTAINER_NAME`
  (`_ga_compose_units`) so every `unit`-keyed rule and dashboard applies unchanged.
  The systemd render must not change with the compose branch: diff `render.yml`'s
  output before and after a template edit.

### `roles/sponsord` and `roles/sponsord_onramp` (their READMEs)

- **Top-up hold guard.** A restart forgets a held, unconfirmed pool top-up and the pool
  can be refilled twice, so `tasks/topup-hold.yml` reads `/metrics` before the role
  queues a restart and before decommission stops the daemon. **The restart-inputs
  comparison is the role's only restart trigger**: never add `notify: Restart sponsord`
  to a task; make its file a hashed input instead, or the restart skips the guard.
  `decdn-compose` makes the same check (`hold_state`) before stop/restart/down and a
  recreating `up`, which it detects with `--dry-run up` (`config --hash` differs from
  the container label on older Compose).
- Molecule under docker needs `/` `--make-rshared` (`molecule/sponsord/prepare.yml`)
  or every credential directory is empty.
- `sponsord_onramp_rpc_url` is served to every user: preflight refuses userinfo, a
  query and the characters the installers cannot quote.

### `roles/iroh_relay` and `roles/iroh_dns_server` (their READMEs)

- Both daemons ignore unknown TOML keys and run on public defaults without a config, so
  the templates write every key, the units carry `AssertPathExists=` /
  `AssertFileNotEmpty=`, and the molecule stubs refuse keys upstream's `main.rs` does
  not define (that is what catches a template typo). The same key lists are held by
  `decdn-compose` as `RELAY_KEYS` / `DNS_KEYS`: a new key goes in the template, the stub
  and the wrapper (its unit tests compare them with the stub's).
- Port guards (`tasks/ports.yml`) test the holder's cgroup against the unit's whole
  path, not a MainPID read beforehand, which is 0 while a unit waits to restart (#113).
  The DNS guard is address-aware for 53 and names `DNSStubListener=no` when resolved's
  stub is the holder; the role never touches the host's resolver.
- A version bump (`iroh_relay_version`, `iroh_dns_server_version`, both tracking the
  iroh decdn builds against) moves every per-target sha256, the image digest and
  version comment in `compose/compose.yaml`, `DNS_VERSION` in `decdn-compose` and each
  one's `exported-metrics.txt` (`make test-scripts` checks the names agree). The
  relay's allowlist play reads `decdn whoami` on every `decdn_nodes` host by
  `delegate_to`, so `LIMIT=<relay>` still needs those hosts reachable; relays deploy
  `serial: 1`.

### `roles/decdn_gateway` (its README)

- It runs the `decdn` CLI (`decdn gateway --public-url`) from its own path,
  `/usr/local/lib/decdn-gateway/decdn`, never `/usr/local/bin/decdn`, which a
  co-located node's role pins and stamps. It always passes `--keystore`: the CLI's
  default lookup (`~/.decdn/client/keystore.json`) is not where `decdn key-gen`
  writes.
- The gateway stops cleanly only on SIGINT (`KillSignal=SIGINT`; Compose needs
  `stop_signal: SIGINT`). A restart forgives the day's allowance (in-memory counters)
  and drops the pulls in flight, so the restart-inputs comparison is its only restart
  trigger, as sponsord's: never add `notify: Restart decdn-gateway` to a task.
- nginx is the distro package, so unattended-upgrades patches it; with the onramp's
  (also distro nginx), these are the only internet-facing TLS terminators in this
  repo that it patches. Its
  certificate is a wildcard for `<domain>` and `*.<domain>` from lego over ACME DNS-01
  (sha256-pinned per architecture; bump the version and both digests together). The
  onramp's single-name certificate is the same lego over HTTP-01 (webroot, no DNS
  credentials): its `sponsord_onramp_lego_*` pin must equal `decdn_gateway_lego_*`
  (`make test-scripts` checks). Each role refuses nginx sites it did not enable, so
  the gateway and the onramp need separate hosts. Stock nginx cannot issue on
  demand, so the hint host `<ns>.<hash32>.<domain>`, which the gateway's `?ns=`
  redirect produces, has no certificate: decdn/decdn#2784 asks upstream for a
  single-label form.
- The site adds no header: the gateway sets its own CORS (a second
  `Access-Control-Allow-Origin` breaks browsers), routes on the exact `Host`, and reads
  no `X-Forwarded-*`. Per-client limits on `PUT /_pointer` are nginx's `limit_req`.
- Compose's `gateway` profile runs the gateway only, on the node image's `decdn`
  (`DECDN_IMAGE_DIGEST`, so no fourth decdn digest), with the operator's own TLS proxy:
  stock nginx cannot bind 80/443 as non-root on the host network, and `root_allowed`
  is not extended for it. Its `gateway.toml` holds `rpc_url = "${DECDN_GATEWAY_RPC_URL}"`
  (the CLI expands it), the URL itself in the root-only env file.

### `cloud-init/` (its README)

- The roles are used unchanged, so a role change reaches this path with no edit here —
  except a **new secret file**, which needs an entry in `bootstrap.sh`'s `SECRETS`, the
  lint's `FORBIDDEN_VARS`, the per-group `case` arm that prints next steps, and the
  README's table; a **new host group** needs its own `case` arm plus `HOST_GROUPS` and
  lint.py's `GROUPS` (`make test-scripts` checks all three).
- The baseline-only first boot trusts every node/origin/sponsord play to run `baseline`
  tagged `baseline`; `cloud-init/baseline-plays.sh` checks that per play at boot and
  `make test-scripts` checks it here. When `ansible/requirements.yml` changes, re-sync
  `collections.lock.yml` (`make lint-cloud-init` checks coverage).
- The molecule `cloud-init` / `cloud-init-publisher` scenarios are the **only coverage**
  of the node's and the onramp's release download-and-verify path.

### `compose/` (its README)

- `decdn-compose` checks values as Compose renders them (`rendered_environments`,
  `parse_env` as fallback), fills chain values through `network_profile`, which parses
  the mirrors' fixed shape (keep the shape, or update the parser), and finds running
  containers by Compose's project labels, not `compose ps`, which loads disabled
  services' env files. No CI job runs it end to end: try a change in a throwaway
  `docker:27-dind` (privileged) with a `compose.override.yaml` that sets a non-journald
  logging driver.
- The onramp's entrypoint script is pinned byte for byte in `invariants.jq`
  (`onramp_entrypoint`): change both together.
- **No `${VAR:?}`**: Compose interpolates disabled services too, so a required variable
  breaks other profiles. An unset variable must render a value its service refuses.
- `make lint-compose` reads the file as written against `bind-sources.jq`
  (`create_host_path` is checked on the source because Compose releases render it in
  opposite ways and default it differently — never move it into the render-based
  invariants), then renders with `--profile '*'` under `env -i` three times: the
  example `.env` against `invariants.jq` (allowed keys, exact mounts), every service env
  file pointed at `/dev/null` against `inline-env.jq` (no RPC URL in the tracked file),
  an empty `.env` against `fail-closed.jq`. **The allow-lists are deliberate friction**:
  a new key, mount or inline env var fails until added to the matching list, and the PR
  should say why. KICS flags the Alloy mount's `rslave` propagation HIGH (query
  `baa452f0`, excluded with its reason in the root `Makefile`; `invariants.jq` refuses
  propagation on any other mount).
- **CI's Compose is older than a dev box's**: v2.33 lacks `config --no-env-resolution`,
  which is why the inline-env render uses `/dev/null` env files. Before relying on a
  newer `config` flag, try it under `docker run --rm -v "$PWD:/w" -w /w docker:27-cli
  docker compose …`.

### `charts/decdn-node/` (its README)

- The config-schema coupling above applies (`make lint-helm`), and CI's `helm` job runs
  the real `decdn config validate` on every `ci/*.yaml` render against the newest
  `decdn` of the `appVersion` line (`scripts/fetch-decdn-cli.sh`), so a decdn bump PR
  validates the chart against the new release.
- The full name is capped at 52 characters: a longer StatefulSet creates no pod.

## Commands

Two Makefiles: the **root** is the check driver CI calls (`make help`); **`ansible/`**
drives deploys (its targets must run from `ansible/`). The full target list is in
[CONTRIBUTING.md](CONTRIBUTING.md#make-targets).

```bash
# Root — the gates (CI runs the same)
make lint             # every pre-commit hook, every file (also the CI `pre-commit` job)
make lint-ansible     # vendor collections + ansible-lint (production profile)
make molecule         # every ansible/molecule/*/ scenario in parallel (Docker; JOBS=<n>, SCENARIOS='a b')
make molecule-changed # only those your branch can affect, as CI picks them (CHANGED_FROM=origin/main)
make lint-helm        # chart: lint + render tests + kubeconform + promtool + schema keys
make lint-alloy       # grafana_alloy config against the real pinned Alloy binary
make lint-compose     # compose/ invariants (the file as written + three renders, compose/tests/*.jq)
make lint-cloud-init  # cloud-init/user-data*.yaml: schema + invariants (no secrets, release mode, lock)
make test-scripts     # Makefile/molecule-driver guards, release gate, lint-compose/lint-cloud-init negatives, decdn-compose unit tests
make security         # KICS over ansible/, the rendered chart and compose/

# Ansible — run from ansible/
make deps                          # vendor pinned Galaxy collections
make check / deploy                # site.yml; fleet-wide unless LIMIT=<host>; INVENTORY=<overlay>
make check-node / deploy-node      # node.yml only (node operators: cache nodes)
make check-publisher / deploy-publisher # publisher.yml only (origins, sponsord, relays, DNS, gateways)
make check-origin / deploy-origin  # origin.yml only (decdn_origin_nodes)
make check-sponsord / deploy-sponsord   # sponsord.yml only (sponsord_hosts)
make check-relay / deploy-relay         # iroh_relay.yml only (iroh_relay_hosts)
make check-dns / deploy-dns             # iroh_dns_server.yml only (iroh_dns_server_hosts)
make check-gateway / deploy-gateway     # decdn_gateway.yml only (decdn_gateway_hosts)
make backup / decommission LIMIT=… # lifecycle playbooks (decommission requires LIMIT)
make build / galaxy-check          # both collections (build-node, galaxy-check-publisher, … for one)
```

**Inventory is private; the firewall hole is not.** `ansible/inventory/hosts.yml` is
git-ignored and a real fleet lives in a private overlay. Inventory-adjacent group_vars do
not load for an overlay, so anything every host needs lives in
`ansible/playbooks/group_vars/`: the public holes (`baseline_extra_inbound`: the node's
udp/4433, tcp/80 + tcp/443 on `sponsord_onramp_hosts` with `sponsord_onramp_proxy: nginx`,
tcp/80 + tcp/443 + udp/7842 on `iroh_relay_hosts`, tcp/443 + udp/53 + tcp/53 on
`iroh_dns_server_hosts`, tcp/80 + tcp/443 on `decdn_gateway_hosts`) are built from a host's groups in `all.yml`
(`_baseline_service_inbound`) and every group file sets `baseline_extra_inbound` to that
list, so a co-located host renders one firewall in every play.
`ansible/tests/firewall-holes/` (`make test-scripts`) pins the result per host shape. The
Alloy per-daemon toggles also live in `all.yml`. Don't move any of it back under
`inventory/`.

**Galaxy collections and releases** (`ansible/README.md` § Packaging, RELEASING.md). The
eight roles ship as `decdn.node` (`baseline`, `decdn_node`, `grafana_alloy`) and
`decdn.publisher` (`sponsord`, `sponsord_onramp`, `iroh_relay`, `iroh_dns_server`,
`decdn_gateway`; depends on `decdn.node`). Each overlay is `ansible/galaxy/<collection>/`: `roles.txt` is
the one role list (a new role goes in exactly one; `make test-scripts` checks),
`playbooks.txt` lists the playbooks it ships (a new playbook goes in at least one, with
every `import_playbook` target in the same one). There is **no** `galaxy.yml` at the
`ansible/` root, and `galaxy/stage-playbooks.py` rewrites role references to FQCNs at
staging only: never qualify them, or add `collections:`, in `ansible/playbooks/`.
`decdn.node`'s node-only `backup.yml`/`decommission.yml` in `galaxy/node/playbooks/` are
kept equal to the fleet-wide plays by `make test-scripts`: change both. Releases are cut
on `main` by `scripts/release.sh` (git-cliff; dry run unless `--execute`) from
conventional PR titles (the repo squash-merges, so the PR title is the changelog entry;
`pr-title.yml` checks it): never edit a CHANGELOG by hand or add an `[Unreleased]`
section (release.sh refuses one), and never write the chart's `artifacthub.io/changes`
annotation by hand. The chart's `decdn-node-X.Y.Z` tag shape and `release-chart.yml`
file name are its cosign identity: never rename them.

**CI.** `ci.yml` is the blocking gate: `pre-commit`, `scripts` and `actionlint` on every
PR, the Ansible, chart, compose and cloud-init jobs path-filtered, KICS on the first
three; `pr-title.yml` checks PR titles; `molecule.yml` runs one runner per scenario
(matrix from `make molecule-list`) with the `molecule` job as the aggregate check: every
scenario on a push to main, on a PR only those its changes can affect
(`scripts/molecule-affected.py`, which derives scenario -> file/role/playbook
dependencies from the tree, so a new scenario, include or stub needs no edit there; a
path it does not recognise selects them all).
`ansible-lint` is **not** a per-commit hook (it needs collections vendored): run
`make lint-ansible`.

**Molecule runs share the host's Docker daemon.** Scenario container names are fixed, so
`scripts/molecule.sh` (behind `make molecule`) takes a host-wide lock per scenario: a
*different* scenario does not block you, the *same* one refuses to start (exit 75). Run
what you changed with `make molecule-changed` or `make molecule SCENARIOS='…'` rather
than bare `molecule test -s`, which skips the lock. They also share one kernel pool,
root's `fs.inotify.max_user_instances` (128 stock): past it the next container's systemd
dies at boot and the scenario fails with "container … is not running", which is no
role bug. The default `JOBS` is sized to it (`jobs_width`), but runs side by side add
up. A scenario that grows slow is split along its side effects into a
sibling that reuses its prepare/converge/verify by path, with an identical inventory
(`make test-scripts` checks the pairs); add the sibling to `SLOW_FIRST` in
`ansible/Makefile` when it is among the slowest.
