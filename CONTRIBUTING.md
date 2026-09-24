# Contributing

The repo's first rule: **never commit secrets** (see [`AGENTS.md`](AGENTS.md)). Secrets
are generated on, or operator-provisioned to, the target host; the repo ships `*.example`
templates for them and commits non-secret config directly. There is no dedicated
secret scanner in the pipeline: keep secrets out by design (and rely on GitHub's push
protection).

Commits follow [Conventional Commits](https://www.conventionalcommits.org).

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
| `make molecule` | every `ansible/molecule/*/` scenario in parallel, in privileged systemd containers (needs Docker; cap with `JOBS=<n>`). `make molecule-serial` runs them one at a time for readable failures. |
| `make lint-helm` | chart: `helm lint --strict`, positive/negative render tests, kubeconform (digest-pinned image), the shared schema-key check (needs `helm`, `yq`, `python3` ≥ 3.11, Docker). Set `DECDN_CLI=<path to decdn>` to also run the real `decdn config validate` (CI can't). |
| `make lint-alloy` | renders `roles/grafana_alloy`'s templates and validates them with the **real** digest-pinned Alloy binary. The molecule stub exits 0 for everything, so this is the only gate that proves the config loads. `ALLOY_BIN=<path>` skips the download. |
| `make lint-compose` | renders `compose/compose.yaml` with its example env and asserts its security invariants |
| `make lint-cloud-init` | `cloud-init schema` on `cloud-init/user-data.yaml`, then `cloud-init/tests/lint.py`: no secrets (only the bootstrap's own files, no secret-looking keys or assignments), no hardening skip, a `release` install verified against the vendored key with a host-generated wallet (trust knobs only in `decdn_nodes.vars`), localhost in `decdn_nodes`, a keyed admin account, `runcmd` exactly stage 1, shellcheck-clean scripts, and a collection lock that covers `ansible/requirements.yml` (needs `cloud-init`, `shellcheck`, `yq`). `CLOUD_INIT_FILE=<path>` checks your own filled-in copy. |
| `make test-scripts` | `tests/scripts-test.sh`: the `ansible/Makefile` scoping guards (dry runs), the release gate, and the negative cases of `lint-compose` and `lint-cloud-init` (the latter skipped without `cloud-init` on PATH). `UPSTREAM=<decdn checkout>` adds the sync generators' exit codes. |
| `make security` | KICS IaC scan of `ansible/`, the rendered chart and `compose/` (digest-pinned engine, fail on HIGH) |
| `make galaxy-check` | build the `decdn.node` collection and run galaxy-importer's checks |

`ansible-lint` is **not** a per-commit hook (it needs the collections installed). Run it
with `make lint-ansible`, or `pre-commit run ansible-lint --hook-stage manual`.

### Upstream mirrors

Three things here are generated from `decdn/decdn`; regenerate, never hand-edit:

| Mirror | Regenerate with |
|--------|-----------------|
| `ansible/roles/decdn_node/vars/main/networks.yml` (contract addresses per network) | `scripts/sync-network-profiles.py <decdn-checkout>` |
| `charts/decdn-node/files/monitoring/` (dashboards, alert rules) | `scripts/sync-monitoring.sh <decdn-checkout>` |
| `ansible/molecule/schema/files/schema-keys.txt` (node.toml keys) | `ansible/molecule/schema/files/gen-schema-keys.py <decdn-checkout> > …` |

The two `scripts/sync-*` generators read `origin/main` through git (override with
`--ref`), so the checkout's own branch doesn't matter for them; `gen-schema-keys.py`
reads the checkout's working tree, so check out the ref you mean first. The generators
exit 1 for "stale" and 2 for "could not run"; the weekly `upstream-drift` workflow
reports the two differently.

## CI overview

- **`ci.yml`**, path-filtered so heavy jobs skip unrelated PRs:
  - always: `pre-commit` (every hook, every file), `scripts` (`make test-scripts`) and
    `actionlint`;
  - on `ansible/**`: `ansible-lint` (plus a syntax-check of every playbook),
    `galaxy-build` and `alloy-config` (`make lint-alloy`);
  - on `charts/**` (or the shared schema files, the root `Makefile`, `ci.yml`): `helm`
    (`make lint-helm`);
  - on `compose/**` (or the root `Makefile`, `ci.yml`): `compose` (`make lint-compose`);
  - on `cloud-init/**` (or `ansible/requirements.yml`, the root `Makefile`, `ci.yml`):
    `cloud-init` (`make lint-cloud-init`);
  - on the Ansible, chart or compose paths: `kics` (`make security`). KICS has no
    cloud-init platform.
- **`molecule.yml`**: `make molecule JOBS=3` on `ansible/**` or `cloud-init/**` changes.
  The `cloud-init` scenario boots the real user-data, so it needs network access to apt,
  PyPI and Galaxy.
- **`release.yml`**: on `vX.Y.Z` tags; see [RELEASING.md](RELEASING.md).
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
- **Bump manually** (Dependabot can't parse them): the `KICS_IMAGE` and
  `KUBECONFORM_IMAGE` digests in the `Makefile`; the molecule image digests in
  `ansible/molecule/*/molecule.yml` (all together, `docker buildx imagetools inspect`);
  the four `setup-helm` `version:` inputs (`ci.yml`'s `helm` and `kics` jobs, both
  jobs in `release.yml`); the collection versions in `ansible/requirements.yml`, and
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
