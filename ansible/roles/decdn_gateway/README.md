# Role: `decdn_gateway`

Deploys deCDN's public HTTP gateway, `decdn gateway --public-url`, on a domain of
your own. Any browser, or the [TypeScript SDK], fetches `decdn:` content through it:

| Host | Serves |
|------|--------|
| `<domain>` | `GET /<hash>[/<path>]`: a blob streams, a bundle redirects to its site; `PUT /_pointer` |
| `<hash32>.<domain>` | the bundle with that manifest hash, as a website |
| `<ns>.<domain>` | the bundle namespace `<ns>`'s owner pointed at, as a website |

The gateway pays for every request from **its own pool**, funded by its own
keystore, within a daily allowance. A request past the allowance gets `402` with
the `decdn:` URI to fetch with a paying client. A pool that cannot pay gets `503`.
Upstream's [`adr/appendix-gateway.md`] and [`docker/README.decdn.md` § Public
gateway][docker-readme] are the reference.

The gateway listens on loopback. **nginx** (the distro package) terminates TLS in
front of it and is the only public listener (AGENTS.md hard rule 2). Its
certificate is a wildcard for `<domain>` and `*.<domain>` from **lego** over ACME
DNS-01, through your DNS provider's API. nginx also rate-limits `PUT /_pointer` per
client address: the gateway budgets owner lookups globally and reads no
`X-Forwarded-*` header, so per-client limits belong in the proxy.

[TypeScript SDK]: https://github.com/decdn/sdk-typescript
[`adr/appendix-gateway.md`]: https://github.com/decdn/decdn/blob/main/adr/appendix-gateway.md
[docker-readme]: https://github.com/decdn/decdn/blob/main/docker/README.decdn.md#public-gateway

## What it does

- **Validates every input** before it changes the host:
  - the domain;
  - both listeners on loopback;
  - the allowances in upstream's byte-size syntax;
  - the chain;
  - the TLS settings and the rate limit.

  It also refuses an nginx that already serves sites the role did not enable. The
  role's site is the default server on tcp/80 and tcp/443.
- **Installs the decdn CLI** at `/usr/local/lib/decdn-gateway/decdn`, never
  `/usr/local/bin/decdn`, which a co-located node's `decdn_node` role owns.
  - `release` (the default) resolves `decdn_gateway_version` like the other decdn
    roles: a line `X.Y` means its newest finished release. It downloads the `decdn`
    tarball, verifies it against the release's GPG-signed `SHA256SUMS`, and holds
    `decdn --version` to the resolved version.
  - `manual` copies a binary from the control machine.
- **Runs the gateway as `decdn-gateway`**, a system user with home
  `/var/lib/decdn-gateway`.
  - **Wallet:** the keystore `/var/lib/decdn-gateway/keystore.json` and its
    password `/etc/decdn-gateway/keystore.password`, both 0600. Set
    `decdn_gateway_generate_keystore: true` to have the role mint a fresh wallet when
    neither exists.
  - **Chain settings** (the RPC URL included) go in the 0600
    `/etc/decdn-gateway/gateway.toml`, never on the command line.
  - **State:** the pool store and the namespace pointers live under
    `/var/lib/decdn-gateway/gateway`.
  - **Unit:** hardened, with `KillSignal=SIGINT`. The gateway settles its pulls in
    flight only on SIGINT.
- **Restarts only when an input changed.** It records the sha256 of the config, the
  unit, the binary, the keystore and its password once the gateway answers `GET /`
  on loopback, and restarts when any differs. A restart forgives the day's allowance
  (the counters live in memory) and drops the pulls in flight.
- **Gets the certificate.**
  - `acme` (the default): installs lego from its GitHub release, verified against
    the sha256 pinned in `decdn_gateway_lego_sha256` (lego signs nothing).
    `decdn-gateway-certs.service` runs `lego run` for `<domain>` and `*.<domain>`
    with your provider's credentials. The role runs it once on the first deploy and
    fails if no certificate comes back. After that,
    `decdn-gateway-certs.timer` runs it twice a day; lego renews when the
    certificate is due and reloads nginx.
  - `self-signed`: an openssl certificate for staging and tests.
- **Puts nginx in front.**
  - One site, `/etc/nginx/sites-available/decdn-gateway`, carries a marker and
    replaces the package's default site. It is validated on its own before it lands.
  - Plain http on `<domain>` and `*.<domain>` redirects to https. Any other name
    gets no answer on tcp/80 and no TLS handshake on tcp/443.
  - Requests reach the gateway with their `Host` and nothing added. The gateway
    sets its own CORS headers, and a second `Access-Control-Allow-Origin` would make
    browsers refuse the answer.
  - Streaming is unbuffered, and request bodies are capped at 64 KiB.
  - `PUT /_pointer` is limited per client address (`decdn_gateway_pointer_rate`,
    `decdn_gateway_pointer_burst`). A client past the limit gets `429`.
  - It probes the http redirect and the whole https chain on this host.

## Before the first deploy

