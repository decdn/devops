#!/usr/bin/env bash
# Opens the PR that moves the decdn/decdn pin to a decdn release
# (ansible/roles/decdn_node/README.md, "Bumping the decdn release").
#
# Usage:  scripts/open-decdn-bump.sh [--dry-run] [vX.Y.Z]
#
# With no tag it takes decdn's latest published release. decdn's
# publish-crates.sh runs it with the tag it just published; a maintainer runs it
# by hand from a clone whose `origin` is decdn/devops, with push access.
#
# It works in a detached worktree at origin/main, so the working copy and its
# branch stay as they are. It commits as your git identity, pushes with your
# `origin` credentials and opens the PR with your `gh` login: a PR opened that
# way runs CI, which one opened by Actions' GITHUB_TOKEN would not.
#
# The bump does checklist steps 1 to 7 (bump_decdn.py rewrite moves every pin,
# the commented examples and AGENTS.md's pinned version; CI's helm job validates
# the chart against the new release's binary). The roles and the chart pin a
# release line, so a release in that line (a patch) moves only what names one
# exact release: Compose, the examples and the generated mirrors, a repo-only
# change. A release that starts a new line moves the line as well, and the
# collections and the chart need a release after it.
# Release facts (the SHA256SUMS digest, the decdn-node image digest) come from
# the release's assets once their signatures verify against the vendored
# decdn-release-KEYS.asc; the generated mirrors and KEYS come from a clone of the
# tag, whose signature is checked the same way. What needs a human is listed in
# the PR body: a schema-key change (node.toml.j2 and the chart's values.config
# follow it by hand), a KEYS change (the sponsord copy and SECURITY.md follow
# it), and any generator that failed.
#
# Nothing happens when the pin is already at that release or a later one, or
# when a PR from bump/decdn-<tag> exists in any state: a closed bump PR is never
# reopened, so close one to skip that release.
#
# --dry-run  make the change in the worktree, print its diff and the PR body,
#            and stop before the commit
#
# Exit: 0 done or nothing to do; 1 error (no PR opened unless the output says
# so), the PR is open but needs work, or (--dry-run) the bump would need work;
# 2 usage. "Needs work" is the body's "Needs work" list: what the script could
# not finish. A PR with no "Needs work" list and a green CI needs no hand edits.
set -euo pipefail

DECDN=decdn/decdn
DEVOPS=decdn/devops
# bump_decdn.py comes from beside this script, so it matches it. The generators
# run from the worktree: sync-network-profiles.py writes relative to its own
# location.
SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KEYS=ansible/roles/decdn_node/files/decdn-release-KEYS.asc
SCHEMA_KEYS=ansible/molecule/schema/files/schema-keys.txt

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '5p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2; exit 2; }

DRY_RUN="" TAG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
    v*) [[ -z "$TAG" ]] || usage; TAG="$arg" ;;
    *) usage ;;
  esac
done

# ---- preconditions -------------------------------------------------------

for tool in git gh python3 gpg sha256sum; do
  command -v "$tool" >/dev/null || die "$tool not found on PATH"
done
# Only the account gh will use: a stale login elsewhere must not block this.
gh auth status --hostname github.com --active >/dev/null ||
  die "\`gh auth status\` failed (see above); run \`gh auth login\`"

REPO_ROOT=$(git rev-parse --show-toplevel) || die "not inside a git repository"
origin=$(git -C "$REPO_ROOT" remote get-url origin) || die "no \`origin\` remote"
# The PR goes to $DEVOPS, so the branch must too: a fork's origin would push
# somewhere `gh pr create` cannot see.
[[ "$origin" =~ [/:]${DEVOPS}(\.git)?/?$ ]] ||
  die "origin is $origin, not $DEVOPS; run this from a $DEVOPS checkout"

if [[ -z "$TAG" ]]; then
  # `gh release view` with no tag is the latest release: never a draft or a
  # pre-release.
  TAG=$(gh release view -R "$DECDN" --json tagName --jq .tagName) ||
    die "could not read $DECDN's latest release"
fi
# vX.Y.Z only, as the upstream-drift job reads tags: the pins have no
# pre-release form.
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$TAG is not a decdn release tag (vX.Y.Z)"
state=$(gh release view "$TAG" -R "$DECDN" --json isDraft,isPrerelease \
  --jq 'if .isDraft then "draft" elif .isPrerelease then "prerelease" else "published" end') ||
  die "could not read $DECDN release $TAG"
