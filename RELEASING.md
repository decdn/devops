# Releasing

The repo publishes two artifacts, each on its own version and released by its own tag:

| Artifact | Tag | Workflow | Published to | Install |
|----------|-----|----------|--------------|---------|
| `decdn.node` Ansible collection | `collection-vX.Y.Z` | [`release-collection.yml`](.github/workflows/release-collection.yml) | [Ansible Galaxy](https://galaxy.ansible.com/ui/repo/published/decdn/node/) | `ansible-galaxy collection install decdn.node:==X.Y.Z` |
| `decdn-node` Helm chart | `decdn-node-X.Y.Z` | [`release-chart.yml`](.github/workflows/release-chart.yml) | `oci://ghcr.io/decdn/charts`, signed with cosign (keyless) | `helm install <release> oci://ghcr.io/decdn/charts/decdn-node --version X.Y.Z` |

Release an artifact when it has changes; the other one is not touched. The two do not
depend on each other, and what they must agree on is checked by CI, not by a shared
version: the decdn version (the chart's `appVersion` and the role's
`decdn_node_version`) on every PR (`make test-scripts`), and the config keys each one
renders against the same upstream schema-key inventory whenever either changes
(`make lint-helm`, `molecule/schema`). When a change lands in both (a decdn bump,
say), release both.

Each workflow's `build` job runs on every matching tag push. It gates the tag
(`scripts/check-release-version.sh`), re-runs that artifact's checks (`make galaxy-check`
or `make lint-helm`), packages it, and uploads it with a `SHA256SUMS` as a workflow
artifact. The `publish` job pushes it to Galaxy or ghcr.io and creates the GitHub
Release, but **only** when the repository variable `PUBLISH_ENABLED` is `true`. Until
then, a tag push is a dry run. So is a manual *Run workflow* (`workflow_dispatch`) with a
tag, which is the way to rehearse. The repo's *Latest* release follows the collection;
chart releases are created with `--latest=false`.

## Cutting a release

For the collection, everything below is under `ansible/galaxy/`; for the chart, under
`charts/decdn-node/`.

1. **Version.** Set `X.Y.Z` as `version:` in `galaxy.yml` (collection) or `Chart.yaml`
   (chart). The chart's `appVersion` and its `artifacthub.io/images` tag already follow
   the role's `decdn_node_version` (`make test-scripts` refuses a PR where they
   differ), so a decdn bump is a chart change too: log it in the chart's changelog and
   release the chart.
2. **Changelog.** `CHANGELOG.md` collects changes under `## [Unreleased]`. At release
   time, move those entries under a dated `## [X.Y.Z] — YYYY-MM-DD` heading and leave an
   empty `[Unreleased]` above it. **First release only:** each changelog already holds
   a `## [0.1.0] — unreleased` section describing the initial state; fold
   `[Unreleased]` into it and replace "unreleased" with the date. The gate rejects a
   missing section, one not dated `YYYY-MM-DD` (so one still marked "unreleased"), and
   one with no bulleted entries. The section becomes the GitHub Release notes. The
   chart's section also becomes the packaged chart's `artifacthub.io/changes`
   annotation (`scripts/chart-artifacthub-changes.py`), so its `###` headings must be
   Keep a Changelog kinds (Added, Changed, Deprecated, Removed, Fixed, Security) and
   every change a bulleted entry; `make test-scripts` checks the section parses.
3. **Check locally:** `scripts/check-release-version.sh collection-vX.Y.Z` then
   `make -C ansible galaxy-check`, or `scripts/check-release-version.sh decdn-node-X.Y.Z`
   then `make lint-helm`.
4. **Merge** that as a PR, then tag the merge commit on `main` with the artifact's tag
   and push it (both lines if you are releasing both):

   ```bash
   git tag -s collection-vX.Y.Z -m "collection-vX.Y.Z" && git push origin collection-vX.Y.Z
   git tag -s decdn-node-X.Y.Z -m "decdn-node-X.Y.Z" && git push origin decdn-node-X.Y.Z
   ```

5. **Watch** the *Release collection* or *Release chart* workflow. With publishing
   enabled, the `publish` job waits for approval on the `release` environment.

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
  releases as above. Both artifacts start at `0.1.0`, so the first two tags are
  `collection-v0.1.0` and `decdn-node-0.1.0`; their versions diverge from then on.

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
concurrency group), so a failure in one artifact's release never affects the other's.

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

**Collection** (`release-collection.yml`: Galaxy, then the Release). **Galaxy refuses a
version that already exists.** If the publish step failed before Galaxy accepted the
upload, fix the cause and re-run. If Galaxy did accept it, finish by hand from the
`release-collection-vX.Y.Z` workflow artifact, with the same assets as the workflow
(`release-notes.md` in it is not an asset):

```bash
gh release create collection-vX.Y.Z --repo decdn/devops --title "decdn.node collection X.Y.Z" \
  --notes-file release-notes.md decdn-node-X.Y.Z.tar.gz SHA256SUMS
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
