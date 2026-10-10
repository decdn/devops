# Contributing

The repo's first rule: **never commit secrets** (see [`AGENTS.md`](AGENTS.md)). Secrets
are generated on, or operator-provisioned to, the target host; the repo ships `*.example`
templates for them and commits non-secret config directly. There is no dedicated
secret scanner in the pipeline: keep secrets out by design (and rely on GitHub's push
protection).

Commits follow [Conventional Commits](https://www.conventionalcommits.org). PRs are
squash-merged with the PR title as the commit subject, and `scripts/release.sh` renders
the subjects into the collections' and the chart's changelogs at release (see
[RELEASING.md](RELEASING.md)). Write a title an operator can read as a changelog entry;
the `pr-title.yml` workflow refuses a title that is not conventional, with a lowercase
type, one of `feat` `fix` `perf` `refactor` `docs` `chore` `revert` `security` `ci`
`test` `style` `build`. Until an
artifact's first release, also add an entry under `[Unreleased]` in its changelog by
hand: that section becomes the first release's notes.

## One-time setup

```bash
pip install pre-commit      # or: pipx install pre-commit
make hooks                  # installs the git pre-commit hook
```

After this, every commit runs hygiene checks, `shellcheck`, `yamllint` (Ansible tree)
and `markdownlint`. CI runs the same hooks on every file, so skipping this only moves
the failure to the PR.

## Make targets

The root `Makefile` is the check driver (`make help` lists it); CI calls the same
targets, so a local pass means a CI pass. Deploy targets live in
[`ansible/Makefile`](ansible/README.md) and run from `ansible/`.

| Target | What it does |
|--------|--------------|
| `make lint` | every pre-commit hook on every file (CI job `pre-commit`) |
| `make lint-ansible` | install Galaxy collections + `ansible-lint` (production profile, which includes the Ansible security rules) |
| `make molecule` | every `ansible/molecule/*/` scenario in parallel, in privileged systemd containers (needs Docker and util-linux `flock`; cap with `JOBS=<n>`, pick some with `SCENARIOS='a b'`). `make molecule-serial` runs them one at a time for readable failures. Each scenario takes its own host-wide lock, so two runs can share a host as long as they share no scenario (a run that would refuses to start: runs of one scenario share its container names). `make molecule-list` prints the selection as JSON (CI's matrix). The driver is `scripts/molecule.sh`. |
| `make lint-helm` | chart: `helm lint --strict`, positive/negative render tests, kubeconform and `promtool check rules` on the alert rules (digest-pinned images), the shared schema-key check (needs `helm`, `yq`, `python3` ≥ 3.11, Docker). Set `DECDN_CLI=<path to decdn>` to also run the real `decdn config validate` (CI can't). |
| `make lint-alloy` | renders `roles/grafana_alloy`'s templates and validates them with the **real** digest-pinned Alloy binary. The molecule stub exits 0 for everything, so this is the only gate that proves the config loads. `ALLOY_BIN=<path>` skips the download. |
| `make lint-compose` | renders `compose/compose.yaml` with every profile on (with its example env, without env files, with an empty `.env`) and asserts `compose/tests/invariants.jq`, `inline-env.jq` and `fail-closed.jq` |
| `make lint-cloud-init` | `cloud-init schema` on `cloud-init/user-data-node.yaml` and `cloud-init/user-data-publisher.yaml`, then `cloud-init/tests/lint.py` on each: only the templates' top-level modules and no YAML anchors, no secrets (only the bootstrap's own files, once each, plain `content` only, no secret-looking keys or assignments), no hardening skip, `release` installs verified against the vendored keys with a host-generated node wallet (trust knobs only in their own group's `vars`, no moved keyring or secret path), only localhost, in `decdn_nodes` and/or `sponsord_hosts` (an origin only beside `decdn_nodes` and with a backend, every backend key only in `decdn_origin_nodes.vars`, the onramp only beside sponsord), a keyed admin account, `runcmd` exactly stage 1, shellcheck-clean scripts, and a collection lock that covers `ansible/requirements.yml` (needs `cloud-init`, `shellcheck`, `yq`). `CLOUD_INIT_FILE=<path>` checks your own filled-in copy. |
| `make test-scripts` | `tests/scripts-test.sh`: the `ansible/Makefile` scoping guards (dry runs, and `limit-guard.sh` on a fixture inventory), the molecule driver's selection guards and locks (no containers), the split scenarios' shared inventories, the release gate, `scripts/release.sh` on a fixture repo and `pr-title.yml`'s check (the former skipped without `git-cliff` or `ssh-keygen` on PATH, failed in CI), the negative cases of `lint-compose` and `lint-cloud-init` (the latter skipped without `cloud-init` on PATH), and the cloud-init bootstrap's contracts: `baseline-plays.sh` on fixtures and on the real playbooks (every node.yml, origin.yml and sponsord.yml play runs `baseline` tagged `baseline`), the two templates' shared stage 1, login hint and `final_message`, `bootstrap.sh`'s groups against lint.py's, and lint.py's `FORBIDDEN_VARS` against the roles' keyrings and secret paths. `UPSTREAM=<decdn checkout>` adds the sync generators' exit codes. |
| `make security` | KICS IaC scan of `ansible/`, the rendered chart and `compose/` (digest-pinned engine, fail on HIGH) |
| `make galaxy-check` | build the `decdn.node` and `decdn.publisher` collections and run galaxy-importer's checks on each (`make -C ansible galaxy-check-node` / `galaxy-check-publisher` for one) |

`ansible-lint` is **not** a per-commit hook (it needs the collections installed). Run it
with `make lint-ansible`, or `pre-commit run ansible-lint --hook-stage manual`.

### Upstream mirrors

Two things here are generated from `decdn/decdn`; regenerate, never hand-edit:

| Mirror | Regenerate with |
|--------|-----------------|
| `ansible/roles/{decdn_node,sponsord,sponsord_onramp}/vars/main/networks.yml` (contract addresses per network) | `scripts/sync-network-profiles.py <decdn-checkout>` |
| `ansible/molecule/schema/files/schema-keys.txt` (node.toml keys) | `ansible/molecule/schema/files/gen-schema-keys.py <decdn-checkout> > …` |

Both describe the release the roles pin (`decdn_node_version`), so generate them from
its tag. `scripts/sync-network-profiles.py` reads git at `--ref`, which defaults to
that tag, whatever the checkout's own branch; `gen-schema-keys.py` reads the
checkout's working tree, so check out the tag first.
The full bump checklist is in `ansible/roles/decdn_node/README.md`.
`sync-network-profiles.py --check` exits 1 for "stale" and 2 for "could not run";
the weekly `upstream-drift` workflow wraps `gen-schema-keys.py` in a generate-then-diff
check so it reports the two differently too.

The Grafana dashboards and Prometheus alert rules in `monitoring/` are not a mirror:
they are maintained here. See [its README](monitoring/README.md).

## CI overview

- **`ci.yml`**, path-filtered so heavy jobs skip unrelated PRs:
  - always: `pre-commit` (every hook, every file), `scripts` (`make test-scripts`) and
    `actionlint`;
  - on `ansible/**`: `ansible-lint` (plus a syntax-check of every playbook),
    `galaxy-build` and `alloy-config` (`make lint-alloy`);
  - on `charts/**` or `monitoring/**` (or the shared schema files, the root `Makefile`,
    `ci.yml`): `helm` (`make lint-helm`);
  - on `compose/**` (or the root `Makefile`, `ci.yml`): `compose` (`make lint-compose`);
  - on `cloud-init/**` (or `ansible/requirements.yml`, the root `Makefile`, `ci.yml`):
    `cloud-init` (`make lint-cloud-init`);
  - on the Ansible, chart or compose paths: `kics` (`make security`). KICS has no
    cloud-init platform.
- **`molecule.yml`**: on `ansible/**`, `cloud-init/**` or `scripts/molecule.sh` changes, one runner per
  scenario (`make molecule SCENARIOS=<one>`), the matrix read from `make molecule-list`.
  The `molecule` job aggregates them: it is the one check name to require, since the
  per-scenario names follow the scenario list. The `cloud-init` and
  `cloud-init-publisher` scenarios boot the real user-data templates, so they need
  network access to apt, PyPI and Galaxy. Keep each scenario well under its leg's
  timeout; when one grows, split it along its side effects (as `sponsord-install`,
  `sponsord-onramp-caddy`, `sponsord-onramp-source`, `iroh-relay-gate`,
  `source-build-recovery` and the `validation-*` scenarios are), or move a play into
  a short sibling that already shares its converge. `source-build`, its two siblings
  and `sponsord-onramp-source` download rustup and a Rust toolchain from
  static.rust-lang.org.
- **`pr-title.yml`**: on every PR, and again when its title is edited: the title (the
  squash-merge subject, which `scripts/release.sh` renders into the changelogs) must be
  a Conventional Commit. It blocks a merge only as a required status check of the
  `main` ruleset.
- **`release-collection.yml`** / **`release-chart.yml`**: on `node-collection-vX.Y.Z`
  and `publisher-collection-vX.Y.Z` / `decdn-node-X.Y.Z` tags, which
  `scripts/release.sh` pushes; see
  [RELEASING.md](RELEASING.md).
- **`upstream-drift.yml`**: weekly, non-blocking; see "Upstream mirrors" above.
- **Every job is bounded** by `timeout-minutes`. The values are bounds sized off
  observed runtimes, not targets. Without one a hung job burns the 360-minute default,
  and combined with `cancel-in-progress` some branch-protection setups read the
  resulting *cancelled* check as "not failed".
- **Caches.** `ansible/collections` is cached across `ansible-lint`, `galaxy-build` and
  `molecule` under one shared key; a hit makes `make deps` a no-op that never contacts
  `galaxy.ansible.com`, which keeps a transient Galaxy error from failing an unrelated
  PR. It uses `actions/cache`'s split `restore`/`save` with `save` gated on success, so a
  part-way Galaxy failure can't poison it. pip is cached by `setup-python`, keyed on the
  workflow file (the repo has no pip manifest; installs stay unpinned, so that saves the
  download, not the PyPI round trip). pre-commit's hook environments are cached on
  `.pre-commit-config.yaml`.

## Supply-chain / pinning rules

- **Third-party actions are pinned to a full commit SHA** with a version comment
  — a mutable tag can be re-pointed to malicious code.
- **`Checkmarx/kics-github-action` is deliberately not used.** Its git tags were
  hijacked in the March 2026 TeamPCP attack (CISA KEV), and even post-remediation
  its entrypoint `apk add`s `nodejs`/`npm` at *run* time inside its digest-pinned
  base image and executes the result — an unpinned fetch that defeats the pinning.
  (That fetch also breaks it outright today: Chainguard's current nodejs needs a
  newer glibc than the pinned base ships, so the action's Node reporter dies and
  the step fails regardless of findings.) CI instead runs `make security`, which
  drives the **Docker Hub** KICS engine image — a different artifact from the
  hijacked action — pinned by a digest verified against Docker Hub, currently
  `v2.1.20`. The engine's `--fail-on high` exit code is the gate.
- **Dependabot** (`.github/dependabot.yml`) bumps the action SHAs and the pre-commit
  hook revs weekly.
- **Bump manually** (Dependabot can't parse them): the `KICS_IMAGE`,
  `KUBECONFORM_IMAGE` and `PROMTOOL_IMAGE` digests in the `Makefile`; the molecule image digests in
  `ansible/molecule/*/molecule.yml` (all together, `docker buildx imagetools inspect`);
  the five `setup-helm` `version:` inputs (`ci.yml`'s `helm`, `kics` and `scripts`
  jobs, both jobs in `release-chart.yml`); the collection versions in `ansible/requirements.yml`, and
  their exact pins in `cloud-init/collections.lock.yml` (the full transitive set, from
  a fresh `make deps` resolve); ansible-core in `cloud-init/requirements.in`, followed by a
  recompile of the hash-locked `requirements.txt` (command in `cloud-init/README.md`);
  and the local yamllint hook's `additional_dependencies` pin.
- **Bump the `cache-epoch:` counter in `ansible/requirements.yml` to make CI
  re-resolve the collections.** Those are `>=` ranges, so a warm cache pins the
  resolved set — transitive collections like `community.crypto` included — until the
  file changes; the counter forces a fresh resolve without editing the requirements
  themselves. It is a comment, but a load-bearing one: the cache key is that file's
  hash. Keeping it *in* the hashed file is deliberate — an epoch duplicated across
  both workflows could drift, since neither workflow runs on a change to the other.
