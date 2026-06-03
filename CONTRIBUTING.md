# Contributing

Two checks run on every change: **pre-commit** locally and **GitHub Actions** on
push / PR. The repo's #1 rule still stands — **never commit secrets** (see
[`CLAUDE.md`](CLAUDE.md)); secrets are generated on the target host and the repo
ships `*.example` templates only. There is no dedicated secret-scanner in the
pipeline — keep secrets out by design (and rely on GitHub's push protection).

## One-time setup

```bash
pip install pre-commit      # or: pipx install pre-commit
make hooks                  # installs the git pre-commit hook
```

After this, every commit runs hygiene checks, `shellcheck`, `yamllint` (Ansible
tree), and `markdownlint`.

## Useful targets (`make help`)

| Target | What it does |
|--------|--------------|
| `make lint` | run all pre-commit hooks on every file (mirrors the CI `pre-commit` job) |
| `make lint-ansible` | install Galaxy collections + run `ansible-lint` (its production profile includes the Ansible security rules) |
| `make security` | KICS IaC security scan of `ansible/` (engine image; CI uses the official KICS action) |
| `make molecule` | containerised converge/verify of the anvil stack (needs Docker) |

`ansible-lint` is **not** a per-commit hook (it needs the collections installed).
Run it on demand with `make lint-ansible`, or `pre-commit run ansible-lint --hook-stage manual`.

## CI overview

- **`ci.yml`** — `pre-commit`, `ansible-lint` + `kics` (on `ansible/**`), and
  `actionlint`. Bash-only PRs skip the Ansible jobs.
- **`molecule.yml`** — runs on `ansible/**` changes; **blocking**. Add it as a
  required status check in branch protection (Settings → Branches) once proven,
  alongside the `ci.yml` jobs.

## Supply-chain / pinning rules

- **Third-party actions are pinned to a full commit SHA** with a version comment
  — a mutable tag can be re-pointed to malicious code.
- **`Checkmarx/kics-github-action`** was hijacked in the March 2026 TeamPCP attack
  (CISA KEV) and has since been remediated. It is pinned to the **post-remediation
  hardened HEAD** by SHA — *not* a release tag, because the newest tag (`v2.1.20`)
  predates the April hardening. Dependabot is told **not** to bump it
  (`.github/dependabot.yml`); re-pin manually only after verifying a newer clean
  commit. The KICS engine image used locally (`make security`) is pinned to the
  pre-incident `v2.1.19` digest.
- **Dependabot** (`.github/dependabot.yml`) bumps the other action SHAs weekly.
- **Bump manually** (Dependabot can't): the `KICS_IMAGE` digest in the `Makefile`,
  and the pre-commit hook revs via `pre-commit autoupdate`.

## Solidity

The `services/anvil-devnet/contracts/` Foundry project has no `.sol` sources yet.
The `forge fmt` pre-commit hook and the CI `solidity` job are present but
commented out; they self-activate once real sources land.