[[ "$state" == published ]] || die "$DECDN $TAG is a $state, not a published release"
VERSION=${TAG#v}

# ---- worktree at origin/main ---------------------------------------------

git -C "$REPO_ROOT" fetch --quiet origin main || die "could not fetch origin main"

WORK=$(mktemp -d)
WORKTREE="$WORK/devops"
cleanup() {
  local err
  # Removed through git, so the parent repository keeps no stale entry. -d: the
  # worktree may not exist yet.
  if [[ -d "$WORKTREE" ]]; then
    err=$(git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" 2>&1) || {
      echo "warning: could not remove the worktree at $WORKTREE: $err" >&2
      echo "         run \`git -C $REPO_ROOT worktree prune\` to clear the stale entry" >&2
    }
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKTREE" origin/main ||
  die "could not create a worktree at origin/main"
cd "$WORKTREE"
bump() { python3 "$SCRIPTS/bump_decdn.py" --root "$WORKTREE" "$@"; }

# ---- which release -------------------------------------------------------

LINE=$(bump pinned) || die "could not read the decdn release line on origin/main"
# The release the exact copies (Compose, the examples, the mirrors) name.
CURRENT=$(bump synced) || die "could not read the decdn release devops main is synced to"
# Never move the pin backwards: not to a patch release on an older line, nor
# to an older tag given by hand.
relation=$(bump compare "$TAG") || die "could not compare the pin with $TAG"
case "$relation" in
  same)
    echo "devops main is already synced to decdn $TAG; nothing to do"
    exit 0 ;;
  ahead)
    echo "devops main is synced to decdn v$CURRENT, later than $TAG; nothing to do"
    exit 0 ;;
  behind) ;;
  *) die "unexpected comparison of the pin with $TAG: $relation" ;;
esac
KIND=$(bump kind "$TAG") || die "could not tell whether $TAG is in the line $LINE"

BRANCH="bump/decdn-${TAG}"
existing=$(gh pr list -R "$DEVOPS" --head "$BRANCH" --state all \
  --json url,state --jq '.[0] | select(.) | "\(.url) (\(.state | ascii_downcase))"') ||
  die "could not list $DEVOPS PRs"
if [[ -n "$existing" ]]; then
  echo "a PR for the bump to $TAG exists: $existing; nothing to do"
  exit 0
fi

# ---- the release's facts, verified ---------------------------------------

echo "==> Verifying $DECDN $TAG against the vendored KEYS"
GNUPG="$WORK/gnupg"
mkdir -m 700 "$GNUPG"
gpg --homedir "$GNUPG" --batch --quiet --import "$KEYS" 2>/dev/null ||
  die "$KEYS is not a valid OpenPGP keyring"
ASSETS="$WORK/assets"
gh release download "$TAG" -R "$DECDN" -D "$ASSETS" \
  -p SHA256SUMS -p SHA256SUMS.asc \
  -p decdn-node-image-digest.txt -p decdn-node-image-digest.txt.asc ||
  die "could not download $TAG's SHA256SUMS and decdn-node-image-digest.txt (and their .asc)"
# A signature by a key the vendored KEYS does not hold fails here, including
# upstream's next key after a rotation: vendor the new KEYS by hand (README step
# 6) and run this again.
for f in SHA256SUMS decdn-node-image-digest.txt; do
  gpg --homedir "$GNUPG" --batch --verify "$ASSETS/$f.asc" "$ASSETS/$f" 2>"$WORK/gpg.log" || {
    cat "$WORK/gpg.log" >&2
    die "$TAG's $f does not verify against $KEYS"
  }
done
# A signature says a maintainer signed the file, not for which release: neither
# file is versioned by its name. SHA256SUMS lists archives named for the
# version, and the digest file is one line naming the decdn-node image, so a
# signed file copied from another release, or the CLI image's digest file,
# stops here.
grep -qE "^[0-9a-f]{64}  decdn-node-${VERSION//./\\.}-" "$ASSETS/SHA256SUMS" ||
  die "$TAG's SHA256SUMS lists no decdn-node-$VERSION archive"
SUMS=$(sha256sum "$ASSETS/SHA256SUMS" | cut -d' ' -f1)
line=$(<"$ASSETS/decdn-node-image-digest.txt")
[[ "$line" =~ ^ghcr\.io/decdn/decdn-node@(sha256:[0-9a-f]{64})$ ]] ||
  die "$TAG's decdn-node-image-digest.txt is not one ghcr.io/decdn/decdn-node@sha256:<digest> line"
