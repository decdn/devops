# Releasing

A `vX.Y.Z` tag releases two artifacts at one version:

| Artifact | Published to | Install |
|----------|--------------|---------|
| `decdn.node` Ansible collection | [Ansible Galaxy](https://galaxy.ansible.com/ui/repo/published/decdn/node/) | `ansible-galaxy collection install decdn.node:==X.Y.Z` |
| `decdn-node` Helm chart | `oci://ghcr.io/decdn/charts`, signed with cosign (keyless) | `helm install <release> oci://ghcr.io/decdn/charts/decdn-node --version X.Y.Z` |

[`.github/workflows/release.yml`](.github/workflows/release.yml) does the work. Its
`build` job runs on every matching tag push. It gates the tag, re-runs
`make galaxy-check` and `make lint-helm`, packages both, and uploads them with a
`SHA256SUMS` as a workflow artifact. The `publish` job pushes to Galaxy and ghcr.io and
creates the GitHub Release, but **only** when the repository variable
`PUBLISH_ENABLED` is `true`. Until then, a tag push is a dry run. So is a manual
*Run workflow* (`workflow_dispatch`) with a tag, which is the way to rehearse.

## Cutting a release

1. **Versions.** Set the same `X.Y.Z` in `ansible/galaxy/galaxy.yml` (`version:`) and
   `charts/decdn-node/Chart.yaml` (`version:`). Bump the chart's `appVersion` (and the
   image tag in its `artifacthub.io/images` annotation) if it now targets a newer decdn
   release.
2. **Changelogs.** Both `ansible/galaxy/CHANGELOG.md` and `charts/decdn-node/CHANGELOG.md`
   collect changes under `## [Unreleased]`. At release time, move those entries under a
   dated `## [X.Y.Z] — YYYY-MM-DD` heading and leave an empty `[Unreleased]` above it.
   **First release only:** both files already hold a `## [0.1.0] — unreleased` section
   describing the initial state; fold `[Unreleased]` into it and replace "unreleased"
   with the date. The gate rejects a missing section and one still marked
   "unreleased". These two sections become the GitHub Release notes. The chart's
   section also becomes the packaged chart's `artifacthub.io/changes` annotation
   (`scripts/chart-artifacthub-changes.py`), so its `###` headings must be Keep a
   Changelog kinds (Added, Changed, Deprecated, Removed, Fixed, Security) and every
   change a bulleted entry; `make test-scripts` checks the section parses.
3. **Check locally:** `scripts/check-release-version.sh vX.Y.Z`, then
   `make -C ansible galaxy-check` and `make lint-helm`.
4. **Merge** that as a PR, then tag the merge commit on `main` and push the tag:

   ```bash
   git tag -s vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z
   ```

5. **Watch** the Release workflow. With publishing enabled, the `publish` job waits for
   approval on the `release` environment.

## First release only

Before the first publish:

- **Galaxy namespace.** The `decdn` namespace must exist on galaxy.ansible.com and the
  account behind `GALAXY_API_KEY` must be allowed to publish to it. Add the key as the
  repository secret `GALAXY_API_KEY`.
- **`release` environment.** Create it under *Settings → Environments* with required
  reviewers, and put `GALAXY_API_KEY` there rather than as a repository secret if you
  want the reviewer gate to guard it too.
- **Enable:** set the repository variable `PUBLISH_ENABLED` to `true`, then cut the
  release as above.

After the first publish (the package does not exist before it):

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

The steps run chart (with its Artifact Hub metadata), then Galaxy, then the GitHub
Release. The Release is last, so it only appears once both artifacts are live.

- **Chart push failed:** nothing is public yet. Fix the cause and re-run the job.
- **Artifact Hub metadata push failed:** the chart is live. Fix the cause and re-run;
  both pushes are repeatable.
- **Galaxy publish failed after the chart was pushed:** fix the cause and re-run. The
  chart push is repeatable for the same version (the tag just moves to an identical
  digest), but **Galaxy refuses a version that already exists**. If Galaxy actually
  accepted the upload before the job failed, finish by hand from the `release-vX.Y.Z`
  workflow artifact, with the same assets as the workflow (`release-notes.md` and
  `artifacthub-repo.yml` in it are not assets): `gh release create vX.Y.Z --title vX.Y.Z
  --notes-file release-notes.md decdn-node-*.tar.gz decdn-node-*.tgz SHA256SUMS`.
- **Never re-use a version** for different content. Cut `vX.Y.Z+1`.

## Verifying a release

```bash
# The chart's signature: keyless, tied to this repo's release workflow.
cosign verify ghcr.io/decdn/charts/decdn-node:X.Y.Z \
  --certificate-identity-regexp '^https://github.com/decdn/devops/.github/workflows/release.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# The files attached to the GitHub Release.
sha256sum --check SHA256SUMS
```
