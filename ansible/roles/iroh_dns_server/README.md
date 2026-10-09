# Role: `iroh_dns_server`

Deploys `iroh-dns-server` from [n0-computer/iroh](https://github.com/n0-computer/iroh),
the server behind iroh's DNS address lookup. Every deCDN node publishes a signed
pkarr record carrying its relay URL and public addresses ([ADR 001], Node
Discovery). Peers find it by the node's ID alone. The one binary serves both legs:

- the **pkarr relay**: nodes `PUT` their record to `https://<hostname>/pkarr/<z32 id>`;
- the **DNS server**: peers resolve the record as the TXT record
  `_iroh.<z32 id>.<origin>`, on udp/53 and tcp/53 (and as DNS-over-HTTPS at
  `/dns-query`).

A node with no `[network.discovery]` config publishes to n0's hosted pkarr relay and
resolves through `dns.iroh.link`, a free service with no SLA. `decdn_node`'s
`decdn_discovery_pkarr_url` and `decdn_discovery_dns_origin` replace it (the
"Discovery-provider seam" in decdn's `adr/appendix-poc-production-seams.md`); this
role deploys the server they point at. Like [`iroh_relay`](../iroh_relay/README.md),
it is operational infrastructure, not an incentivized role.

The server is **public by design and terminates its own TLS**. It gets a Let's
Encrypt certificate itself (TLS-ALPN-01 on tcp/443), so there is no proxy in front
of it. It binds tcp/443 and udp+tcp/53; its metrics and a plain-http health
listener stay on loopback. This is the DNS server exception to AGENTS.md hard rule 2.

[ADR 001]: https://github.com/decdn/decdn/blob/main/adr/001-network.md#node-discovery-registry

## What it does

- **Installs the binary.**
  - `release` (the default) downloads `iroh-dns-server-v<version>-<target>.tar.gz`
    from the iroh GitHub release and verifies it against the sha256 pinned in
    `iroh_dns_server_sha256` for the host's target triple. Upstream signs nothing,
    so the pin is all that vouches for it. A stamp
    (`/usr/local/lib/iroh-dns-server/installed-version`, `<version> <target>
    <pinned archive sha256> <binary sha256>`) skips re-downloading while the pin
    and the binary on disk are the ones it records.
  - `manual` copies a binary from the control machine.
  - iroh-dns-server has **no `--version`** (clap exits 2 on it). On every run the
    role runs `--help` instead, which proves the binary runs on the host and takes
    `--config`. The version is checked on the running server's `/healthz` by the
    readiness gate, and the stamp is written only after that check.
- **Templates `/etc/iroh-dns-server/config.toml`** (root `0644`; nothing secret in
  it) with every key the role relies on written out. iroh-dns-server ignores keys it
  does not know, so a typo would silently drop a setting; the molecule stub refuses
  them. Two 1.3.0 behaviours shape the `[dns]` table:
  - **`"."` is always an origin.** The server roots its static zone at the root and
    refuses to start without an SOA there (`SOA record must be present: .`), which
    is why upstream's examples list it. So `_iroh.<z32>.` also resolves on this
    server.
  - **Every origin is written fully qualified.** With `"dns.example.org"` (no
    trailing dot, as in upstream's `config.prod.toml`), the server answers the
    apex SOA but not the `rr_a`, `rr_aaaa` or `rr_ns` records there.
- **Runs it under a hardened unit.** It runs as a `DynamicUser` whose only privilege
  is `CAP_NET_BIND_SERVICE`. The record store (`signed-packets-1.db`), the Let's
  Encrypt account key and the certificate with its private key live in
  `StateDirectory=iroh-dns-server` (`/var/lib/private/iroh-dns-server`, `0700`).
  You provision no secret: the server generates them itself. The unit asserts the
  config exists and is not empty. It sets `RUST_LOG` (iroh-dns-server logs only
  errors without it) and `NO_COLOR=1`, and stops with `KillSignal=SIGINT`, the only
  signal it shuts down gracefully on.
- **Checks its inputs first.** The bind addresses and the apex address records are
  parsed as IP addresses on the control machine. The SOA, the origins, the NS name
  and the DHT bootstrap nodes are checked for the shapes upstream parses. `::` is
  refused on a host with `net.ipv6.bindv6only=1`, where it would serve no IPv4.
- **Refuses ports another process holds.** Before it changes anything, the role
  fails if anything other than the server holds tcp/443, the metrics port or the
  health port, or port 53 (udp or tcp) **on the DNS bind address or a wildcard**. A
  resolver on another address, such as systemd-resolved's stub on `127.0.0.53`, is
  no conflict, because the DNS listener binds one address. With
  `iroh_dns_server_dns_bind_address: "::"` every holder of port 53 is a conflict,
  and the refusal names systemd-resolved when that is the holder. Ownership is read
  by cgroup, as in `iroh_relay` (#113). `playbooks/iroh_dns_server.yml` also
  refuses a host that is in `iroh_relay_hosts` or `sponsord_onramp_hosts`: all
  three want tcp/443.
- **Gates the deploy.** After the start, all of these must hold, or the deploy fails:
  - `/healthz` on the loopback http listener answers `status: ok` and, in release
    mode, the pinned version;
  - `/metrics` answers;
  - every listener belongs to the unit's `MainPID`;
  - the DNS listener answers each origin's SOA, over udp and over tcp, at the bind
    address (loopback for a wildcard bind);
  - the same process is still up `iroh_dns_server_readiness_settle` seconds later.

  The server binds all of this before it has a certificate, so the gate does not
  need one.
- **Checks the certificate.** It does this separately from the gate, exactly as
  `iroh_relay` does: `curl https://<hostname>/healthz` against the host's trust
  store. `warn` (the default) reports a missing first certificate and fails once a
  production certificate for the hostname was issued before. `fail` always fails,
  and `skip` does not look.
- **Restarts only on a change.** A hash record of the config, the unit and the
  binary (`/etc/iroh-dns-server/.server-inputs.sha256`) restarts the server when any
  of them changed since it last came up.

## Before the first deploy

1. **Delegate a zone to the host.** The server is authoritative for
   `iroh_dns_server_hostname` (say `dns.example.org`), and that same name is its
   https name. At the parent zone (`example.org`), add an NS record and a glue
   record:

   ```text
   dns.example.org.  NS  dns.example.org.
   dns.example.org.  A   203.0.113.10        ; glue: the host's public IPv4
   ```

   The server answers the matching records itself: `NS dns.example.org.`
   (`iroh_dns_server_rr_ns`, which defaults to the hostname), `A 203.0.113.10`
   (`iroh_dns_server_rr_a`) and the SOA (`iroh_dns_server_default_soa`, whose
   `mname` defaults to the hostname). Let's Encrypt resolves the hostname through
   this delegation, so the certificate comes only once the delegation works:
   `dig +trace A dns.example.org` must end at this host.
2. **Set the public address.** `iroh_dns_server_rr_a` defaults to the DNS bind
   address when that is a public IPv4 address. On a host behind 1:1 NAT (most
   clouds) the host's own address is private: set `iroh_dns_server_rr_a` to the
   public one. Leave `iroh_dns_server_dns_bind_address` on the private address,
   which is where the provider forwards port 53. Add `iroh_dns_server_rr_aaaa` (and
   an AAAA glue record) for IPv6.
3. **Open ports at your provider.** The role's baseline firewall opens them; a cloud
   security group must open them too:
   - tcp/443: nodes' record `PUT`s, DNS-over-HTTPS, and Let's Encrypt's
     TLS-ALPN-01 challenge;
   - udp/53 and tcp/53: DNS (tcp for answers too large for udp).
4. **An ACME contact.** Set `iroh_dns_server_acme_contact` to an email address.
   iroh-dns-server refuses to start without one in this mode.
5. **For a trial run,** set `iroh_dns_server_acme_staging: true`. Staging
   certificates are never trusted, so nodes cannot publish until you set it back.

In this repo, list the host in `iroh_dns_server_hosts` and run `make deploy-dns
LIMIT=<host>` (or `make deploy`, which includes it). The firewall holes come from
`playbooks/group_vars/all.yml`.

## Pointing nodes at it

Set both on the nodes, then re-deploy them:

```yaml
# inventory group_vars/decdn_nodes.yml
decdn_discovery_pkarr_url: https://dns.example.org/pkarr
decdn_discovery_dns_origin: dns.example.org
```

A node republishes its record every 5 minutes (iroh's pkarr publisher), and the
server drops a record not republished for 7 days.

**Clients need the same origin.** Setting either discovery setting on a node
**drops its n0 leg**: it publishes here only. A client on defaults
(`presets::N0`, decdn's `crates/client/src/endpoint.rs`) resolves through
`dns.iroh.link` and cannot find those nodes by pkarr. Dials still work through the
registry `multiaddrs` (ADR 001: pkarr is one path among several, never a gate), but
a client gets the pkarr path only if its `[network.discovery] dns_origin` names this
origin too.

## Things to know

- **One server is a single point of failure for pkarr resolution.** A node
  publishes to exactly one `pkarr_url`, and iroh-dns-server does not replicate, so
  two instances would be two independent stores. This is still an open question:
  the role supports one server per origin for now. `[mainline]` (the BitTorrent
  DHT, `iroh_dns_server_mainline_enabled`) does not help. The server uses it only
  as a lookup fallback for keys it does not hold, never publishes to it, and deCDN
  nodes publish to their `pkarr_url` alone. Turning it on would find nothing for
  them, and every public query for an unknown key would start a DHT lookup from
  this host. It is off by default.
- **Anyone can publish.** The pkarr relay stores any validly signed record; there
  is no allowlist upstream. What bounds it: the per-address rate limit on
  `PUT /pkarr` (a burst of 2, then one every 4 seconds) and the 7-day eviction.
- **The rate limit keys on the peer address.** `smart`, which upstream documents
  as reading `X-Forwarded-For`, is refused. With no proxy in front, a client could
  forge that header to escape its limit. In 1.3.0, `smart` behaves exactly as
  `simple` anyway, because the extractor it builds is discarded.
- **systemd-resolved.** The DNS listener binds one address (upstream takes one
  `bind_addr` for udp and tcp), by default the host's default IPv4 address, so the
  stub listener on `127.0.0.53` keeps resolving for the host. To serve DNS on IPv6
  too, set `iroh_dns_server_dns_bind_address: "::"`. Nothing else may then hold
  port 53: put `DNSStubListener=no` in a drop-in under
  `/etc/systemd/resolved.conf.d/` and point `/etc/resolv.conf` at a resolver. The
  role refuses `::` until you do; it does not change the host's resolver itself.
- **The SOA serial is a constant.** The server builds its zone at start and refuses
  AXFR, so there are no secondaries to notify. Its own NS, SOA and A/AAAA TTLs are
  fixed upstream (12 h, 14 days, 1 h); `iroh_dns_server_default_ttl` applies to node
  records.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `iroh_dns_server_hostname` | `""` (**required**) | The zone the server is authoritative for and its https name. No scheme, port, IP or trailing dot. |
| `iroh_dns_server_acme_contact` | `""` (**required**) | The Let's Encrypt account's email address, without `mailto:`. |
| `iroh_dns_server_acme_staging` | `false` | Use Let's Encrypt's staging CA. Its certificates are untrusted. |
| `iroh_dns_server_install_method` | `release` | `release` or `manual`. |
| `iroh_dns_server_version` | `1.3.0` | The iroh release. Keep it on the iroh version decdn builds against (`decdn/Cargo.lock`). |
| `iroh_dns_server_sha256` | the v1.3.0 digests | Per-target sha256 of the release tarball. Bump it together with the version. |
| `iroh_dns_server_manual_bin_src` | `""` | `manual`: the control-machine path to the binary. |
| `iroh_dns_server_origins` | `[<hostname>]` | The zones node records are served under (at least one besides `"."`). Written fully qualified; `"."` is always added. |
| `iroh_dns_server_rr_a` / `_rr_aaaa` | DNS bind address if public / `""` | The address records at each origin apex: the public addresses the glue names. |
| `iroh_dns_server_rr_ns` | `<hostname>.` | The NS record at each apex: an apex (whose address the server answers) or a name outside every origin. |
| `iroh_dns_server_default_soa` | `<hostname>. hostmaster.<hostname>. 0 10800 3600 604800 3600` | The apex SOA, in zone-file form. |
| `iroh_dns_server_default_ttl` | `30` | TTL of node records, in seconds. |
| `iroh_dns_server_https_bind_address` | `::` | The address for tcp/443: `::`, `0.0.0.0`, or one of the host's unicast addresses. |
| `iroh_dns_server_dns_bind_address` | the default IPv4 address | The one address for udp/53 and tcp/53. `::` needs port 53 free (see systemd-resolved above). |
| `iroh_dns_server_metrics_bind` / `_port` | `127.0.0.1` / `9117` | Prometheus metrics. Must be loopback, and the port must clear this repo's other listeners. |
| `iroh_dns_server_health_port` | `9118` | The loopback plain-http listener the gate reads `/healthz` from. |
| `iroh_dns_server_pkarr_put_rate_limit` | `simple` | `simple` (per client address) or `disabled`. |
| `iroh_dns_server_mainline_enabled` | `false` | The mainline DHT lookup fallback. See "Things to know". |
| `iroh_dns_server_mainline_bootstrap` | `[]` | DHT bootstrap nodes as `host:port` (only with the DHT on). |
| `iroh_dns_server_limit_nofile` | `65536` | The unit's `LimitNOFILE`. |
| `iroh_dns_server_log_level` | `info` | `RUST_LOG`: a level, or comma-separated `target=level` directives. |
| `iroh_dns_server_certificate_check` | `warn` | `warn`, `fail` or `skip`. See "What it does". |
| `iroh_dns_server_readiness_retries` / `_delay` / `_settle` | `30` / `2` / `5` | The gate's window, and the seconds the same process must then stay up. |
| `iroh_dns_server_certificate_retries` / `_delay` | `15` / `4` | The certificate check's window (~60 s). |

The public ports (443, 53) are fixed in `vars/main.yml`.

## Observability

With Grafana Cloud on (`decdn_grafana_cloud_enabled`), `playbooks/group_vars/all.yml`
turns on `grafana_alloy_iroh_dns_server_enabled` for `iroh_dns_server_hosts`. Alloy
then:

- scrapes the server's metrics as `job="iroh-dns-server"`,
  `service_name=iroh-dns-server`. The series are `dns_server_*`: pkarr publishes,
  DNS requests and lookups, HTTP requests, and the record store;
- labels its journal stream `unit="iroh-dns-server.service"`, with a `level` parsed
  from each line.

There is no dashboard or alert rule set in `monitoring/` for it yet; that is a
follow-up. Certificate expiry is not exported. Watch `https://<hostname>/healthz`
and an external `dig` with a check of your own.

## Day 2

- **Restarts.** A change to the config, the unit or the binary restarts the server.
  Nodes retry their next publish; resolvers retry or use another path while it is
  down.
- **Certificates.** iroh-dns-server renews its certificate itself.
  `journalctl -u iroh-dns-server | grep -i acme` shows the ACME exchange.
- **Upgrades.** Move `iroh_dns_server_version` to the iroh version decdn moved to
  (`decdn/Cargo.lock`), then:
  1. re-pin every `iroh_dns_server_sha256` digest against the release assets;
  2. run the real binary on a rendered config, with `cert_mode` swapped to
     `self_signed` and the ports moved off 53 and 443. It must start, report the
     version on `/healthz`, answer the apex SOA, NS and A records, and round-trip a
     record (see [Testing](#testing));
  3. check whether the new release still needs `"."` among the origins, and still
     drops the apex records of an unqualified origin;
  4. check that the molecule stub (`molecule/iroh-dns-server/files/iroh-dns-server-stub`)
     accepts exactly the config keys the new release's `config.rs`, `http.rs` and
     `dns.rs` define;
  5. check that the tokio-rustls-acme version it pins still names its certificate
     cache as `vars/main.yml` says, and that `dns_server_dns_requests_total` (the
     gate's metric) is still exported.
- **Backup.** None. Nodes republish their records every 5 minutes, and Let's
  Encrypt re-issues the certificate on a new host.
- **Moving it.** The zone follows the glue record. Deploy on the new host, then
  update the parent zone's glue (and `iroh_dns_server_rr_a`). Nodes keep their
  `pkarr_url` and repopulate the new store within minutes.
- **Decommission.** `make decommission LIMIT=<host>` stops the server and removes
  its unit and restart-inputs record. It keeps the binary, the config and the state directory. Point the nodes
  elsewhere first, and remove the delegation afterwards.

## Testing

- `molecule/iroh-dns-server` converges `playbooks/iroh_dns_server.yml` against a
  stub server on Debian 12 and Ubuntu 24.04. A molecule CA stands in for Let's
  Encrypt. The stub enforces the startup contract: only the config keys
  iroh-dns-server 1.3.0 knows, the keys it requires, `"."` among fully qualified
  origins, Let's Encrypt with a contact, and loopback metrics and health. It
  answers SOA, NS, A and AAAA at the apex over udp and tcp. Its side effects prove
  the following:
  - restarts happen on a changed knob and not otherwise;
  - the gate is fatal and records nothing;
  - squatters on tcp/443 and on port 53 at the bind address are refused before
    any change, and one on `127.0.0.53:53` is tolerated;
  - a missing config fails the start.

  Sibling scenarios on the same converge cover the rest:
  - `iroh-dns-server-gate`: a server without DNS, one that crashes after binding,
    the wildcard DNS bind (and its systemd-resolved refusal), and a specific https
    address;
  - `iroh-dns-server-certificate`: the certificate check;
  - `iroh-dns-server-install`: the `release` method against a local mirror. That
    covers the pin, the stamp, the mirror down, a binary replaced in place, and a
    version `/healthz` does not report;
  - `iroh-dns-server-lifecycle`: decommission.
- `molecule/validation-iroh-dns-server` is the bad-input matrix.
- `tests/firewall-holes` pins the firewall holes per host shape;
  `tests/scripts-test.sh` runs the placement guard.
- **Not covered by CI**, so it is checked by hand on every version bump:
  - **The real binary and a real record.** The v1.3.0 digests were checked against
    the release assets. The x86_64 binary was then run on a config rendered by this
    role (cert mode `self_signed`, unprivileged ports). It answered `/healthz` with
    `1.3.0`, the apex SOA, NS and A over udp and tcp, and exported the gate's
    metric. A pkarr `PUT` of a signed `_iroh` TXT record got a 204, and
    `dig TXT _iroh.<z32>.<origin>` returned the record over udp and tcp. To
    repeat it on a deployed server, point a node at it and run
    `dig TXT _iroh.<z32 id>.<hostname> @<host>`. The name carries the node's
    public key in z-base-32, not the hex `decdn whoami` prints. The server logs the
    key of every `PUT` (`pkarr upsert key=<z32>`, at `info`).
  - **A real Let's Encrypt issuance through a delegated zone.**
  - **A peer configured with the same origin dialing a node by bare ID.**
  - **The ACME certificate-cache name.** `warn` mode's escalation looks for
    tokio-rustls-acme 0.9's file name (`vars/main.yml`). If an iroh bump changes
    it, the escalation stops working without any error.
