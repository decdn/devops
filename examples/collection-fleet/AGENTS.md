# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in this fleet
repository. `CLAUDE.md` includes this file.

## What this repo is

A deCDN fleet as **inventory only**. Every role and playbook comes from the
[`decdn.node`](https://galaxy.ansible.com/ui/repo/published/decdn/node/) and
[`decdn.publisher`](https://galaxy.ansible.com/ui/repo/published/decdn/publisher/)
Galaxy collections (`requirements.yml`, installed into the git-ignored
`collections/`). The layout is decdn/devops's
[`examples/collection-fleet`](https://github.com/decdn/devops/tree/main/examples/collection-fleet).

There are no roles or playbooks here. Role variables, their defaults and the role
READMEs live in the installed collections
(`collections/ansible_collections/decdn/{node,publisher}/roles/`): read them there,
not from memory. A change to a role or playbook is made upstream in
[decdn/devops](https://github.com/decdn/devops) and arrives with a collection release.

## Hard rules

1. **Never commit secrets.** No passwords, private keys, API tokens, RPC URLs with keys
   in them or keystores in any tracked file. Inventory secrets live in the git-ignored
   `secret.yml` files (`host_vars/<host>/` or `group_vars/<group>/`) or, if this fleet
   opted in, in ansible-vault encrypted `vault.yml` files beside them, the one secrets
   file that is committed (`README.md` § Encrypted secrets). Change a `vault.yml` only
   with `ansible-vault edit`, never decrypt it in place, and never put the vault
   password in the repository. Host secrets are generated on, or provisioned by the
   operator to, the host. `.gitignore` is a backstop, not the design.
2. **Infrastructure only.** Protocol and economic facts trace to the
   [deCDN ADRs](https://github.com/decdn/decdn/tree/main/adr). Contract addresses come
   only from the collections' network profile (`decdn_network`), never copied into the
   inventory or docs.
3. **Show before deploying.** Present inventory changes; a playbook run is what mutates
   a host. Dry-run with `--check --diff` first, always pass `-l` (nothing here stops a
   run from reaching every host the playbook targets, but for decommission's
   `decdn_decommission_max_hosts` cap, and a `-l` that matches none of them exits 0
   having done nothing), and read the PLAY RECAP.

## Gotchas

- **A vars directory shadows the file beside it.** Ansible reads one of
  `group_vars/<group>/`, `<group>.yml`, `<group>.yaml` and `<group>.json` and ignores
  the rest, silently. To give a group a `secret.yml`, first move its `<group>.yml` to
  `<group>/main.yml`; never keep both. The same holds for `host_vars/`.
  `scripts/check-vars-shadowing.sh` refuses such a pair (the pre-commit hook runs it on
  the working tree, where the git-ignored directories exist; CI on the tracked files).
- **Host vars beat group vars.** A `host_vars/<host>/secret.yml` overrides the same
  variable in a group's `secret.yml`; a secret every host shares belongs in
  `group_vars/all/` (move `all.yml` to `all/main.yml` first).
- **No `ansible_user` by default.** Runs connect as the local `$USER`, the admin
  account `baseline` creates. A fresh host's first run connects once as root or the
  image's bootstrap user (`-u root`; `README.md` § Run and the hosts example's header
  say how); root login is off after it. Never set `ansible_user` to the bootstrap user.
- **Ubuntu 25.10+ ships sudo-rs**, which hangs Ansible's become prompt, but only when
  a become password is sent (`baseline_sudo_passwordless: false`; the default is
  passwordless). Then set `ansible_become_exe: /usr/bin/sudo.ws` on that host
  (`inventory/hosts-node.yml.example`'s header explains).
- **Never run `decdn.node.decommission` on a host that also runs sponsord, a relay or
  a DNS server**: it removes the Grafana Alloy agent they share. Use
  `decdn.publisher.decommission`.
- **Until you pin `==X.Y.Z`, collections float on `>=` floors.** CI installs the
  newest release; a new release can move the default decdn or sponsord release line. Read each collection's
  [CHANGELOG](https://github.com/decdn/devops/tree/main/ansible/galaxy) before an
  `--upgrade`.

## Commands

```bash
ansible-galaxy collection install -r requirements.yml -p collections   # once, and after a bump (--upgrade)
ansible-playbook decdn.publisher.site -l <host> --check --diff          # dry run
ansible-playbook decdn.publisher.site -l <host>                         # deploy what the host's groups call for
ansible-playbook decdn.publisher.backup -l <host>                       # fetched to backups/ (git-ignored)
ansible-playbook decdn.publisher.decommission -l <host>                 # typed confirmation; keeps the keys
ansible-vault edit inventory/group_vars/<group>/vault.yml               # change encrypted secrets (ANSIBLE_VAULT_PASSWORD_FILE set)
pre-commit run --all-files                                              # the lint gate CI runs
```

With `decdn.node` alone (cache nodes only), use `decdn.node.node`, `decdn.node.backup`
and `decdn.node.decommission`. `README.md` maps decdn/devops's `make` targets to these
commands.

## CI

`.github/workflows/ci.yml`: `pre-commit` (every hook, every file), `ansible` (a fresh
Galaxy install, `scripts/check-vars-shadowing.sh`, `ansible-inventory --list`, which
loads every vars file, and `--syntax-check` of the site, backup and decommission
playbooks), and `actionlint`. None of it checks what a role makes of your variables:
only a `--check --diff` run does. Committed `vault.yml` files must each decrypt with
the `ANSIBLE_VAULT_PASSWORD` repository secret when it is set, and are replaced by `{}`
in the checkout when it is not; the `vault-encrypted` hook checks each one is encrypted.

## This fleet

<!-- Fill in: the hosts and their groups, where each runs, which release line or exact
release each follows, where the fleet-wide secrets live, and anything a host does
differently. -->
