# deCDN node (or sponsor host) from cloud-init user-data

A deCDN node with no machine of your own in the loop. Paste
[`user-data.yaml`](user-data.yaml) into your provider's "create server" form, and a
fresh Debian 12/13 or Ubuntu 24.04/26.04 VM (x86_64 or aarch64) sets itself up. It
hardens itself and stops to wait for its secrets (a node's is its RPC endpoint). You
then SSH in once to write them.

On the host it runs the [Ansible project](../ansible/README.md)'s `site.yml` against
localhost. That means the same `baseline` hardening (nftables default-deny with only
SSH and the host's public services open: udp/4433 for a node, tcp/80 and tcp/443 for a
sponsor host; DevSec SSH/OS hardening, fail2ban, unattended upgrades) and the same
`decdn_node` role (or the `sponsord` roles), with no second copy of any. Nearly
every provider accepts cloud-init: Hetzner, DigitalOcean, OVHcloud, Vultr, AWS,
Scaleway and others.

Pick this path for one VM when you don't want a control machine. For a fleet, or
repeated deploys from your workstation, use the [Ansible project](../ansible/README.md)
directly. [`docs/requirements.md`](../docs/requirements.md) compares the paths.

There are two templates. They share the bootstrap and differ only in their inventory:

| Template | Host | Waits for |
|----------|------|-----------|
| [`user-data.yaml`](user-data.yaml) | a deCDN node | `/etc/decdn/decdn.env` |
| [`user-data-sponsord.yaml`](user-data-sponsord.yaml) | a sponsor host: `sponsord` and `sponsord-onramp` behind Caddy ([Sponsor host](#sponsor-host)) | `/etc/sponsord/{secret.env,treasury-keystore.json,treasury-password,turnstile-secret}` |

To run both on one VM, copy the `decdn_nodes` group from `user-data.yaml` into the sponsor
template's inventory, leaving out its `baseline_*` settings. Ansible applies one
`baseline_sudo_users` list, not the union of two groups', so the lint wants it set once.
The bootstrap then waits for both sets of secrets.

> **Releases only.** The node installs only from a GPG-verified release tarball
> (`release` mode). The `manual` mode would install binaries that nothing verified,
> and the Ansible path's `source` mode builds whatever its git ref points at (and
> takes many minutes on first boot), so the lint refuses both. The release is the
> one the roles pin at `DEVOPS_REF` (decdn/decdn `v0.0.1` today, decdn/sponsord
> `v0.0.2` for a sponsor host); set `decdn_node_version` in the user-data to pin
> another. `decdn_node_release_base` points the download at a mirror that serves
> `v<version>/{decdn-node,decdn}-<version>-<target>.tar.gz`, `SHA256SUMS` and
> `SHA256SUMS.asc`; the signature is still checked against deCDN's release keys.

## What happens at boot

1. cloud-init writes four files early in boot:
   - `/etc/decdn-bootstrap/bootstrap.env`: which revision of this repo to run.
   - `/etc/decdn-bootstrap/inventory.yml`: your non-secret settings.
   - `/usr/local/sbin/decdn-bootstrap`: stage 1 of the bootstrap.
   - `/etc/profile.d/decdn-bootstrap.sh`: the login hint (below).

   In its final stage it installs `git`, `python3-venv`, `ca-certificates` and `sudo`,
   then runs stage 1.
2. **Stage 1** (`decdn-bootstrap`) takes a lock, so only one run happens at a time, and
   records `running`. It clones this repo into `/opt/decdn-devops` at `DEVOPS_REF`. If
   the ref is a full commit SHA, it checks that the checkout really is at that commit.
   It then runs the checkout's [`bootstrap.sh`](bootstrap.sh).
3. **Stage 2** (`bootstrap.sh`) installs the pinned toolchain:
   - ansible-core into `/opt/decdn-bootstrap/venv`, from
     [`requirements.txt`](requirements.txt) with pip's hash checking on;
   - the Galaxy collections at the exact versions in
     [`collections.lock.yml`](collections.lock.yml).

   It then syntax-checks the playbook. It also checks that the inventory puts localhost
   in `decdn_nodes` or `sponsord_hosts` (and in `sponsord_hosts` whenever it is in
   `sponsord_onramp_hosts`). Last, it checks that `--tags baseline` still selects the
   baseline role in every `decdn_nodes` and `sponsord_hosts` play that localhost is in
   ([`baseline-plays.sh`](baseline-plays.sh)). Another group's play does not count,
   so a play that lost the role or its tag stops the run before it reports a host
   hardened that is not.
4. Each of the host's groups needs its secrets on the host: `decdn.env` for the node,
   and the files in the table above for a sponsor. While any is missing, stage 2 runs
   only the `baseline` role, lists the missing paths in
   `/var/lib/decdn-bootstrap/awaiting` and records `awaiting-secret`. With all of them
   present, it runs the whole playbook and records `complete`.

The state is in `/var/lib/decdn-bootstrap/state`: `running`, `awaiting-secret`,
`complete` or `failed`. Any failed run records `failed`, including one that stage 1
refused or a signal interrupted. The login hint (`/etc/profile.d/decdn-bootstrap.sh`)
prints the next step whenever the state is not `complete`, including the missing
secrets while it is `awaiting-secret`. It also says when a
`running` bootstrap is no longer alive, for example after a reboot mid-run. The full
log is in `/var/log/cloud-init-output.log`.

## Set up

1. **Fill in the user-data.** Copy [`user-data.yaml`](user-data.yaml) and replace every
   `CHANGE_ME`:
   - `DEVOPS_REF`: a full 40-character commit SHA of this repo (recommended; it is
     verified after checkout) or a release tag. Branch names are refused.
   - `baseline_sudo_users`: your admin login and your SSH **public** key. Hardening
     disables root and password logins. Some providers (Hetzner, DigitalOcean) inject
     your key for `root` only, so without this entry you are locked out.
   - `decdn_region`: the VM's ISO 3166-1 alpha-2 country code, e.g. `DE`.

   Optional:
   - `ssh_allow_cidrs`, to accept SSH only from your addresses;
   - `decdn_node_version`, to install another release than the one `DEVOPS_REF` pins;
   - `decdn_node_release_base`, for a mirror (see the note above);
   - `decdn_network`, `arbitrum-sepolia` today.

   Any other non-secret role knob can go in the same `vars:` block
   (`ansible/roles/*/defaults/main.yml`). The knobs that decide the install's trust
   (install method, wallet generation, signature verification) stay there too. The lint
   refuses them as host vars, and refuses `decdn_release_keyring` and `decdn_env_file`
   outright. Check the file before you paste it:

   ```bash
   make lint-cloud-init CLOUD_INIT_FILE=path/to/your-user-data.yaml
   ```

   It fails on your edited copy only if an invariant breaks. Examples: a secret added,
   another file written, or `release` mode changed.

2. **Create the VM** with the file as its user data. Examples:
   - **Hetzner Cloud:** "Cloud config" field, or `hcloud server create --user-data-from-file`.
   - **DigitalOcean:** "Advanced options → Add initialization scripts", or the
     `user_data` of a `digitalocean_droplet` in Terraform
     ([#48](https://github.com/decdn/devops/issues/48)).
   - **AWS EC2:** "Advanced details → User data".

   Open **udp/4433** in the provider's own firewall, if it has one. The host's nftables
   already allows it.

3. **Wait for the first boot to finish.** This takes a few minutes: packages, pip,
   Galaxy and the hardening run.

   ```bash
   ssh <admin>@<ip> cloud-init status --wait    # status: done
   ssh <admin>@<ip> cat /var/lib/decdn-bootstrap/state   # awaiting-secret
   ```

   Your admin account exists only once `baseline` has run, near the end of the first
   boot. Until then, and after a failure before that point, log in the way your
   provider set up (often `root` with the injected key).

   `status: error` means the bootstrap failed. The reason is at the end of
   `/var/log/cloud-init-output.log`. Fix it (usually a value in
   `/etc/decdn-bootstrap/inventory.yml`), then run `sudo decdn-bootstrap`.

4. **Write the RPC endpoint on the host.** The URL may embed a provider API key, so it
   never goes in user-data:

   ```bash
   umask 077
   sudo mkdir -p /etc/decdn
   echo 'DECDN_RPC_URL=https://…' | sudo tee /etc/decdn/decdn.env >/dev/null
   sudo chmod 600 /etc/decdn/decdn.env
   ```

   Other environment-borne secrets, such as S3 cache-origin credentials, go in the
   same file ([`decdn.env.example`](../ansible/roles/decdn_node/files/decdn.env.example)).

5. **Install and start the node:**

   ```bash
   sudo decdn-bootstrap        # ends with "decdn-bootstrap: complete"
   ```

   This runs the whole playbook:
   - installs the verified release;
   - generates the node's wallet on the host (`decdn_node_generate_keystore`);
   - writes `node.toml`, and has the real binary validate it;
   - starts `decdn-node`.

6. **Stake and register on chain.** This is an operator step, driven by `decdn setup`.
   Use the `decdn_chain` helper in
   [`docs/lifecycle.md`](../docs/lifecycle.md#running-on-chain-commands):

   ```bash
   decdn_chain setup --mbps 100 --region DE \
     --multiaddr /ip4/<public-ip>/udp/4433/quic-v1 --dry-run
   ```

   `decdn whoami` prints the wallet's address. The address is encrypted inside the
   keystore, so the command needs the keystore password, which is in the root-only
   `/etc/decdn/keystore.password`. Fund the wallet before you run the command without
   `--dry-run`.

## Sponsor host

[`user-data-sponsord.yaml`](user-data-sponsord.yaml) boots a host for the deCDN
onboarding sponsor: the [`sponsord`](../ansible/roles/sponsord/README.md) daemon, which
holds the treasury wallet, and
[`sponsord-onramp`](../ansible/roles/sponsord_onramp/README.md), its public gate, with
Caddy terminating TLS. The flow is the node's. Only the values and the secrets differ.

> **Releases only.** Both services install only from GPG-verified release tarballs
> (`release` mode), and the lint refuses `manual` and `source`. Both come from one
> decdn/sponsord release (`v<version>`), the one the roles pin at `DEVOPS_REF`
> unless the user-data sets `sponsord_version` and `sponsord_onramp_version`.
> `sponsord_release_base` and `sponsord_onramp_release_base` point at a mirror; the
> signature is still checked against the KEYS vendored in the `sponsord` role.

1. **Before you start**, as the role READMEs describe:
   - create the treasury wallet, open its pool (`decdn pool open`, which prints the
     pool id) and fund it;
   - create a Cloudflare Turnstile widget for your domain;
   - check the `decdn` and `decdn-sponsored` releases the installers install: the
     roles' pins at `DEVOPS_REF` unless you set all four `sponsord_onramp_*_release`
     / `_sums_sha256` values.
2. **Fill in the user-data.** Replace every `CHANGE_ME`: `DEVOPS_REF` and
   `baseline_sudo_users` (as for a node), `sponsord_pool_id`,
   `sponsord_onramp_domain`, `sponsord_onramp_rpc_url` and
   `sponsord_onramp_turnstile_sitekey`.
   - `sponsord_onramp_rpc_url` is served to every user, so it must be a **public**
     endpoint with no API key in it. sponsord's own RPC URL may embed a key, so it is
     written on the host instead (step 5).
   - Check the file with
     `make lint-cloud-init CLOUD_INIT_FILE=path/to/your-user-data.yaml`.
3. **Point DNS** for the domain (A/AAAA) at the VM, and open **tcp/80 and tcp/443**
   in the provider's firewall, if it has one. The host's nftables already allows both.
   Caddy needs them to get its certificate.
4. **Create the VM and wait for the first boot.** It ends at `awaiting-secret`, with
   the four sponsor secrets listed in `/var/lib/decdn-bootstrap/awaiting`.
5. **Write the secrets on the host**, as your admin account:

   ```bash
   umask 077
   sudo mkdir -p /etc/sponsord
   sudo install -m 0600 treasury-keystore.json /etc/sponsord/treasury-keystore.json
   sudo install -m 0600 treasury-password      /etc/sponsord/treasury-password
   echo 'SPONSORD_RPC_URL=https://…' | sudo tee /etc/sponsord/secret.env >/dev/null
   sudo chmod 600 /etc/sponsord/secret.env
   printf '%s' '<turnstile secret>' | sudo tee /etc/sponsord/turnstile-secret >/dev/null
   sudo chmod 600 /etc/sponsord/turnstile-secret
   ```

   `secret.env` may hold `SPONSORD_RPC_URL` **only**: the role refuses any other key,
   because an `EnvironmentFile` would override every other setting.
6. **Install and start both services:** `sudo decdn-bootstrap`, which ends with
   `decdn-bootstrap: complete`. The sponsord role generates sponsord's API token on
   the host. sponsord starts only once its keystore decrypts and the treasury owns
   `sponsord_pool_id`. If either check fails, the run fails at sponsord's `/healthz`
   gate (`journalctl -u sponsord`).

Day 2 is in the role READMEs. Rotate a secret by replacing its file and running
`sudo decdn-bootstrap`.

## Operate

- **Re-run or change settings:** edit `/etc/decdn-bootstrap/inventory.yml`, then run
  `sudo decdn-bootstrap`. Once every secret the host needs exists, every run
  converges the whole host again, as `make deploy` does. Before that, runs apply
  `baseline` only.
- **Upgrade the deployment code:** set `DEVOPS_REF` in
  `/etc/decdn-bootstrap/bootstrap.env` to the new SHA or tag, then run
  `sudo decdn-bootstrap`. It fetches, verifies and re-installs the toolchain pinned at
  that revision. Nothing pulls on a timer: the host only runs code you pinned. A tag is
  resolved again on every run, so if someone re-points it, the next run follows. Pin a
  SHA if that matters to you.
- **Upgrade the node or the sponsor:** move `DEVOPS_REF` to a revision that pins the
  new release, or set `decdn_node_version` (or `sponsord_version` and
  `sponsord_onramp_version`) in the inventory, and re-run.
- **Back up, migrate or decommission:** the host is an ordinary Ansible host. Add it to
  an inventory on your workstation with the same groups and variables and use
  `make backup`, `make decommission` and the rest
  ([`docs/lifecycle.md`](../docs/lifecycle.md)). Both cover a sponsor host too: its
  backup carries the treasury keystore and password, the API token and the Turnstile
  secret, and decommission keeps `/etc/sponsord` and never touches the pool on chain.
  From then on,
  manage it from one place: either `decdn-bootstrap` on the host or `make deploy` from
  the workstation, never both.

## Security notes

- **User-data is not private.** Any local process can read it from the instance
  metadata service, and the provider keeps it in its console and API. The file carries
  only public material: an SSH public key, versions, a region or domain, a repo URL, and
  the onramp's public RPC URL and Turnstile sitekey. The secrets are written over SSH,
  and the node's wallet and sponsord's API token are generated on the host.
  `make lint-cloud-init` checks both templates and fails on:
  - any top-level module besides the templates' own (`package_update`, `packages`,
    `write_files`, `runcmd`, `final_message`), since the others (`bootcmd`, `apt`, …)
    run commands or write files outside these checks;
  - YAML anchors or aliases, in the file or its inventory: the lint reads YAML through
    yq, which can resolve a merge key (`<<: *x`) differently from cloud-init and Ansible;
  - any file written besides the bootstrap's own four, a path written twice, empty
    content, and any `write_files` key besides `path`, `owner`, `permissions` and
    `content` (so no encoded, appended, fetched or deferred content);
  - any secret-looking key (RPC URL, password, token, private key, keystore,
    `decdn_extra_env`), except `sponsord_onramp_rpc_url`, which is public by design.
    That one is accepted only in `sponsord_onramp_hosts.vars`, and only in the role's
    own format: no userinfo, query or fragment. A key in its path cannot be detected;
    use a public endpoint.
  - a `NAME=value` assignment of a secret-looking variable anywhere, including
    commands;
  - a URL with embedded credentials;
  - an unknown `bootstrap.env` key;
  - any mention of the test-only switch that skips hardening;
  - any override of a signing key; of a secret's path (`decdn_env_file`,
    `sponsord_etc` and sponsord's secret, treasury and API-token files,
    `sponsord_onramp_etc` and the onramp's token and Turnstile files), since the gate
    looks for the secrets at the roles' defaults; or of sponsord's API-token and
    treasury-wallet generation, since the token is always generated on the host and
    the wallet is the operator's;
  - an inventory group other than `decdn_nodes`, `sponsord_hosts` and
    `sponsord_onramp_hosts`, a group holding anything but `hosts` and `vars` (no
    `children:`), a host other than localhost, or the onramp without `sponsord_hosts`;
  - `baseline_sudo_users` set in more than one place.
- **Everything is pinned.**
  - This repo: by commit SHA (checked after checkout), or by tag, which is weaker
    because a tag can be moved.
  - ansible-core: by version and hash.
  - The collections: by exact version.
  - The node, sponsord and sponsord-onramp: by release version, installed only if
    `SHA256SUMS` carries a valid signature from a vendored release key. The lint
    refuses a user-data that turns a `*_verify_release_signature` off, swaps a
    `*_release_keyring`, or sets an install method or signature switch outside its
    own group's `vars`.

  Nothing is piped from `curl` into a shell.
- **No lockout.** Baseline refuses to harden SSH unless `baseline_sudo_users` names a
  non-root account with a key.
- **The network posture is the role's.** It is nftables default-deny with only SSH and
  the host's public services open: the node's QUIC udp/4433, and tcp/80 + tcp/443 for
  the onramp's Caddy. Metrics, the admin RPC and both sponsor daemons stay on loopback.
- The files in `/etc/decdn-bootstrap/` are `root` `0600`. `decdn-bootstrap` refuses a
  `bootstrap.env` that is not `root`-owned `0600`. It reads the file as literal
  `KEY=value` lines and never sources it, and it rejects unknown keys. That leaves no
  way to pass Ansible arguments (extra-vars or skipped tags) from user-data.
- `runcmd` must be exactly stage 1, so a failure always reaches `cloud-init status`.

What CI proves:

- `make lint-cloud-init` (CI job `cloud-init`) checks the schema and the invariants
  above, and `make test-scripts` checks that it rejects broken variants.
- The molecule `cloud-init` scenario boots `user-data.yaml` with cloud-init in Debian
  12 and Ubuntu 26.04 containers. It covers the secret gate first. It then checks that
  stage 1 refuses a branch name, the placeholder ref, an unknown key and a loose file mode,
  each recording `failed`. Finally, after an upgrade to a tag and `decdn.env`, it
  covers a running node installed from a locally signed mirror.
- The molecule `cloud-init-sponsord` scenario boots `user-data-sponsord.yaml` in an
  Ubuntu 26.04 container. It checks that stage 2 refuses an inventory with localhost
  in neither base group, and one with the onramp outside `sponsord_hosts`, each
  recording `failed`. It writes sponsord's secrets but not the Turnstile secret, and
  checks that the gate still holds for that one file. It then covers both services
  installed from a locally signed mirror, and the onramp answering through Caddy.
- Both scenarios skip `baseline`, because host hardening means nothing in a container.
  It is exercised on real hosts, as for the Ansible path. `make test-scripts` checks
  that every `decdn_nodes` and `sponsord_hosts` play keeps the role and its tag.

## Updating the pins

- **ansible-core:** edit [`requirements.in`](requirements.in), then regenerate:

  ```bash
  uv pip compile --universal --generate-hashes --python-version 3.11 \
    cloud-init/requirements.in -o cloud-init/requirements.txt
  ```

  Keep a pin whose controller Python range covers 3.11 (Debian 12) and one covering
  3.12 to 3.14 (Ubuntu 24.04, Debian 13, Ubuntu 26.04).
- **Collections:** resolve from scratch (`rm -rf ansible/collections && make -C ansible
  deps`), because an existing tree keeps what it has. Then copy the resolved versions
  into [`collections.lock.yml`](collections.lock.yml). `make lint-cloud-init` checks the
  lock against `ansible/requirements.yml`. The molecule `cloud-init` scenario checks
  that a node ends up with exactly the locked set.
