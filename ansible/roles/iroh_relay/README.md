# Role: `iroh_relay`

Deploys `iroh-relay` from [n0-computer/iroh](https://github.com/n0-computer/iroh),
the relay server iroh peers fall back to. deCDN nodes and clients connect over iroh
QUIC. When two peers cannot hole-punch (roughly one connection in ten), their
traffic, still end-to-end encrypted, goes through a relay. The relay's QUIC address
discovery (QAD) also tells each peer the address it is seen at, which is what lets
most of them hole-punch in the first place.

Nodes use n0's public relays unless `decdn_relay_urls` names others. The ADRs expect
production to self-host dedicated relays as operational infrastructure, not as an
incentivized network role ([decdn/adr/architecture.md], "Trust Assumptions"). The
relay URL is not registered on-chain ([ADR 019]).

The relay is **public by design and terminates its own TLS**. It gets a Let's
Encrypt certificate itself (TLS-ALPN-01 on tcp/443), and QAD needs that same
certificate in-process, so there is no proxy in front of it. It binds tcp/80,
tcp/443 and udp/7842 on every address; its metrics stay on loopback. This is the
relay exception to AGENTS.md hard rule 2.

By default it **admits only listed endpoint IDs**: the deCDN nodes in the inventory
and any you add. See [Who may use it](#who-may-use-it) for what that means for
clients.

[decdn/adr/architecture.md]: https://github.com/decdn/decdn/blob/main/adr/architecture.md
[ADR 019]: https://github.com/decdn/decdn/blob/main/adr/019-node-onboarding.md

## What it does

- **Installs the binary.**
  - `release` (the default) downloads `iroh-relay-v<version>-<target>.tar.gz` from
    the iroh GitHub release and verifies it against the sha256 pinned in
    `iroh_relay_sha256` for the host's target triple. Upstream signs nothing, so the
    pin is all that vouches for it. A stamp (`/usr/local/lib/iroh-relay/installed-version`,
    `<version> <target> <pinned archive sha256> <binary sha256>`) skips re-downloading
    while the pin and the binary on disk are the ones it records, so a corrected pin
    or a binary replaced in place is downloaded and verified again. On every
    run `iroh-relay --version` must print exactly `iroh-relay <version>` (a `manual`
    binary only has to print a line starting with the word `iroh-relay`).
  - `manual` copies a binary from the control machine.
- **Templates `/etc/iroh-relay/iroh-relay.toml`** (root `0644`; nothing secret in it)
  with every key written out. iroh-relay ignores keys it does not know and runs on
  its built-in defaults when the file is missing: metrics on a public port, no TLS.
  The unit therefore asserts that the file exists and is not empty, and fails to
  start otherwise.
- **Runs it under a hardened unit.** It runs as a `DynamicUser` whose only privilege
  is `CAP_NET_BIND_SERVICE`. The Let's Encrypt account key and the certificate
  with its private key live in `StateDirectory=iroh-relay`
  (`/var/lib/private/iroh-relay/acme`, `0700`), so a restart reuses them. You
  provision no secret: the relay generates them itself. It sets `RUST_LOG` (iroh-relay logs only errors without it)
  and `NO_COLOR=1`, stops with `KillSignal=SIGINT` (the only signal it shuts down
  gracefully on), and sets `LimitNOFILE` (one socket per client).
- **Checks its inputs first.** The bind address is parsed as an IP address on the
  control machine (a port, a zone, loopback, link-local, multicast and
  IPv4-mapped forms are refused), and `::` is refused on a host with
  `net.ipv6.bindv6only=1`, where it would serve no IPv4 peer.
- **Refuses ports another process holds.** Before it changes anything, the role
  fails if anything other than the relay holds tcp/80, tcp/443 or the metrics port,
  or udp/7842 while QUIC address discovery is on. A web server or the sponsord-onramp's Caddy cannot share 80/443
  with the relay. `playbooks/iroh_relay.yml` also refuses a host in both
  `iroh_relay_hosts` and `sponsord_onramp_hosts`.
- **Gates the deploy.** After the start, loopback `/metrics` must answer, every
  listener must belong to the unit's `MainPID`, and the same process must still be
  up `iroh_relay_readiness_settle` seconds later (a relay that binds and then
  crashes does not pass). A failure stops the deploy. The relay binds all of this
  before it has a certificate, so the gate does not need one.
- **Checks the certificate.** Separately from the gate, the role fetches
  `https://<hostname>/healthz` on the relay's own address (`curl --resolve`; loopback
  for a wildcard bind) against the host's trust store and checks the version it
  reports. What happens next depends on
  `iroh_relay_certificate_check`:
  - `warn` (the default) reports a relay still waiting for its first certificate,
    as a changed task so it shows in the play recap. The first issuance needs DNS
    and tcp/443 from the internet, which the deploy cannot force. Once Let's Encrypt
    has issued a production certificate for this hostname (its cache file exists in
    the ACME directory), a failed check is a regression (expired, no longer
    reachable) and fails the deploy here too. With `iroh_relay_acme_staging` it only
    warns: staging certificates are never trusted.
  - `fail` fails the deploy.
  - `skip` does not look.
- **Restarts only on a change.** A hash record of the config, the unit and the
  binary (`/etc/iroh-relay/.relay-inputs.sha256`) restarts the relay when any of
  them changed since it last came up, including after a run that failed before
  its handler fired.

## Before the first deploy

1. **A DNS name.** Point an A record (and an AAAA record, if the host has IPv6) at
   the host, and set `iroh_relay_hostname`.
2. **Open ports at your provider.** The role's baseline firewall opens the three
   ports; a cloud security group or provider firewall must open them too:
   - tcp/80: iroh's captive-portal probe (`/generate_204`);
   - tcp/443: the relay itself, and Let's Encrypt's TLS-ALPN-01 challenge;
   - udp/7842: QUIC address discovery.
3. **An ACME contact.** Set `iroh_relay_acme_contact` to an email address. Let's
   Encrypt sends expiry warnings there.
4. **For a trial run,** set `iroh_relay_acme_staging: true` (pass it as JSON:
   `-e '{"iroh_relay_acme_staging": true}'`). Staging certificates are never
   trusted, so nodes cannot use the relay until you set it back to `false`. The
   point is to leave Let's Encrypt's production rate limits untouched.

In this repo, list the host in `iroh_relay_hosts` and run `make deploy-relay
LIMIT=<host>` (or `make deploy`, which includes it). The firewall holes come from
`playbooks/group_vars/all.yml`.

## Pointing nodes at it

Set the URL on the nodes, then re-deploy them:

```yaml
# inventory group_vars/decdn_nodes.yml
decdn_relay_urls:
  - https://relay1.example.org
  - https://relay2.example.org
```

Setting `decdn_relay_urls` **replaces** n0's relays; it does not add to them. A node
whose only relay is down has no fallback for peers it cannot hole-punch. Deploy
**at least two** relays, preferably in different regions, before switching a fleet
over. Clients (`decdn fetch`, `decdn probe --relay-url …`) take relays the same way.

## Who may use it

`iroh_relay_access` picks the mode:

- **`allowlist` (the default):** only the listed endpoint IDs may connect.
  - `playbooks/iroh_relay.yml` reads the ID of every host in `decdn_nodes` (`decdn
    whoami` on the node, as its decdn user; `tasks_from: node-ids`). It does this
    under `LIMIT=<relay>` too, because `delegate_to` ignores the limit.
  - `iroh_relay_allowlist` adds more: nodes outside this inventory, or clients that
    must use the relay. The IDs are 64 lowercase hex, as `decdn whoami` prints them
    (`node id: <hex>`).
  - **The deploy fails** if any inventory node's ID cannot be read (a node not
    deployed yet), and if the list ends up empty, because the relay would admit
    nobody.
  - A new node is admitted once the relay is re-deployed: the config changes and
    the relay restarts.
