# Role: `sponsord_onramp`

Deploys `sponsord-onramp` from [decdn/sponsord](https://github.com/decdn/sponsord),
the public side of the deCDN onboarding sponsor. It serves:

- the gate page people pass (Cloudflare Turnstile) before the sponsor pays for
  their download;
- the `decdn.sh` / `decdn.ps1` installers, which install `decdn` and
  `decdn-sponsored` from pinned releases;
- the API the `decdn-sponsored` CLI polls for its capability.

It holds no wallet. For each person who passes the gate it asks the
[`sponsord`](../sponsord/README.md) daemon on the same host for a capability, using
the daemon's API token. So the daemon must run on the same host: in this repo, list
the host in `sponsord_hosts` as well as `sponsord_onramp_hosts` (`playbooks/sponsord.yml`
refuses it otherwise). The role itself checks no group name: it fails early when
the daemon's token file is missing, and its `/healthz` gate fails when the daemon
is unreachable.

## What it does

- **Installs the binary**, exactly as the `sponsord` role does:
  - `release` (the default) downloads `sponsord-onramp-v<version>` and verifies it
    against the GPG-signed `SHA256SUMS`, with the KEYS file vendored in the
    `sponsord` role. Upstream has cut no release yet, so until it does this needs a
    mirror (`sponsord_onramp_release_base`).
  - `source` builds `sponsord_onramp_source_ref` of `sponsord_onramp_source_repo`
    on the host (`cargo build -p sponsord-onramp`) as the `sponsord` role's `source`
    mode does, from its own clone, so the two can pin different refs. Each builds
    from scratch, so a co-located host compiles the sponsord workspace twice.
  - `manual` copies a binary built in a `decdn/sponsord` checkout.
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
  release pins and any limits you set.
- **Runs a hardened unit.** `sponsord-onramp.service` runs with `DynamicUser=`, no
  capabilities and a read-only filesystem.
  - `PartOf=sponsord.service`: a daemon restart restarts the onramp, because the
    onramp reads the daemon's limits only at start.
  - It exits at start while the daemon is unreachable, so it retries every 5 s
    with no start limit.
- **Gates the deploy on `/healthz`.** The onramp binds only after it has reached the
  daemon and validated its settings (the release pins, its cap and TTL against the
  daemon's maximum). If `/healthz` does not answer 200 within the readiness window,
  the deploy fails.
- **Restarts on out-of-band changes.** As in the `sponsord` role, a hash record of
  every restart input (the token, the Turnstile secret, the env file, the gate page,
  the unit, the binary) restarts the onramp when one changes outside the role.
- **Puts Caddy in front** (`sponsord_onramp_proxy: caddy`, the default):
  - Installs the distribution's `caddy` package (Debian main; on Ubuntu it is in
    **universe**, which must be enabled). No third-party apt repository is added.
    The package is not allowed to start Caddy on its stock config: Caddy first
    starts once the role's Caddyfile has validated.
  - Writes `/etc/caddy/Caddyfile`: TLS for `sponsord_onramp_domain`, then a reverse
    proxy to the onramp on loopback. The file is validated with `caddy validate`
    before it lands. The admin API is off, so nothing on the host can reconfigure
    the running proxy over its admin endpoint (:2019), and HTTP/3 is off, so udp/443
    stays closed.
  - Needs tcp/80 (ACME challenge, https redirect) and tcp/443 open. This repo's
    playbooks open both (`playbooks/group_vars/all.yml`); from your own playbook, add
    them to `baseline_extra_inbound` yourself.
  - Probes the domain through Caddy on the host. Plain http must answer with Caddy's
    https redirect, and `https://<domain>/healthz` must answer through TLS; both
    failures are fatal. One exception: with ACME, a certificate that is not issued
    yet (the TLS handshake fails, or the certificate cannot be verified) only warns,
    since it can lag DNS.
  - Refuses to replace a `/etc/caddy/Caddyfile` that it did not write and that is
    not the caddy package's untouched default, unless you set
    `sponsord_onramp_caddy_overwrite_config: true`.

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

4. **Point DNS** for the domain (A/AAAA) at the host, so Caddy can get a
   certificate.
5. **Pick the releases the installers install.** For `decdn`, a `vX.Y.Z` tag and the
   SHA-256 of that release's `SHA256SUMS`. For `decdn-sponsored`, a
   `decdn-sponsored-vX.Y.Z` tag and the same digest; both values are printed in its
   release notes.
6. **Set inventory** (`group_vars/sponsord_onramp_hosts.yml`): the domain, the
   public RPC URL, the sitekey and the four release-pin values. The contracts come
   from `sponsord_network`.

Then run `make deploy-sponsord` from `ansible/`.

## Variables

See [`defaults/main.yml`](defaults/main.yml) for the full list with comments.

| Variable | Default | Notes |
|----------|---------|-------|
| `sponsord_onramp_install_method` | `release` | `release`, `source` or `manual` |
| `sponsord_onramp_source_repo` / `_source_ref` | `decdn/sponsord` on GitHub / `""` | `source` only. The ref is required: a tag, branch or SHA. |
| `sponsord_onramp_source_build_jobs` | `""` | `source` only: `CARGO_BUILD_JOBS` (`""` = one per CPU). |
| `sponsord_onramp_manual_bin_src` / `_release_target_dir` | `""` / `sponsord_release_target_dir` | `manual` only. |
| `sponsord_onramp_version` | `""` | Required in `release` mode, e.g. `0.1.0` → tag `sponsord-onramp-v0.1.0`. |
| `sponsord_onramp_network` | `sponsord_network` | Supplies CapacityBond and SlashJudge. Must match the daemon's network. |
| `sponsord_onramp_capacity_bond_address`, `_slash_judge_address` | from profile | Explicit values win. SlashJudge may be `""`. |
| `sponsord_onramp_rpc_url` | `""` | **Required. Public**: served to every user. No credentials, query or API key. |
| `sponsord_onramp_proxy` | `caddy` | `caddy` or `none`. Set it in inventory: the firewall holes read it. |
| `sponsord_onramp_domain` | `""` | Required with Caddy. |
| `sponsord_onramp_public_url` | `https://<domain>` | Required with `none`: the https URL your proxy serves. |
| `sponsord_onramp_caddy_tls` | `acme` | `internal` uses Caddy's local CA (staging, tests). |
| `sponsord_onramp_acme_email` | `""` | Optional ACME contact. |
| `sponsord_onramp_caddy_overwrite_config` | `false` | Let the role take over a Caddyfile it did not write. |
| `sponsord_onramp_client_ip_header` | `X-Forwarded-For` with Caddy, else `""` | With your own proxy, set it only if that proxy is the only way in. |
| `sponsord_onramp_turnstile_sitekey` | `""` | **Required.** |
| `sponsord_onramp_turnstile_secret` | `""` | **Sensitive.** Leave empty to provision `turnstile-secret` on the host. |
| `sponsord_onramp_turnstile_secret_overwrite_host_file` | `false` | Confirm that the inventory secret may replace a file the role did not write. |
| `sponsord_onramp_decdn_release`, `_decdn_sums_sha256` | `""` | **Required.** `vX.Y.Z` and 64 lowercase hex. |
| `sponsord_onramp_cli_release`, `_cli_sums_sha256` | `""` | **Required.** `decdn-sponsored-vX.Y.Z` and 64 lowercase hex. |
| `sponsord_onramp_min_cli_version` | `""` | Older `decdn-sponsored` CLIs are told to re-run the installer. |
| `sponsord_onramp_brand_name`, `_gate_template_src` | `""` | The gate page's name, or your own HTML page (a control-machine file). |
| `sponsord_onramp_spending_cap_micro_usdc`, `_ttl_secs` | `""` | Requested per capability. `""` takes the daemon's maximum; more than it fails the deploy. |
| `sponsord_onramp_fund_rate_per_min`, `_poll_rate_per_min` | `""` | Per-address rate limits (upstream 10 and 120; `0` turns one off). |
| `sponsord_onramp_bind_address` / `_port` | `127.0.0.1` / `8080` | IPv4 loopback only (asserted). |
| `sponsord_onramp_readiness_retries` / `_delay` | `30` / `2` | `/healthz` window (about 60 s). |

## Bringing your own proxy

With `sponsord_onramp_proxy: none` the role installs no Caddy and opens no port.
Your proxy must terminate TLS for `sponsord_onramp_public_url` and forward to
`127.0.0.1:8080`. Set `sponsord_onramp_client_ip_header` only if the proxy is the
only way to reach the onramp: `CF-Connecting-IP` behind Cloudflare, or
`X-Forwarded-For` if your proxy appends the client address. Otherwise clients can
choose their own address and get around the rate limits. Switching from `caddy`
to `none` closes the firewall holes but leaves the Caddy package installed and
running on 80/443; the role warns about it on every run until you remove it.

## Observability

With `decdn_grafana_cloud_enabled: true`, the `grafana_alloy` role ships the
onramp's journal with `service_name="sponsord-onramp"` and a `level` parsed from each
line (it has no `/metrics`). This repo's playbooks turn that on for hosts in
`sponsord_onramp_hosts`. From your own playbook, set
`grafana_alloy_sponsord_onramp_enabled`. Caddy's unit state is in the systemd
collector; its access logs are not shipped.

## Day 2

- **Rotate the Turnstile secret:** change `sponsord_onramp_turnstile_secret` (or,
  for a host-provisioned secret, write the new one to
  `/etc/sponsord/turnstile-secret`) and re-run the role. It restarts the onramp.
- **Ship a new CLI:** point `sponsord_onramp_cli_release` / `_cli_sums_sha256` (and
  the `decdn` pair) at the new release and re-run. New installs get it; set
  `sponsord_onramp_min_cli_version` to make existing users re-run the installer.
- **Certificate trouble:** `sudo journalctl -u caddy -e`. Check that the domain
  resolves to the host and that tcp/80 and tcp/443 reach it.
- **Logs:** `journalctl -u sponsord-onramp`.
- **Removal:**

  ```bash
  sudo systemctl disable --now sponsord-onramp caddy
  sudo rm /etc/systemd/system/sponsord-onramp.service
  sudo systemctl daemon-reload
  sudo rm -f /usr/local/bin/sponsord-onramp /etc/sponsord/sponsord-onramp.env \
    /etc/sponsord/onramp-gate.html /etc/sponsord/.onramp-inputs.sha256 \
    /etc/sponsord/turnstile-secret
  sudo rm -rf /usr/local/lib/sponsord-onramp
  sudo apt-get remove caddy
  ```

  Then take the host out of `sponsord_onramp_hosts`, so the next deploy closes
  tcp/80 and tcp/443. After a `source` install, remove
  `/var/lib/decdn-build/git/sponsord-onramp` (or the whole build user, `sudo userdel
  decdn-build && sudo rm -rf /var/lib/decdn-build`, once nothing on the host builds
  from source).

## Testing

- `molecule/sponsord-onramp` runs `playbooks/sponsord.yml` (daemon, then onramp) on
  Debian 12 and Ubuntu 24.04, against stub binaries and the real distro Caddy with
  `tls internal`. It checks:
  - idempotence;
  - the `https://` chain through Caddy, and that a client-sent `X-Forwarded-For`
    cannot choose the address the onramp sees;
  - that a Turnstile rotation restarts the onramp and not the daemon;
  - that the `/healthz` gate fails the deploy when the onramp will not start;
  - a custom gate page, and the Turnstile secret from inventory.
- `molecule/sponsord-onramp-caddy` runs beside it on the same converge. It checks
  proxy `none`, ACME mode, a broken upstream behind Caddy, the refusal of a foreign
  Caddyfile, and the confirmed takeover.
- `molecule/validation-sponsord` holds the negative cases.
- `tests/firewall-holes` (`make test-scripts`) pins the tcp/80 and tcp/443 holes.
- `tests/alloy-config` (`make lint-alloy`) runs the onramp's log lines through the
  real Alloy.
- `molecule/cloud-init-sponsord` boots `cloud-init/user-data-sponsord.yaml`, which
  installs both services in release mode from a locally signed mirror, and checks the
  https chain through Caddy. It is the only test of this role's release mode, whose
  tasks mirror the `sponsord` role's (`molecule/sponsord-install` tests those in more depth).