DIGEST=${BASH_REMATCH[1]}

UPSTREAM="$WORK/decdn"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" \
  "https://github.com/${DECDN}.git" "$UPSTREAM" || die "could not clone $DECDN at $TAG"
GNUPGHOME="$GNUPG" git -C "$UPSTREAM" verify-tag "$TAG" 2>"$WORK/gpg.log" || {
  cat "$WORK/gpg.log" >&2
  die "$DECDN tag $TAG is not signed by a key in $KEYS"
}
UPSTREAM_SHA=$(git -C "$UPSTREAM" rev-parse HEAD)
[[ -f "$UPSTREAM/KEYS" ]] || die "$DECDN $TAG has no KEYS file; no PR opened"

# ---- bump ----------------------------------------------------------------

echo "==> Moving decdn to $TAG (from v$CURRENT; $KIND bump, line $LINE)"
# What a human must finish; the PR still opens, and the exit code says so.
NEEDS=()
indent() { sed 's/^/  /'; }
# need <text> [<output> [<lang>]]: a PR-body bullet, <output> as a code block under it.
need() {
  local item="$1"
  [[ -z "${2:-}" ]] || item+=$'\n\n  ```'"${3:-}"$'\n'"$(indent <<<"$2")"$'\n  ```'
  NEEDS+=("$item")
}

bump rewrite "$VERSION" --sums-sha256 "$SUMS" --image-digest "$DIGEST" >/dev/null ||
  die "could not move the pins to $TAG; no PR opened"

# Step 2: the generated mirrors, from the tag. --check first: each mirror records the
# upstream commit it came from, which moves on every tag, so only the generator can
# tell whether the contract addresses themselves changed.
MIRRORS_MOVED=""
python3 scripts/sync-network-profiles.py "$UPSTREAM" --ref HEAD --check >/dev/null 2>&1 || MIRRORS_MOVED=1
if ! out=$(python3 scripts/sync-network-profiles.py "$UPSTREAM" --ref HEAD 2>&1); then
  need "\`scripts/sync-network-profiles.py\` failed against $TAG: the role and its
  template need the change upstream made." "$out"
