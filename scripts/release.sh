#!/usr/bin/env bash
# Cut a release of one artifact on main: bump its version, write its changelog
# section, then make a signed release commit and a signed tag and push both. There
# is no release PR; the tag push runs the artifact's release workflow.
#
#   scripts/release.sh <node-collection|publisher-collection|chart>
#                      [auto|patch|minor|major|X.Y.Z]
#                      [--execute] [--no-verify] [--allow-unconventional]
#
#   node-collection       node-collection-vX.Y.Z       ansible/galaxy/node/{galaxy.yml,CHANGELOG.md}
#   publisher-collection  publisher-collection-vX.Y.Z  ansible/galaxy/publisher/{galaxy.yml,CHANGELOG.md}
#   chart                 decdn-node-X.Y.Z             charts/decdn-node/{Chart.yaml,CHANGELOG.md}
#
# Without --execute it is a dry run: it prints the new tag and the diff it would
# commit, and changes no file. The level defaults to `auto`, the bump git-cliff
# derives (cliff.toml) from the conventional commits since the artifact's last tag
# that touched what it ships: the roles in its galaxy/<collection>/roles.txt, that
# overlay, galaxy/build.sh and LICENSE for a collection; the chart and
# monitoring/decdn-node/ for the chart.
# Before 1.0, a feature (or, from 0.1 on, a breaking change) bumps the minor and any
# other commit kept in the changelog bumps the patch. The section is git-cliff's
# rendering of those commits, under a `## [X.Y.Z] — YYYY-MM-DD` heading. A commit there
# that git-cliff cannot parse as a Conventional Commit would be dropped without a word,
# so the script has git-cliff list them (require_conventional) and refuses them unless
# --allow-unconventional.
#
# The first release (no tag yet, the manifest at the 0.0.0 placeholder) names its level
# and releases the changelog's hand-written `## [Unreleased]` section instead: without a
# previous tag, git-cliff would render the whole history. decdn.publisher depends on
# decdn.node, so its first release is refused until origin has a node-collection tag
# that satisfies the `decdn.node: ">=X.Y.Z"` its galaxy.yml declares.
#
# --execute runs scripts/check-release-version.sh on the result (and, for the chart,
# scripts/chart-artifacthub-changes.py), then the artifact's make target (make
# galaxy-check-<collection> or make lint-helm) unless --no-verify: a tag that fails its workflow
# burns the version. If any of that or the commit fails, both files are restored. Run
# it on an up-to-date, clean main, with git configured to sign (user.signingkey), and
# with a bypass of the main ruleset (its PR rule and its required status checks): the
# release commit goes straight to main.
set -euo pipefail

usage() {
  echo "usage: $0 <node-collection|publisher-collection|chart> [auto|patch|minor|major|X.Y.Z] [--execute] [--no-verify] [--allow-unconventional]" >&2
  exit 2
}
die() { echo "release: $*" >&2; exit 1; }

artifact="" level="" execute=0 verify=1 allow_unconventional=0
for arg in "$@"; do
  case "$arg" in
    --execute) execute=1 ;;
    --no-verify) verify=0 ;;
    --allow-unconventional) allow_unconventional=1 ;;
    -*) usage ;;
    *)
      if [[ -z "$artifact" ]]; then artifact="$arg"
      elif [[ -z "$level" ]]; then level="$arg"
      else usage
      fi ;;
  esac
