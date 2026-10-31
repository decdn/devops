# Role: `sponsord_onramp`

Deploys `sponsord-onramp` from [decdn/decdn](https://github.com/decdn/decdn/tree/main/crates/sponsord-onramp),
the public side of the deCDN onboarding sponsor. It serves:

- the gate page people pass (Cloudflare Turnstile) before the sponsor pays for
  their download;
- the `decdn.sh` / `decdn.ps1` installers, which install `decdn` from a pinned
  release, make a throwaway download key, get the capability through the gate and
  run `decdn get` with it;
- the API the installers poll for that capability.

It holds no wallet. For each person who passes the gate it asks the
[`sponsord`](../sponsord/README.md) daemon on the same host for a capability, using
the daemon's API token. So the daemon must run on the same host: in this repo, list
the host in `sponsord_hosts` as well as `sponsord_onramp_hosts` (`playbooks/sponsord.yml`
refuses it otherwise). The role itself checks no group name: it fails early when
the daemon's token file is missing, and its `/healthz` gate fails when the daemon
is unreachable.

## What it does

- **Installs the binary**, exactly as the `sponsord` role does:
  - `release` (the default) downloads `sponsord-onramp-<version>-<triple>.tar.gz`
    from the `v<version>` release of `decdn/decdn` (`sponsord_onramp_version`,
    the same release line, or exact release, as the daemon's `sponsord_version` and
    the node's `decdn_node_version`; a line resolves to its newest finished release
    on every run, from `sponsord_onramp_release_index`) and verifies it against the
    GPG-signed `SHA256SUMS`, with the decdn KEYS vendored in this role (the same
    file the installers' decdn release is checked against).
    `sponsord_onramp_release_base` points it at a mirror.
  - `source` builds `sponsord_onramp_source_ref` of `sponsord_onramp_source_repo`
    on the host (`cargo build -p sponsord-onramp`) as the `sponsord` role's `source`
    mode does, from its own clone, so the two can pin different refs. Each builds
    from scratch, so a co-located host compiles the shared crates twice.
  - `manual` copies a binary built in a `decdn/decdn` checkout (or installed
    with `cargo install --locked sponsord-onramp@<version>`, unsigned).
    `sponsord_onramp_release_target_dir` defaults to `sponsord_release_target_dir`,
    so one `cargo build --release` covers both.
- **Uses two secrets.** Both stay root `0600` under `/etc/sponsord` and reach the
  onramp as `LoadCredential=` credentials, never as environment:

  | File | Who provides it |
  |------|-----------------|
  | `api-token` | The `sponsord` role (generated on the host). The onramp uses the daemon's own file. |
  | `turnstile-secret` | `sponsord_onramp_turnstile_secret` from the git-ignored `host_vars/<host>/secret.yml`, or a file you write on the host. The two-way rules match `sponsord_rpc_url`: the role replaces a file it did not write only with `sponsord_onramp_turnstile_secret_overwrite_host_file: true`, and an empty value over a file the role wrote fails the deploy, because that means `secret.yml` went missing. Either way the role checks it is a non-empty regular file at `0600`. |

- **Writes non-secret settings** to `/etc/sponsord/sponsord-onramp.env` (0644): the
  public URL, the public RPC URL, CapacityBond and SlashJudge, the sitekey, the
  `decdn` release pin and any limits you set.
- **Runs a hardened unit.** `sponsord-onramp.service` runs with `DynamicUser=`, no
  capabilities and a read-only filesystem.
  - `PartOf=sponsord.service`: a daemon restart restarts the onramp, because the
    onramp reads the daemon's limits only at start.
  - It exits at start while the daemon is unreachable, so it retries every 5 s
    with no start limit.
- **Gates the deploy on `/healthz`.** The onramp binds only after it has reached the
  daemon and validated its settings (the release pin, its cap and TTL against the
  daemon's maximum). If `/healthz` does not answer 200 within the readiness window,
  the deploy fails.
- **Restarts on out-of-band changes.** As in the `sponsord` role, a hash record of
  every restart input (the token, the Turnstile secret, the env file, the gate page,
  the unit, the binary) restarts the onramp when one changes outside the role.
- **Puts nginx in front** (`sponsord_onramp_proxy: nginx`, the default):
  - Installs the distribution's `nginx`, `curl` and `openssl` packages. No
    third-party apt repository is added, so baseline's unattended-upgrades keeps the
    internet-facing TLS terminator patched. The package is not allowed to start
    nginx on its stock default site: nginx first starts once the role's site has
    validated.
  - Writes one site, `/etc/nginx/sites-available/sponsord-onramp` (enabled in
    `sites-enabled/`, replacing the package's `default`): `sponsord_onramp_domain` on
    tcp/80 serves the ACME HTTP-01 challenge and redirects everything else to https;
    on tcp/443 it terminates TLS and proxies to the onramp on loopback, **setting**
    `X-Forwarded-For` to the client address (never appending a client-sent one).
    Other names get no answer on 80 and no TLS handshake on 443. The site is
    validated on its own before it lands, then `nginx -t` checks the whole
    configuration before a reload.
  - Gets the certificate from **lego** over **ACME HTTP-01**
    (`sponsord_onramp_tls: acme`, the default): no DNS credentials, only the domain's
    A/AAAA records pointing at the host and tcp/80 reaching it. lego is a pinned
    release, verified against its per-architecture sha256 (the same pin as the
    `decdn_gateway` role's). The first deploy serves http only, has lego issue the
    certificate, then adds the https server; `sponsord-onramp-certs.timer` renews
    twice a day, and its deploy hook reloads nginx. A changed domain or ACME server
    reissues on the next run. `self-signed` makes an openssl certificate instead,
    for staging and tests.
  - Needs tcp/80 (ACME challenge, https redirect) and tcp/443 open. This repo's
    playbooks open both (`playbooks/group_vars/all.yml`); from your own playbook, add
    them to `baseline_extra_inbound` yourself.
  - Probes the domain through nginx on the host. Plain http must answer with the
    https redirect, and `https://<domain>/healthz` must answer through TLS. A
    certificate lego cannot obtain fails the deploy, with the reason in
    `journalctl -u sponsord-onramp-certs`.
  - Refuses to deploy while nginx serves a site it did not enable (other than the
    package's untouched `default`): the role's site is the default server on 80 and
    443. The `decdn_gateway` role refuses the same way, so the two need separate
    hosts.
- **Retires the Caddy it ran before nginx.** Up to `decdn.publisher` 0.4 the role
  put Caddy in front. On the first converge since, a Caddy serving the role's
  `/etc/caddy/Caddyfile` (its marker line) is stopped and disabled before nginx
  takes tcp/80, and purged with `/var/lib/caddy` only once the onramp answers over
  https through nginx: until then a failed first issuance can go back to it
  (`sudo systemctl disable --now nginx && sudo systemctl enable --now caddy`). A
  Caddy someone else runs is never touched; the role names whatever else holds
  tcp/80 or tcp/443 before nginx starts. The retired `sponsord_onramp_caddy_tls` and
  `sponsord_onramp_caddy_overwrite_config`, and `sponsord_onramp_proxy: caddy`, fail
  preflight with what replaces them.

## Before the first deploy

1. **Deploy `sponsord`** on the host (see [its README](../sponsord/README.md)). The
   same `make deploy-sponsord` run can do both.
2. **Create a Turnstile widget** for your domain in the Cloudflare dashboard. Note
   its sitekey (public) and secret.
3. **Provide the secret**, either way:
   - `sponsord_onramp_turnstile_secret` in the git-ignored
     `host_vars/<host>/secret.yml`, and the role writes the file;
   - or the file itself on the host, as root:

     ```bash
     umask 077
     printf '%s' '<secret>' | sudo tee /etc/sponsord/turnstile-secret >/dev/null
     sudo chmod 600 /etc/sponsord/turnstile-secret
     ```

4. **Point DNS** for the domain (A/AAAA) at the host, and make sure tcp/80 reaches
   it, so lego can get a certificate over HTTP-01. Use
   `sponsord_onramp_acme_server: letsencrypt-staging` while iterating, so failed
   attempts do not spend the production rate limits.
5. **The `decdn` release the installers install** defaults to the release line this
   repo pins (`sponsord_onramp_decdn_release`, the `v` form of the decdn_node role's
   default `decdn_node_version`): every run serves the line's newest finished release,
   with the SHA-256 of its `SHA256SUMS`, which the role downloads from where the
   installers download it and verifies against `files/decdn-release-KEYS.asc` first.
   A new decdn patch release therefore reaches new installs on the next run. To serve
   one exact release, set its tag (`vX.Y.Z`) together with that digest: the role
   refuses a tag without a digest, and a line with one.
6. **Set inventory** (`group_vars/sponsord_onramp_hosts.yml`): the domain, the ACME
   contact email, the public RPC URL and the sitekey. The contracts come from `sponsord_network`.

Then run `make deploy-sponsord` from `ansible/`.

## Variables

See [`defaults/main.yml`](defaults/main.yml) for the full list with comments.

| Variable | Default | Notes |
|----------|---------|-------|
| `sponsord_onramp_install_method` | `release` | `release`, `source` or `manual` |
| `sponsord_onramp_source_repo` / `_source_ref` | `decdn/decdn` on GitHub / `""` | `source` only. The ref is required: a tag, branch or SHA. |
| `sponsord_onramp_source_build_jobs` | `""` | `source` only: `CARGO_BUILD_JOBS` (`""` = one per CPU). |
| `sponsord_onramp_manual_bin_src` / `_release_target_dir` | `""` / `sponsord_release_target_dir` | `manual` only. |
| `sponsord_onramp_version` | the pinned release line | `release` mode: a `decdn/decdn` release line (`"X.Y"`, its newest finished release) or an exact `"X.Y.Z"`, quoted; see [`defaults/main.yml`](defaults/main.yml). Keep it equal to `sponsord_version` (and the node's `decdn_node_version`): overriding one does not move the other. |
| `sponsord_onramp_network` | `sponsord_network` | Supplies CapacityBond and SlashJudge. Must match the daemon's network. |
| `sponsord_onramp_capacity_bond_address`, `_slash_judge_address` | from profile | Explicit values win. SlashJudge may be `""`. |
| `sponsord_onramp_rpc_url` | `""` | **Required. Public**: served to every user. No credentials, query or API key. |
| `sponsord_onramp_proxy` | `nginx` | `nginx` or `none`. Set it in inventory: the firewall holes read it. |
| `sponsord_onramp_domain` | `""` | Required with nginx. |
| `sponsord_onramp_public_url` | `https://<domain>` | Required with `none`: the https URL your proxy serves. |
| `sponsord_onramp_tls` | `acme` | `acme` (lego, HTTP-01) or `self-signed` (staging, tests). |
| `sponsord_onramp_acme_email` | `""` | **Required with `acme`**: the ACME account contact. |
| `sponsord_onramp_acme_server` | `letsencrypt` | A lego shortcode or an https directory URL; `letsencrypt-staging` while iterating. |
| `sponsord_onramp_acme_dir` / `_acme_webroot` | `/var/lib/sponsord-onramp-acme` / `/var/www/sponsord-onramp-acme` | lego's state (root, 0700) and the challenge directory nginx serves. |
| `sponsord_onramp_lego_version` / `_lego_sha256` | the pinned lego release | Bump with `decdn_gateway_lego_*`: `make test-scripts` checks they agree. |
| `sponsord_onramp_client_ip_header` | `X-Forwarded-For` with nginx, else `""` | With your own proxy, set it only if that proxy is the only way in. |
| `sponsord_onramp_turnstile_sitekey` | `""` | **Required.** |
| `sponsord_onramp_turnstile_secret` | `""` | **Sensitive.** Leave empty to provision `turnstile-secret` on the host. |
| `sponsord_onramp_turnstile_secret_overwrite_host_file` | `false` | Confirm that the inventory secret may replace a file the role did not write. |
| `sponsord_onramp_decdn_release`, `_decdn_sums_sha256` | the `decdn_node` role's default line as a `v` tag, `""` | A decdn/decdn line (`vX.Y`, with no digest: the role reads it from the resolved release) or a tag (`vX.Y.Z`) with its 64-lowercase-hex digest, no older than sponsord-onramp's `MIN_DECDN_RELEASE`: `v0.2.0` for 0.2 (its installers rely on decdn 0.2's `get` picking the destination), `v0.3.0` for 0.3. The role checks this before installing. The default follows the `decdn_node` role's pin; a host override of `decdn_node_version` does not move it. |
| `sponsord_onramp_decdn_release_index`, `_decdn_release_base`, `_decdn_keyring` | GitHub's decdn/decdn release list, `<releases base>/decdn/releases/download`, the vendored KEYS | Where a line is resolved, where its `SHA256SUMS` is read (the installers' own download location), and the keys it must verify against. |
| `sponsord_onramp_brand_name`, `_gate_template_src` | `""` | The gate page's name, or your own HTML page (a control-machine file). |
| `sponsord_onramp_spending_cap_micro_usdc`, `_ttl_secs` | `""` | Requested per capability. `""` takes the daemon's maximum; more than it fails the deploy. |
| `sponsord_onramp_fund_rate_per_min`, `_poll_rate_per_min` | `""` | Per-address rate limits (upstream 10 and 120; `0` turns one off). |
| `sponsord_onramp_bind_address` / `_port` | `127.0.0.1` / `8080` | IPv4 loopback only (asserted). |
| `sponsord_onramp_readiness_retries` / `_delay` | `30` / `2` | `/healthz` window (about 60 s). |
| `sponsord_onramp_log_level` | `""` | `RUST_LOG`: a level or `target=level` pairs (`""` = info). |
| `decdn_decommission_max_hosts` / `_prompt_seconds` | `1` / `300` | `tasks_from: decommission`, shared with the other roles. |

## Bringing your own proxy

With `sponsord_onramp_proxy: none` the role installs no nginx and opens no port.
Your proxy must terminate TLS for `sponsord_onramp_public_url` and forward to
`127.0.0.1:8080`. Set `sponsord_onramp_client_ip_header` only if the proxy is the
only way to reach the onramp: `CF-Connecting-IP` behind Cloudflare, or
`X-Forwarded-For` if your proxy sets or appends the client address (the onramp
reads the right-most entry; with nginx, `proxy_set_header X-Forwarded-For
$remote_addr`). Otherwise clients can choose their own address and get around the
rate limits. Switching from `nginx` to `none` closes the firewall holes but leaves
the role's nginx site enabled on 80/443; the role warns about it on every run until
you remove it.

## Observability

With `decdn_grafana_cloud_enabled: true`, the `grafana_alloy` role ships the
onramp's journal with `service_name="sponsord-onramp"` and a `level` parsed from each
line (it has no `/metrics`). This repo's playbooks turn that on for hosts in
`sponsord_onramp_hosts`. From your own playbook, set
`grafana_alloy_sponsord_onramp_enabled`. nginx's unit state is in the systemd
collector, and so is `sponsord-onramp-certs.service`, lego's renewal: alert on it
being `failed`, or run a blackbox check of `https://<domain>/healthz`, since nothing
else warns before the certificate expires. nginx's access logs are not shipped.

## Day 2

- **Rotate the Turnstile secret:** change `sponsord_onramp_turnstile_secret` (or,
  for a host-provisioned secret, write the new one to
  `/etc/sponsord/turnstile-secret`) and re-run the role. It restarts the onramp.
- **Ship a new `decdn`:** with a release line, re-run the role once the release is
  out; with an exact tag, point `sponsord_onramp_decdn_release` /
  `_decdn_sums_sha256` at the new release and re-run. New installs get it.
- **Certificate trouble:** `sudo journalctl -u sponsord-onramp-certs -e` (lego) and
  `sudo journalctl -u nginx -e`. Check that the domain resolves to the host and that
  tcp/80 reaches it from the internet; `sudo systemctl start sponsord-onramp-certs`
  retries at once.
- **Logs:** `journalctl -u sponsord-onramp`, at info by default. `sponsord_onramp_log_level`
  sets `RUST_LOG`: a level or `target=level` pairs only. The release is built without
  tracing's env-filter, so a span or field filter makes it log nothing at all.
- **Removal:** `make decommission LIMIT=<host>` (`tasks_from: decommission`, run
  before sponsord's) asks for the typed host list, stops the onramp and the renewal
  timer and removes their units, disables the role's nginx site, and stops nginx if
  that was all it served. It keeps the files under `/etc/sponsord`, the certificate,
  the binaries and the nginx package. To remove those by hand afterwards:

  ```bash
  sudo rm -f /usr/local/bin/sponsord-onramp /etc/sponsord/sponsord-onramp.env \
    /etc/sponsord/onramp-gate.html /etc/sponsord/turnstile-secret \
    /etc/sponsord/.turnstile-secret.sha256
  sudo rm -rf /usr/local/lib/sponsord-onramp /var/lib/sponsord-onramp-acme \
    /var/www/sponsord-onramp-acme /etc/sponsord/tls
  sudo rm -f /etc/nginx/sites-available/sponsord-onramp
  sudo apt-get remove nginx   # if nothing else on the host uses it
  ```

  Then take the host out of `sponsord_onramp_hosts`, so the next deploy closes
  tcp/80 and tcp/443. After a `source` install, remove
  `/var/lib/decdn-build/git/sponsord-onramp` (or the whole build user, `sudo userdel
  decdn-build && sudo rm -rf /var/lib/decdn-build`, once nothing on the host builds
  from source).

## Testing

- `molecule/sponsord-onramp` runs `playbooks/sponsord.yml` (daemon, then onramp) on
  Debian 12 and Ubuntu 24.04, against stub binaries and the real distro nginx with a
  self-signed certificate. It checks:
  - idempotence;
  - the `https://` chain through nginx, and that a client-sent `X-Forwarded-For`
    cannot choose the address the onramp sees;
  - that a Turnstile rotation restarts the onramp and not the daemon;
  - that the `/healthz` gate fails the deploy when the onramp will not start;
  - that a running onramp with no record restarts, and a daemon restart brings it
    back.
- `molecule/sponsord-onramp-nginx` runs beside it on the same converge. It checks
  proxy `none`, a broken upstream behind nginx, the refusal of a foreign nginx site,
  the retirement of the role's earlier Caddy, and ACME against an ACME server that
  does not answer; then a custom gate page, and the Turnstile secret from inventory.
- `molecule/validation-sponsord` holds the negative cases.
- `tests/firewall-holes` (`make test-scripts`) pins the tcp/80 and tcp/443 holes.
- `tests/alloy-config` (`make lint-alloy`) runs the onramp's log lines through the
  real Alloy.