- **`denylist`:** everyone except `iroh_relay_denylist`.
- **`everyone`:** no restriction.

**What allowlist mode costs.** A peer reaches a node behind NAT through the node's
own relay. So a client that is not on the list (`decdn fetch`, an onramp user,
another operator's node) **cannot reach a node homed on this relay** when they
cannot hole-punch. They still connect directly when they can. Add the IDs of the
clients that must, or use `everyone` for a relay that serves clients.

`iroh_relay_allowlist_from_inventory: false` stops the inventory read; then only
`iroh_relay_allowlist` counts. A list set for a mode that does not use it is refused
rather than ignored. Collection users without this repo's playbook set
`iroh_relay_allowlist` themselves.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `iroh_relay_hostname` | `""` (**required**) | The DNS name nodes reach the relay at. No scheme, port or IP address. |
| `iroh_relay_acme_contact` | `""` (**required**) | The Let's Encrypt account's email address, without `mailto:`. |
| `iroh_relay_acme_staging` | `false` | Use Let's Encrypt's staging CA. Its certificates are untrusted. |
| `iroh_relay_install_method` | `release` | `release` or `manual`. |
| `iroh_relay_version` | `1.3.0` | The iroh release. Keep it on the iroh version decdn builds against (`decdn/Cargo.lock`). |
| `iroh_relay_sha256` | the v1.3.0 digests | Per-target sha256 of the release tarball. Bump it together with the version. |
| `iroh_relay_manual_bin_src` | `""` | `manual`: the control-machine path to the binary. |
| `iroh_relay_bind_address` | `::` | The public address for 80, 443 and 7842: `::` (every address, IPv4 included on a dual-stack host with `net.ipv6.bindv6only=0`), `0.0.0.0` (an IPv4-only host or kernel), or one of the host's own unicast addresses. |
| `iroh_relay_enable_quic_addr_discovery` | `true` | QUIC address discovery on udp/7842 (iroh-relay leaves it off by default). Set it in inventory: the firewall hole follows it. |
| `iroh_relay_metrics_bind` / `_port` | `127.0.0.1` / `9092` | Prometheus `/metrics`. Must be loopback, and the port must clear this repo's other listeners. |
| `iroh_relay_access` | `allowlist` | `allowlist`, `denylist` or `everyone`. See [Who may use it](#who-may-use-it). |
| `iroh_relay_allowlist` | `[]` | `allowlist`: endpoint IDs beyond the inventory's nodes, as 64 lowercase hex (what `decdn whoami` prints). |
| `iroh_relay_allowlist_from_inventory` | `true` | `allowlist`: add every `decdn_nodes` host's ID (read by `playbooks/iroh_relay.yml`). |
| `iroh_relay_allowlist_node_hosts` | `groups['decdn_nodes']` | The hosts whose IDs are read (not defined by the role; override in inventory). |
| `iroh_relay_denylist` | `[]` | `denylist`: endpoint IDs refused service, same form. |
| `iroh_relay_accept_conn_limit` / `_accept_conn_burst` | `""` | New connections per second server-wide, and the burst above that. `""` means unlimited. |
| `iroh_relay_client_rx_bytes_per_second` / `_client_rx_max_burst_bytes` | `""` | Per-client receive rate and burst (at most 4294967295; a burst needs a rate). |
| `iroh_relay_limit_nofile` | `65536` | The unit's `LimitNOFILE`. |
| `iroh_relay_log_level` | `info` | `RUST_LOG`: a level, or comma-separated `target=level` directives. |
| `iroh_relay_certificate_check` | `warn` | `warn`, `fail` or `skip`. See "What it does". |
| `iroh_relay_readiness_retries` / `_delay` | `30` / `2` | The gate's window: ~60 s for metrics to answer, then ~60 s more for every listener. |
| `iroh_relay_readiness_settle` | `5` | Seconds the same process must then stay up. `0` skips it. |
| `iroh_relay_certificate_retries` / `_delay` | `15` / `4` | The certificate check's window (~60 s). |

The ports (80, 443, 7842) are fixed in `vars/main.yml`. ACME's challenge comes to
443, and iroh clients assume 7842.

## Observability

With Grafana Cloud on (`decdn_grafana_cloud_enabled`), `playbooks/group_vars/all.yml`
turns on `grafana_alloy_iroh_relay_enabled` for `iroh_relay_hosts`. Alloy then:

- scrapes the relay's `/metrics` as `job="iroh-relay"`, `service_name=iroh-relay`;
- labels its journal stream `unit="iroh-relay.service"`, with a `level` parsed from
  each line.

The dashboard and alert rules are in
[`monitoring/iroh-relay/`](../../../monitoring/iroh-relay/). Certificate expiry is
not exported. Watch `https://<hostname>/healthz` with a blackbox or synthetic
check of your own.

## Day 2

- **Restarts.** A change to the config, the unit or the binary restarts the relay.
  Relayed connections drop and the peers reconnect, through another relay if they
  have one. Roll changes across relays one at a time (`LIMIT=`).
- **Certificates.** iroh-relay renews its certificate itself; nothing on the
  Ansible side needs to run. `journalctl -u iroh-relay | grep -i acme` shows the
  ACME exchange.
- **Upgrades.** Bump `iroh_relay_version` and every `iroh_relay_sha256` digest
  together, to the iroh version decdn moved to. Then re-capture
  `monitoring/iroh-relay/exported-metrics.txt` from the new binary (the command is
  in its header).
- **Privacy.** A relay sees the source and destination IP addresses of what it
  relays, and the timing, but not the content ([ADR 017], P-17).
- **Backup.** None. The relay holds no state worth one: Let's Encrypt re-issues
  the certificate on a new host.
- **Decommission.** `make decommission LIMIT=<host>` stops the relay and removes its
  unit. It keeps the binary, the config and the ACME state. Take the URL out of
  every node's `decdn_relay_urls` first.

[ADR 017]: https://github.com/decdn/decdn/blob/main/adr/017-privacy.md

## Testing

- `molecule/iroh-relay` converges `playbooks/iroh_relay.yml` against a stub relay
  on Debian 12 and Ubuntu 24.04. A molecule CA stands in for Let's Encrypt. The
  stub enforces the startup contract: only the config keys iroh-relay 1.3.0 knows,
  LetsEncrypt TLS, loopback metrics, and the rest.
  - The converge proves the unit's hardening and capability, the gate and the
    certificate check.
  - Its side effects prove:
    - a knob restarts the relay, and a running relay with no record is restarted;
    - the gate is fatal and records nothing, for a relay that never starts, one
      that skips its QUIC socket, and one that crashes after binding (the stub's
      marker files);
    - squatters on tcp/80 and udp/7842 are refused before any change (the UDP one
      only with QUIC address discovery on, which is also converged off);
    - a missing config fails the start;
    - an untrusted certificate fails in `fail` mode, warns in `warn` mode, and fails
      in `warn` mode once a certificate was issued;
    - `0.0.0.0` and a specific IPv4 address are rendered, bound and probed.
- `molecule/iroh-relay-install` runs the `release` method against a local mirror
  serving the stub as a release tarball: a wrong pin, the stamp, a re-run with the
  mirror down, a binary replaced in place, and a version the binary does not report.
  - the allowlist: the ID read from a stand-in node (a fake `decdn` on the relay
    host) merged with the listed one; a node without an identity fails the read;
    the `everyone` and `denylist` modes render as such.
- `molecule/iroh-relay-lifecycle` runs decommission: the refusals, then a real
  decommission, twice.
- `molecule/validation-iroh-relay` is the bad-input matrix.
- Not covered by CI: a real Let's Encrypt issuance, and the real binary. The
  v1.3.0 digests were checked against the release assets, and the binary was run
  once on Debian 12 with this config (it stayed up with ACME unreachable) when the
  role was written; repeat that by hand when you bump `iroh_relay_version`.
- `tests/firewall-holes` pins the firewall holes per host shape.
