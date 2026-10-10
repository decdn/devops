# Releasing

The repo publishes three artifacts, each on its own version and released by its own tag:

| Artifact | Tag | Workflow | Published to | Install |
|----------|-----|----------|--------------|---------|
| `decdn.node` Ansible collection (node operators) | `node-collection-vX.Y.Z` | [`release-collection.yml`](.github/workflows/release-collection.yml) | [Ansible Galaxy](https://galaxy.ansible.com/ui/repo/published/decdn/node/) | `ansible-galaxy collection install decdn.node:==X.Y.Z` |
| `decdn.publisher` Ansible collection (publishers) | `publisher-collection-vX.Y.Z` | [`release-collection.yml`](.github/workflows/release-collection.yml) | [Ansible Galaxy](https://galaxy.ansible.com/ui/repo/published/decdn/publisher/) | `ansible-galaxy collection install decdn.publisher:==X.Y.Z` |
| `decdn-node` Helm chart | `decdn-node-X.Y.Z` | [`release-chart.yml`](.github/workflows/release-chart.yml) | `oci://ghcr.io/decdn/charts`, signed with cosign (keyless) | `helm install <release> oci://ghcr.io/decdn/charts/decdn-node --version X.Y.Z` |

Release an artifact when it has changes; the others are not touched. Their versions are
independent. The one dependency is Galaxy's: `decdn.publisher` requires `decdn.node`
(its playbooks run `decdn.node`'s baseline, Alloy and origin nodes), so the publisher
collection's first release comes after the node collection's. `scripts/release.sh`
refuses any publisher release whose `decdn.node: ">=X.Y.Z"` no `node-collection-v*`
tag on origin satisfies yet. A tag is not a Galaxy upload, so the publish job also
asks Galaxy, before uploading a `decdn.publisher`, for a `decdn.node` that satisfies
it, and fails while there is none: publish that node release, then re-run the job. What the artifacts must agree on is checked by CI, not by a shared
version: the decdn version (the chart's `appVersion` and the role's
`decdn_node_version`) on every PR (`make test-scripts`), and the config keys each one
renders against the same upstream schema-key inventory whenever either changes
(`make lint-helm`, `molecule/schema`). When a change lands in several (a decdn bump
touches the node collection, the publisher collection and the chart), release each.

Each workflow's `build` job runs on every matching tag push. It gates the tag
(`scripts/check-release-version.sh`), re-runs that artifact's checks (`make
galaxy-check-node`, `make galaxy-check-publisher` or `make lint-helm`), packages it,
and uploads it with a `SHA256SUMS` as a workflow artifact. The `publish` job pushes it to Galaxy or ghcr.io and creates the GitHub
Release, but **only** when the repository variable `PUBLISH_ENABLED` is `true`. Until
then, a tag push is a dry run. So is a manual *Run workflow* (`workflow_dispatch`) with an
existing tag. Before a tag exists, the rehearsal is `scripts/release.sh`'s dry run and the
artifact's make target (below). The repo's *Latest* release is the highest `decdn.node`
version, the node operator's collection: a node collection release is marked Latest only
when no higher `node-collection-v` release exists (so a patch to an older line does not
take it), and publisher collection and chart releases never are (`--latest=false`).
Collection publishes run one at a time, so two cannot race for it.

## Cutting a release

A release is cut on `main`, with no release PR, by
[`scripts/release.sh`](scripts/release.sh), a wrapper around
[git-cliff](https://git-cliff.org) in the manner of `cargo release`:

```bash
scripts/release.sh chart                     # dry run: the new tag and the diff
scripts/release.sh chart --execute           # bump, check, commit, tag, push
scripts/release.sh node-collection minor --execute
```

The first argument is the artifact (`node-collection`, `publisher-collection` or
`chart`); the second is the level:
`auto` (the default), `patch`, `minor`, `major` or an explicit `X.Y.Z`. Without
`--execute`, it is a dry run: it runs steps 1 to 4, prints the new tag and the diff it
would commit, and changes no file. The script:

1. **Refuses unconventional commits.** It looks at the commits since the artifact's
   last tag that touched what it ships: for a collection, the roles its
   `ansible/galaxy/<collection>/roles.txt` lists (the list `galaxy/build.sh` reads), that
   overlay, `ansible/galaxy/build.sh` and `LICENSE`; for the chart, `charts/decdn-node/`
   and `monitoring/decdn-node/`.
   git-cliff drops a commit it cannot parse as a Conventional Commit, from the
   changelog and from the bump, and only logs a count. That covers an unconventional
   subject, but also an empty scope (`feat(): …`) and a body right under the subject
   with no blank line. The script has git-cliff name every such commit
   (`require_conventional`) and stops; `--allow-unconventional` releases without them.
2. **Picks the version.** `auto` is the bump git-cliff derives (`cliff.toml`) from
   those commits. Before 1.0, a feature bumps the minor, and so does a breaking change
   from 0.1 on (at 0.0.x it bumps the patch); any other commit kept in the changelog
   bumps the patch. It refuses when none of those commits makes a changelog entry
   (they are all `ci`, `test`, `style`, `build` or release commits, or unconventional
   ones `--allow-unconventional` leaves out), whatever the level.
3. **Sets `version:`** in `ansible/galaxy/<collection>/galaxy.yml` or
   `charts/decdn-node/Chart.yaml`.
   The chart's `appVersion` and its `artifacthub.io/images` tag already follow the
   role's `decdn_node_version` (`make test-scripts` refuses a PR where they differ), so
   a decdn bump is a chart change too: release the chart.
4. **Writes the changelog section.** It renders the same commits into a dated
   `## [X.Y.Z] — YYYY-MM-DD` section at the top of the artifact's `CHANGELOG.md`:
   `feat` under Added, `fix` under Fixed, `revert` under Removed, `security` under
   Security, and `perf`, `refactor`, `docs`, `chore` and any other type under Changed
   (types match case-insensitively). `ci`, `test`, `style` and `build` commits are
   left out unless breaking (those go under Changed); release commits always are. A
   commit is breaking
   with a `!` or a `BREAKING CHANGE:` footer, and its entry starts with **Breaking:**.
   An entry is the subject without its type, the scope in bold and the first letter
   capitalised: `fix(chart): drop a label (#12)` becomes `- **chart**: Drop a label
   (#12)`. PRs are squash-merged with the PR title as the subject, so write the title
   as a changelog line for an operator; `pr-title.yml` checks it is conventional. The
   section becomes the GitHub Release notes, and the chart's also becomes the packaged
   chart's `artifacthub.io/changes` annotation (`scripts/chart-artifacthub-changes.py`),
   so the script refuses any heading that is not a Keep a Changelog kind.
5. **Checks** (`--execute` only) with `scripts/check-release-version.sh <tag>`, plus
   `scripts/chart-artifacthub-changes.py` for the chart, then the artifact's make
   target, `make -C ansible galaxy-check-<collection>` or `make lint-helm`
   (`--no-verify` skips the make target only). A tag whose workflow fails burns its version, so the checks run
   before anything is committed.
6. **Commits** (`--execute` only) `chore(release): <tag>` and tags `<tag>`, both
   signed, and pushes them with `git push --atomic origin main <tag>`: origin gets both
   or neither. If a check or the commit (a pre-commit hook, say) fails, both files are
   restored and nothing is committed. If tagging or the push fails, or the script is
   stopped after the commit, the commit (and the tag) stay local, and it says whether
   origin got anything and how to undo. A refusal before step 5 never touches the
   working tree.

While `PUBLISH_ENABLED` is not `true`, the script says so before it writes anything (it
reads the variable with `gh`, when it can): the tag push then only builds the artifact,
and the version is used up all the same.

Then **watch** the *Release collection* or *Release chart* workflow (`gh run list
--workflow release-chart.yml`). With publishing enabled, the `publish` job waits for
approval on the `release` environment. Release each artifact on its own run; when a
change lands in several, run the script once for each.

**Prerequisites.**

- [git-cliff](https://git-cliff.org) 2.9 or later, for `require_conventional`
  (`cargo install git-cliff`; CI tests with 2.14.1). The first release does not use it.
- Git configured to sign, with `user.signingkey` set explicitly. The script signs a
  throwaway commit object first, so a key that cannot sign fails before the checks.
- A clean `main` equal to `origin/main`, and no local tag of the artifact above
  origin's highest. Release a commit whose CI is green.
- A bypass of the `main` ruleset, because the release commit goes straight to `main`:
  its pull-request rule and its required status checks (`pr-title` among them) both
  apply to a direct push.
- The repository settings the changelog relies on: squash merges only, with the PR title
  as the squash commit's subject (*Settings → General → Pull Requests*, and the `main`
  ruleset's allowed merge methods), and `pr-title` a required status check.

**The first release** of each artifact starts from the `0.0.0` placeholder in its
manifest and names its level: `scripts/release.sh chart minor --execute` cuts `0.1.0`.
Without a tag, git-cliff would render the whole history, so the first release does not
use it. It renames the changelog's hand-written `## [Unreleased]` section to the dated
version instead, so until then, changes are logged there by hand. After that, no
`[Unreleased]` section is kept: the script refuses one, because every later section is
generated.

The chart's tag shape (`decdn-node-`) and workflow file name (`release-chart.yml`) are
part of its cosign certificate identity (see [Verifying a release](#verifying-a-release)):
never change either once a chart is published.

## First release only

Before the first publish:

- **Galaxy namespace.** The `decdn` namespace must exist on galaxy.ansible.com and the
  account behind `GALAXY_API_KEY` must be allowed to publish to it. Add the key as the
  repository secret `GALAXY_API_KEY`.
- **`release` environment.** Create it under *Settings → Environments* with required
  reviewers, and put `GALAXY_API_KEY` there rather than as a repository secret if you
  want the reviewer gate to guard it too.
- **Enable:** set the repository variable `PUBLISH_ENABLED` to `true`, then cut the
  releases as above, `node-collection` before `publisher-collection` (Galaxy resolves
  `decdn.publisher`'s dependency on `decdn.node` at install). Every artifact sits at the
  `0.0.0` placeholder, so `scripts/release.sh <artifact> minor --execute` makes the
  first three tags `node-collection-v0.1.0`, `publisher-collection-v0.1.0` and
  `decdn-node-0.1.0`; their versions diverge from then on.

After the first chart publish (the package does not exist before it):

- **GHCR visibility.** The first `helm push` creates the `decdn/charts/decdn-node`
  package as **private**. Make it public under the org's *Packages* settings, or
  nobody outside the org can pull it, Artifact Hub included.
- **Artifact Hub.** Sign in to artifacthub.io with the `info@decdn.org` account and add
  a Helm repository with the URL `oci://ghcr.io/decdn/charts/decdn-node`. That account
  owns it and Artifact Hub lists the chart from then on. (`owners` in
  `charts/decdn-node/artifacthub-repo.yml` is what lets the account claim the repository
  if someone else added it first.) For the Verified Publisher badge, put the repository
  ID it shows into `repositoryID` in that file and merge it: every publish pushes the
  file as `ghcr.io/decdn/charts/decdn-node:artifacthub.io`, so a later publish without
  the ID would drop it. Artifact Hub re-reads the file only when a new chart version
  appears, so the badge comes with the next release. To have it with the first one,
  push the file by hand right after adding the repository, before Artifact Hub first
  processes it, with a token that has `write:packages` (`gh auth refresh -s
  write:packages` adds it to gh's):

  ```bash
  gh auth token | oras login ghcr.io --username "$(gh api user --jq .login)" --password-stdin
  cd charts/decdn-node && oras push ghcr.io/decdn/charts/decdn-node:artifacthub.io \
    --config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml \
    artifacthub-repo.yml:application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml
  ```

## When a publish fails half-way

In both workflows the GitHub Release is the last step, so it only appears once the
artifact is live. The two workflows share nothing at run time (each has its own
concurrency group), so a failure in the chart's release never affects a collection's,
or the other way round.

Re-run only the failed `publish` job, never the whole workflow: `publish` reuses the
artifact `build` checksummed, while a fresh `build` repackages the chart, which need
not reproduce the same bytes.

**Chart** (`release-chart.yml`: chart push and signature, then the Artifact Hub
metadata, then the Release). The pushes are repeatable: re-pushing the same package
moves the version tag to the same digest, and `oras push` moves the `artifacthub.io`
tag. The Release is not: if `gh release create` made the Release and then failed (an
asset upload, say), a re-run fails on the existing Release. Finish it by hand with
`gh release upload decdn-node-X.Y.Z --repo decdn/devops <missing assets>` from the
`release-decdn-node-X.Y.Z` workflow artifact.

**Collections** (`release-collection.yml`: Galaxy, then the Release). **Galaxy refuses a
version that already exists.** If the publish step failed before Galaxy accepted the
upload, fix the cause and re-run. If Galaxy did accept it, finish by hand from the
`release-<collection>-collection-vX.Y.Z` workflow artifact, with the same assets as the
workflow (`release-notes.md` in it is not an asset):

```bash
# decdn.node; --latest=false if a higher node-collection-v release already exists
gh release create node-collection-vX.Y.Z --repo decdn/devops --title "decdn.node collection X.Y.Z" \
  --latest=true --notes-file release-notes.md decdn-node-X.Y.Z.tar.gz SHA256SUMS
# decdn.publisher: never Latest
gh release create publisher-collection-vX.Y.Z --repo decdn/devops --title "decdn.publisher collection X.Y.Z" \
  --latest=false --notes-file release-notes.md decdn-publisher-X.Y.Z.tar.gz SHA256SUMS
```

**Never re-use a version** for different content. Cut the next patch version.

## Verifying a release

```bash
# The chart's signature: keyless, tied to this repo's chart release workflow and tags.
cosign verify ghcr.io/decdn/charts/decdn-node:X.Y.Z \
  --certificate-identity-regexp '^https://github\.com/decdn/devops/\.github/workflows/release-chart\.yml@refs/tags/decdn-node-[0-9]+\.[0-9]+\.[0-9]+$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# The files attached to the GitHub Release.
sha256sum --check SHA256SUMS
```