done
level="${level:-auto}"
[[ "$level" =~ ^(auto|patch|minor|major|[0-9]+\.[0-9]+\.[0-9]+)$ ]] || usage

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
case "$artifact" in
  node-collection|publisher-collection)
    collection="${artifact%-collection}"
    overlay="ansible/galaxy/$collection"
    prefix="$artifact-v"
    manifest="$overlay/galaxy.yml"
    changelog="$overlay/CHANGELOG.md"
    workflow="release-collection.yml"
    check=(make -C ansible "galaxy-check-$collection")
    # What `galaxy/build.sh <collection>` ships: the roles in its roles.txt, its
    # overlay, and LICENSE; build.sh itself too. The role list is the one build.sh
    # reads, so a role added there is counted here too.
    [[ -f "$overlay/roles.txt" ]] || die "$overlay/roles.txt is missing"
    roles=()
    while IFS= read -r role; do roles+=("$role"); done < <(grep -vE '^[[:space:]]*(#|$)' "$overlay/roles.txt")
    ((${#roles[@]} > 0)) || die "$overlay/roles.txt lists no role"
    paths=("$overlay/**" 'ansible/galaxy/build.sh' 'LICENSE')
    for role in "${roles[@]}"; do paths+=("ansible/roles/$role/**"); done
    ;;
  chart)
    prefix="decdn-node-"
    manifest="charts/decdn-node/Chart.yaml"
    changelog="charts/decdn-node/CHANGELOG.md"
    workflow="release-chart.yml"
    check=(make lint-helm)
    # The chart packages monitoring/decdn-node/ through its files/monitoring symlink.
    paths=('charts/decdn-node/**' 'monitoring/decdn-node/**')
    ;;
  *) usage ;;
esac
[[ -f "$manifest" && -f "$changelog" ]] || die "$manifest or $changelog is missing"

tmp="$(mktemp -d)"
written=0 committed=0 pushed=0 reported=0
cleanup() {
  # Once --execute has written the two files, any failure before the release commit
  # exists puts them back. Nothing is restored before that: a refusal never touches
  # the operator's own edits.
  if ((written == 1 && committed == 0)); then
    git checkout -q -- "$manifest" "$changelog" \
      || echo "release: could not restore $manifest and $changelog: run git checkout -- $manifest $changelog" >&2
  fi
  # Stopped (Ctrl-C, say) between the release commit and the end of the push.
  if ((committed == 1 && pushed == 0 && reported == 0)); then
    echo "release: stopped after the release commit, before the push finished. Check what origin has:" >&2
    echo "  git ls-remote origin refs/heads/main refs/tags/$tag" >&2
    echo "then, if it has neither, undo locally: git tag -d $tag; git reset --hard origin/main" >&2
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- preflight ---------------------------------------------------------------------
branch="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "$branch" == "main" ]] || die "releases are cut on main, not '${branch:-a detached HEAD}'"
status="$(git status --porcelain)" || die "git status failed"
[[ -z "$status" ]] || die "the working tree is not clean (git status)"
git fetch --quiet --tags origin main || die "git fetch origin failed"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
  || die "main is not origin/main: pull or push first"
if ((execute == 1)); then
  [[ -n "$(git config user.signingkey || true)" ]] \
    || die "git has no user.signingkey: the release commit and tag are signed"
  # Sign a throwaway commit object now, not after the checks: an unusable key would
  # otherwise fail only at the release commit.
  git commit-tree -S -p HEAD -m "release.sh signing check" "HEAD^{tree}" >/dev/null 2>"$tmp/sign.err" \
    || { cat "$tmp/sign.err" >&2; die "git cannot sign with user.signingkey"; }
fi

ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }
tag_re="^${prefix}[0-9]+\.[0-9]+\.[0-9]+$"
# <tag names on stdin>: the highest X.Y.Z among this artifact's tags, or nothing.
highest() { { grep -E "$tag_re" || (($? == 1)); } | sed "s/^$prefix//" | sort -V | tail -n1; }
# The last release is origin's highest tag. A different local one (a tag left by a
# failed push, say) would move git-cliff's boundary, so it is refused.
remote_tags="$(git ls-remote --tags --refs origin "refs/tags/${prefix}*")" || die "git ls-remote origin failed"
remote_tags="$(awk '{sub(/^refs\/tags\//, "", $2); print $2}' <<<"$remote_tags")"
local_tags="$(git tag --list "${prefix}*")" || die "git tag failed"
prev="$(highest <<<"$remote_tags")"
local_prev="$(highest <<<"$local_tags")"
[[ "$local_prev" == "$prev" ]] \
  || die "the highest local tag, $prefix${local_prev:-?}, is not origin's (${prev:+$prefix}${prev:-none}): delete it with git tag -d"
current="$(sed -nE 's/^version:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/p' "$manifest" | head -n1)"
[[ -n "$current" ]] || die "$manifest has no top-level version: line"
today="$(date -u +%F)"

# --- version and section -----------------------------------------------------------
if [[ -z "$prev" ]]; then
  # First release: the hand-written [Unreleased] section becomes the release's.
  [[ "$current" == "0.0.0" ]] || die "no ${prefix}X.Y.Z tag yet, but $manifest is $current, not the 0.0.0 placeholder"
  if [[ "$artifact" == "publisher-collection" ]]; then
    need="$(sed -nE 's/^[[:space:]]+decdn\.node:[[:space:]]*">=([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$manifest")"
    [[ -n "$need" ]] || die "$manifest declares no decdn.node: \">=X.Y.Z\" dependency"
    node_tags="$(git ls-remote --tags --refs origin 'refs/tags/node-collection-v*')" || die "git ls-remote origin failed"
    node_prev="$(awk '{sub(/^refs\/tags\//, "", $2); print $2}' <<<"$node_tags" \
      | { grep -E '^node-collection-v[0-9]+\.[0-9]+\.[0-9]+$' || (($? == 1)); } | sed 's/^node-collection-v//' | sort -V | tail -n1)"
    if [[ -z "$node_prev" ]] || ver_gt "$need" "$node_prev"; then
      die "decdn.publisher needs decdn.node >=$need, and origin's highest node-collection tag is ${node_prev:-none}: release node-collection first"
    fi
  fi
  case "$level" in
    auto) die "the first release names its level: minor for 0.1.0" ;;
    patch) version="0.0.1" ;;
    minor) version="0.1.0" ;;
    major) version="1.0.0" ;;
    *) version="$level" ;;
  esac
  ver_gt "$version" "0.0.0" || die "$version is not above 0.0.0"
  grep -qx '## \[Unreleased\]' "$changelog" \
    || die "$changelog has no '## [Unreleased]' section for the first release"
  awk -v h="## [$version] — $today" '$0 == "## [Unreleased]" {print h; next} {print}' \
    "$changelog" > "$tmp/changelog"
  awk -v h="## [$version] — $today" '
    $0 == h {on=1; next}
    on && (/^## \[/ || /^<!--/ || /^\[[^]]+\]: /) {exit}
    on' "$tmp/changelog" > "$tmp/section"
  grep -q '^- ' "$tmp/section" || die "$changelog: the [Unreleased] section has no '- ' entries"
else
  command -v git-cliff >/dev/null || die "git-cliff is not installed (cargo install git-cliff)"
  cliff_version="$(git-cliff --version)" || die "git-cliff --version failed"
  cliff_version="$(awk '{print $2}' <<<"$cliff_version")"
  # 2.9 added require_conventional, which the unconventional-commit refusal below needs.
  ver_gt "2.9.0" "$cliff_version" && die "git-cliff 2.9 or later is required, not ${cliff_version:-unknown}"
  [[ "$current" == "$prev" ]] \
    || die "$manifest is $current, but the last tag is $prefix$prev: fix the manifest first"
  if grep -q '^## \[Unreleased\]' "$changelog"; then
    die "$changelog has an [Unreleased] section: sections are generated since the first release, so turn its entries into commit subjects or drop it"
  fi

  include=()
  for p in "${paths[@]}"; do include+=(--include-path "$p"); done
  # Every run is --unreleased: the commits since the last tag. (git-cliff's
  # require_conventional would otherwise judge the whole history.)
  cliff() {
    git-cliff --config "$repo/cliff.toml" --tag-pattern "$tag_re" "${include[@]}" --unreleased "$@" 2>"$tmp/cliff.err" \
      || { cat "$tmp/cliff.err" >&2; die "git-cliff failed"; }
  }
  # git-cliff drops a commit it cannot parse as a Conventional Commit (cliff.toml,
  # filter_unconventional) and only says so in a log line, so the bump and the section
  # would leave it out unseen: an empty scope, say, or a body right under the subject.
  # With require_conventional it fails instead, naming each one.
  if ! GIT_CLIFF__GIT__REQUIRE_CONVENTIONAL=true git-cliff --config "$repo/cliff.toml" --tag-pattern "$tag_re" \
      "${include[@]}" --unreleased --bumped-version >/dev/null 2>"$tmp/cliff.err"; then
    esc="$(printf '\033')"
    sed "s/$esc\[[0-9;]*m//g" "$tmp/cliff.err" > "$tmp/cliff.plain" # git-cliff colours its log even off a tty
    grep -q 'UnconventionalCommitsError' "$tmp/cliff.plain" || { cat "$tmp/cliff.err" >&2; die "git-cliff failed"; }
    echo "release: git-cliff cannot parse these commits that touched the $artifact as Conventional Commits, so its changelog and bump leave them out:" >&2
    # "Commit <hash> is not conventional:", then the message, one "| " line per line.
    awk '/Commit [0-9a-f]+ is not conventional:/ {match($0, /Commit [0-9a-f]+/); h=substr($0, RSTART+7, RLENGTH-7); next}
         h != "" && sub(/^[[:space:]]*\| /, "") {print "  " h " " $0; h=""}' "$tmp/cliff.plain" >&2
    ((allow_unconventional == 1)) || die "refusing; re-run with --allow-unconventional to release without them"
  fi
  case "$level" in
    auto) bumped="$(cliff --bumped-version)" ;;
    patch|minor|major) bumped="$(cliff --bump "$level" --bumped-version)" ;;
    *) bumped="$prefix$level" ;;
  esac
  [[ "$bumped" =~ $tag_re ]] || die "git-cliff proposed '$bumped', not a ${prefix}X.Y.Z tag"
  version="${bumped#"$prefix"}"
  # Squeeze git-cliff's blank lines and trim the ends.
  cliff --strip all | cat -s | sed '/./,$!d' | sed '${/^$/d;}' > "$tmp/section"
  # Every heading must be a Keep a Changelog kind: the chart's section becomes
  # artifacthub.io/changes, and chart-artifacthub-changes.py refuses anything else.
  bad="$(grep '^### ' "$tmp/section" | grep -vxE '### (Added|Changed|Deprecated|Removed|Fixed|Security)' || true)"
  [[ -z "$bad" ]] || die "git-cliff rendered a heading that is not a Keep a Changelog kind: $bad (fix cliff.toml's commit_parsers)"
  if [[ "$level" == [0-9]* ]]; then
    ver_gt "$version" "$prev" || die "$version is not above the last release, $prev"
  fi
  if [[ "$version" == "$prev" ]] || ! grep -q '^- ' "$tmp/section"; then
    die "nothing to release: no commit since $prefix$prev that touched ${paths[*]} makes a changelog entry (ci, test, style, build and release commits do not, nor, with --allow-unconventional, unconventional ones)"
  fi
  ver_gt "$version" "$prev" || die "$version is not above the last release, $prev"
  awk -v h="## [$version] — $today" -v s="$tmp/section" '
    !done && /^## \[/ {
      print h; print ""
      while ((getline l < s) > 0) print l
      print ""; done=1
    }
    {print}
    END {
      if (!done) {
        print ""; print h; print ""
        while ((getline l < s) > 0) print l
      }
    }' "$changelog" > "$tmp/changelog"