1. **A wallet of the gateway's own**, never a node's or sponsord's treasury: the
   gateway adopts the newest live pool its wallet owns. Fund its address with USDC
   (at least the working deposit, 10 USDC unless `decdn_gateway_working_deposit_micro_usdc`
   says otherwise) and ETH for gas. Either provision the keystore and password on
   the host (the role's failure message prints the commands) or set
   `decdn_gateway_generate_keystore: true` and fund the address it prints.
2. **DNS records**: `<domain>` and `*.<domain>`, both pointing at this host.
3. **A DNS provider token** for ACME DNS-01, scoped to the domain's zone. Pick the
   provider's lego code (`decdn_gateway_acme_dns_provider`, e.g. `cloudflare`) and
   write its variables, as listed on its page at
   <https://go-acme.github.io/lego/dns/>, into the root-only env file on the host:

   ```bash
   sudo install -d -m 0750 /etc/decdn-gateway
   sudo install -m 0600 /dev/null /etc/decdn-gateway/acme-dns.env
   sudoedit /etc/decdn-gateway/acme-dns.env   # CLOUDFLARE_DNS_API_TOKEN=...
   ```

   While iterating, set `decdn_gateway_acme_server: letsencrypt-staging` so failed
   attempts do not spend Let's Encrypt's production limits.
4. **The Public Suffix List.** A bundle's site is a separate browser site, with
   cookies of its own, only when `<domain>` is a public suffix. Register it in the
   PSL's private section. Inclusion takes weeks and reaches browsers slowly, so
   start early.
5. **The host to itself on tcp/80 and tcp/443.** `playbooks/decdn_gateway.yml`
   refuses a host that is also a sponsord-onramp, an iroh relay or an iroh DNS
   server, which all want 443. A deCDN node on the same host is fine.

## Known limitation: namespace-hint hosts

The gateway redirects `GET /<hash>?ns=<id>` to `<ns>.<hash32>.<domain>`. A wildcard
certificate covers one label, so `*.<domain>` does not cover that host, and a
browser following such a link gets a certificate error. The other host forms are
unaffected. The fix belongs upstream: decdn/decdn#2784 asks for a single-label hint.

## Variables

The full list, with comments, is [`defaults/main.yml`](defaults/main.yml). The ones
a deploy sets:

| Variable | Default | |
|----------|---------|---|
| `decdn_gateway_domain` | `""` | **Required.** The domain, without a scheme. |
| `decdn_gateway_rpc_url` | `""` | **Required.** The JSON-RPC endpoint; may hold an API key, so set it in the git-ignored `host_vars/<host>/secret.yml`. |
| `decdn_gateway_acme_email` | `""` | **Required** for `acme`. The ACME account contact. |
| `decdn_gateway_acme_dns_provider` | `""` | **Required** for `acme`. The lego provider code. |
| `decdn_gateway_allowance_bytes_per_day` | `1GiB` | Bytes delivered per UTC day, over every request. |
| `decdn_gateway_namespace_allowances` | `{}` | A bucket of its own per namespace pointer host: `{7: 20GiB}`. |
| `decdn_gateway_network` | the node's `decdn_network`, else `arbitrum-sepolia` | The chain profile ([`vars/main/networks.yml`](vars/main/networks.yml), generated). |
| `decdn_gateway_working_deposit_micro_usdc` | `""` | The pool's working deposit; `""` is the CLI's 10 USDC. |
| `decdn_gateway_tls` | `acme` | `acme` or `self-signed`. |
| `decdn_gateway_acme_server` | `letsencrypt` | A lego shortcode or directory URL. |
| `decdn_gateway_pointer_rate` / `_burst` | `6r/m` / `5` | The per-client limit on `PUT /_pointer`. |
| `decdn_gateway_generate_keystore` | `false` | Mint a fresh wallet when none exists. |
| `decdn_gateway_version` | the decdn line | Kept equal to `decdn_node_version` (`make test-scripts` checks). |

## Observability

The gateway's metrics listener (`127.0.0.1:9094`) serves Prometheus text at
`/metrics` and its state at `/_status` (`decdn dashboard --gateway`). It answers only
a loopback `Host`. The series are listed in [`adr/appendix-gateway.md` §
Metrics][metrics]. The two to alert on are
`decdn_gateway_pull_failures_funding_total` (the pool cannot pay: `503`s) and
`decdn_gateway_requests_allowance_exhausted_total` (`402`s). Logs go to the journal
as `decdn-gateway.service` (`RUST_LOG` from `decdn_gateway_log_level`).

[metrics]: https://github.com/decdn/decdn/blob/main/adr/appendix-gateway.md#metrics

## Day 2

- **Fund the pool.** Watch the wallet's USDC; a pool that cannot refill answers
  `503` until it can.
- **Rotate the password or the keystore**: replace the file on the host. The next
  converge sees its hash change and restarts the gateway.
- **Certificates** renew on their own (`systemctl list-timers decdn-gateway-certs.timer`,
  `journalctl -u decdn-gateway-certs`). To force a renewal now: `sudo systemctl start
  decdn-gateway-certs.service`.
- **Back up** the wallet and the namespace pointers with `make backup LIMIT=<host>`.
  The backup is encrypted to `decdn_gateway_backup_age_recipients`, which defaults
  to `decdn_backup_age_recipients`. See docs/lifecycle.md.
- **Decommission** with `make decommission LIMIT=<host>`. It stops the gateway and
  its timer and disables the role's nginx site. It keeps the wallet, which still
  owns the pool: with that keystore, `decdn pool close` the pool, and once its grace
  window has passed, `decdn pool reclaim` its funds.

## Testing

- `molecule/decdn-gateway` converges `playbooks/decdn_gateway.yml` against a stub
  gateway (`files/decdn-gateway-stub`) and the real distro nginx with a self-signed
  certificate on Debian 12 and Ubuntu 24.04. Its verify covers:
  - modes and listeners;
  - the https chain, with `Host` passed through and nothing added;
  - the http redirect;
  - the refused unknown name;
  - the `PUT /_pointer` limit.
- `molecule/decdn-gateway-lifecycle` shares its inventory. It covers:
  - the restart triggers and the fatal readiness gate;
  - lego's real download, verification and certificate units, against an ACME
    server that does not answer;
  - backup and decommission.
- `molecule/validation-decdn-gateway` holds the broken-input matrix.