fi
if out=$(python3 ansible/molecule/schema/files/gen-schema-keys.py "$UPSTREAM" 2>&1 >"$WORK/schema-keys.txt"); then
  if ! cmp -s "$WORK/schema-keys.txt" "$SCHEMA_KEYS"; then
    rc=0
    keydiff=$(diff -u "$SCHEMA_KEYS" "$WORK/schema-keys.txt") || rc=$?
    ((rc == 1)) || die "could not diff the schema keys (diff exited $rc); no PR opened"
    keydiff=$(sed -n '/^[-+][^-+]/p' <<<"$keydiff")
    cp "$WORK/schema-keys.txt" "$SCHEMA_KEYS"
    need "The config schema keys changed: re-sync
  \`ansible/roles/decdn_node/templates/node.toml.j2\` and the chart's \`values.config\`." \
      "$keydiff" diff
  fi
else
  need "\`gen-schema-keys.py\` failed against $TAG." "$out"
fi

# Within a line the deployed roles keep the mirrors they were released with, so
# a patch that changes them is not repo-only.
if [[ "$KIND" == patch ]] && { [[ -n "$MIRRORS_MOVED" ]] || ! git diff --quiet -- "$SCHEMA_KEYS"; }; then
  need "$TAG changes the generated mirrors within the line $LINE: the released
  collections still carry the old ones, so release \`decdn.node\` and
  \`decdn.publisher\` after merging (RELEASING.md)."
fi

# Step 6: KEYS is a byte copy of upstream's.
if ! cmp -s "$UPSTREAM/KEYS" "$KEYS"; then
  cp "$UPSTREAM/KEYS" "$KEYS"
  cp "$UPSTREAM/KEYS" ansible/roles/sponsord_onramp/files/decdn-release-KEYS.asc
  need "decdn's \`KEYS\` changed and is copied to \`$KEYS\` and the onramp's
  \`ansible/roles/sponsord_onramp/files/decdn-release-KEYS.asc\`: update the sponsord copy
  (\`ansible/roles/sponsord/files/sponsord-release-KEYS.asc\`) and SECURITY.md's fingerprints."
fi

# ---- PR body -------------------------------------------------------------

others=$(gh pr list -R "$DEVOPS" --state open --json number,headRefName \
  --jq "[.[] | select(.headRefName | startswith(\"bump/decdn-\")) | select(.headRefName != \"${BRANCH}\") | \"#\\(.number)\"] | join(\", \")") ||
  others=""   # only a note in the body; not worth stopping the bump
BODY="$WORK/body.md"
{
  if [[ "$KIND" == patch ]]; then
    echo "Moves what names one decdn/decdn release to [${TAG}](https://github.com/${DECDN}/releases/tag/${TAG}) from \`v${CURRENT}\`:"
    echo "Compose's image digest and onramp installer pin, the chart's example digest, the exact-pin"
    echo "examples and the generated mirrors. The roles and the chart pin the line \`${LINE}\` and"
    echo "pick ${TAG} up on their own."
  else
    echo "Moves the decdn/decdn pin to the line \`${TAG%.*}\` and [${TAG}](https://github.com/${DECDN}/releases/tag/${TAG}), from \`${LINE}\` and \`v${CURRENT}\`."
  fi
  echo
  echo "- decdn changes: https://github.com/${DECDN}/compare/v${CURRENT}...${TAG}"
  echo "- \`SHA256SUMS\` (\`${SUMS}\`) and the \`decdn-node\` image digest (\`${DIGEST}\`)"
  echo "  come from the release's assets, verified against \`${KEYS}\`."
  echo
  if ((${#NEEDS[@]})); then
    echo "**Needs work:**"
    echo
    printf -- '- %s\n' "${NEEDS[@]}"
    echo
  fi
  if [[ "$KIND" == patch ]]; then
    echo "Repo-only: no collection or chart release is needed (unless *Needs work* says otherwise)."
  else
    echo "After merging, release each artifact the bump touched (RELEASING.md)."
  fi
  echo
  if [[ -n "$others" ]]; then
    echo "Older bump PRs still open: ${others}. This one supersedes them."
    echo
  fi
  echo "Opened by \`scripts/open-decdn-bump.sh\`. A red CI means the new decdn needs"
  echo "changes here: push them to this branch."
} > "$BODY"

if [[ -n "$DRY_RUN" ]]; then
  git --no-pager diff
  printf '\n---- PR body ----\n'
  cat "$BODY"
  printf -- '----\n\ndry run: would push %s and open "chore: pin decdn to %s"\n' "$BRANCH" "$TAG"
  ((${#NEEDS[@]} == 0))
  exit
fi
git --no-pager diff --stat

# ---- commit, push, PR ----------------------------------------------------

git add -u || die "git add failed; no PR opened"
# --no-verify: CI is the gate on this PR.
if [[ "$KIND" == patch ]]; then
  SUMMARY="Move what names one decdn/decdn release from v${CURRENT} to ${TAG}
(${UPSTREAM_SHA}): the Compose image digest and onramp installer pin, the
chart's example digest, the inventory and cloud-init exact-pin examples and the
generated mirrors. The roles and the chart pin the line ${LINE}."
else
  SUMMARY="Move the decdn/decdn pin from the line ${LINE} (v${CURRENT}) to ${TAG}
(${UPSTREAM_SHA}): the role default, the onramp's installer line, the chart's
appVersion and Artifact Hub image, AGENTS.md's pinned line, and what names one
release (Compose, the examples, the generated mirrors)."
fi
git commit --quiet --no-verify -F - <<EOF || die "git commit failed; no PR opened"
chore: pin decdn to ${TAG}

${SUMMARY} The PR body lists anything left.
EOF
# No local branch: the commit is pushed from the detached worktree. Forced,
# because the branch may be left over from a run that pushed it and opened no
# PR; a run stops above when a PR exists.
git push --quiet --force origin "HEAD:refs/heads/${BRANCH}" ||
  die "could not push $BRANCH; no PR opened"

url=$(gh pr create -R "$DEVOPS" --base main --head "$BRANCH" \
  --title "chore: pin decdn to ${TAG}" --body-file "$BODY") ||
  die "pushed $BRANCH but could not open the PR; run this again to retry"
echo "==> Opened $url"

if ((${#NEEDS[@]})); then
  echo "warning: the PR needs work; see its body" >&2
  exit 1
fi