fi
tag="$prefix$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"
! grep -qx "$tag" <<<"$remote_tags" || die "tag $tag already exists on origin"

awk -v v="$version" '
  !done && /^version:/ { sub(/^version:[[:space:]]*"?[^"#[:space:]]+"?/, "version: " v); done=1 }
  {print}' "$manifest" > "$tmp/manifest"
rc=0
cmp -s "$manifest" "$tmp/manifest" || rc=$?
((rc == 1)) || die "could not set the version in $manifest"

show_diff() { # <file> <new copy>
  local rc=0
  diff -u --label "a/$1" --label "b/$1" "$1" "$2" || rc=$?
  ((rc <= 1)) || die "diff failed on $1"
}
echo "release $artifact: ${prev:+$prefix$prev -> }$tag"
echo
show_diff "$manifest" "$tmp/manifest"
show_diff "$changelog" "$tmp/changelog"
echo
# Until PUBLISH_ENABLED is true, a tag push only builds (RELEASING.md), but the version
# is used up all the same: say so before it is.
publish=""
command -v gh >/dev/null && publish="$(GH_PROMPT_DISABLED=1 gh variable get PUBLISH_ENABLED 2>/dev/null || true)"
if [[ "$publish" != "true" ]]; then
  echo "note: PUBLISH_ENABLED is not true (or gh cannot read it), so the $tag push builds it and publishes nothing"
  echo
fi

if ((execute == 0)); then
  echo "dry run: no file changed. --execute would run:"
  echo "  scripts/check-release-version.sh $tag"
  [[ "$artifact" == "chart" ]] && echo "  scripts/chart-artifacthub-changes.py $changelog $version"
  ((verify == 1)) && echo "  ${check[*]}"
  echo "  git commit -S -m 'chore(release): $tag' -- $manifest $changelog"
  echo "  git tag -s $tag -m $tag"
  echo "  git push --atomic origin main $tag"
  exit 0
fi

# --- execute -----------------------------------------------------------------------
written=1
cp "$tmp/manifest" "$manifest"
cp "$tmp/changelog" "$changelog"
scripts/check-release-version.sh "$tag" || die "the release gate refused $tag: nothing was committed"
if [[ "$artifact" == "chart" ]]; then
  scripts/chart-artifacthub-changes.py "$changelog" "$version" >/dev/null \
    || die "chart-artifacthub-changes.py refused the section: nothing was committed"
fi
if ((verify == 1)); then
  "${check[@]}" || die "${check[*]} failed: nothing was committed"
fi

git commit --quiet -S -m "chore(release): $tag" -- "$manifest" "$changelog" \
  || die "git commit failed (a pre-commit hook, or signing): nothing was committed"
committed=1
git tag -s "$tag" -m "$tag" || { reported=1; die "tagging failed after the release commit. To undo: git reset --hard origin/main"; }
if ! git push --atomic origin "HEAD:refs/heads/main" "refs/tags/$tag"; then
  # --atomic makes a rejected push all-or-nothing, but a dropped connection can leave
  # it unknown: look before suggesting an undo.
  if seen="$(git ls-remote origin refs/heads/main "refs/tags/$tag")" \
     && ! grep -q "refs/tags/$tag$" <<<"$seen" \
     && ! grep -q "^$(git rev-parse HEAD)[[:space:]]refs/heads/main$" <<<"$seen"; then
    echo "release: the push failed; nothing reached origin. To undo locally:" >&2
    echo "  git tag -d $tag && git reset --hard origin/main" >&2
  else
    echo "release: the push failed, and origin may have the release commit or $tag:" >&2
    echo "  check git ls-remote origin before undoing anything" >&2
  fi
  reported=1
  exit 1
fi
pushed=1
if [[ "$publish" == "true" ]]; then
  echo "released $tag. Watch it: gh run list --workflow $workflow"
else
  echo "tagged $tag, but PUBLISH_ENABLED is not true: $workflow builds it and publishes nothing. Watch it: gh run list --workflow $workflow"
fi
