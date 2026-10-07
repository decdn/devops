#!/usr/bin/env bash
# The molecule suite driver behind ansible/Makefile's `deps`, `molecule`,
# `molecule-serial` and `molecule-list` targets. Run from ansible/ (the Makefile does).
#
#   scripts/molecule.sh deps       install the Galaxy collections (safe beside a running suite)
#   scripts/molecule.sh parallel   run the selected scenarios, JOBS at a time
#   scripts/molecule.sh serial     run them one at a time, stopping at the first failure
#   scripts/molecule.sh list       print the selected scenarios as a JSON array (CI's matrix)
#
# Inputs, from the environment (the Makefile passes them through):
#   SCENARIOS             space-separated scenario names, or `all` (the default)
#   JOBS                  parallel width; empty means one slot per selected scenario
#   SLOW_FIRST            scenarios to start first, longest first; the rest follow by name
#   MOLECULE_LOCK_PREFIX  lock path prefix (default /tmp/decdn-devops-molecule)
#
# Fail loud (hard rule 4), because a harness that passes when it did not run is
# worse than a slow one:
#   - discovery refuses an empty or truncated scenario set. A glob that matches nothing
#     (wrong cwd, renamed layout) would otherwise run zero scenarios and exit 0.
#   - an empty, unknown or stale name (in SCENARIOS or SLOW_FIRST) is refused, not skipped.
#   - pipefail stops the [scenario] prefixing pipe from masking molecule's status, and
#     each scenario announces its own failure by name.
#   - every scenario failure is normalised to exit 1, which keeps xargs off its own
#     abort-on-255 path (that one stops launching queued scenarios). xargs then exits
#     123 when a scenario failed, 125 if one was killed, and every scenario still runs.
#
# Locking. Two runs of the SAME scenario are not isolated: its container names are
# fixed on the one Docker daemon (so this covers other checkouts and worktrees too),
# each run starts by destroying them, and molecule's ephemeral dir is keyed on the
# scenario, not the run. DIFFERENT scenarios share nothing they write, so each
# scenario has its own lock and agents can run disjoint sets side by side:
#   - <prefix>.<scenario>.lock — held (flock -n) for the scenario's whole run. A
#     preflight checks every selected one before anything starts, so a busy scenario
#     refuses the run with exit 75 and installs nothing.
#   - <prefix>.collections.lock — every run holds it SHARED, since every scenario reads
#     ansible/collections/. `deps` takes it EXCLUSIVE to rewrite the tree. When a run
#     holds it, deps proceeds only if the tree was installed from this exact
#     requirements.yml (the stamp below); a changed requirements.yml refuses instead
#     of rewriting collections under a running scenario.
# `flock -o` keeps each lock in flock itself, not in anything molecule leaves running.
#
# The locks are DIRECTORIES in /tmp, shared by every user of the host (users of one
# Docker daemon collide just the same). Not $XDG_RUNTIME_DIR, which is per user, and
# not regular files: with fs.protected_regular (Ubuntu/Debian default) another user
# cannot open(O_CREAT) a file someone else created in sticky /tmp, so the second user
# would fail even when nothing runs. Directories are exempt, and flock(1) falls back
# to a read-only open on one, so 0755 is enough.
set -euo pipefail
shopt -s nullglob

prefix="${MOLECULE_LOCK_PREFIX:-/tmp/decdn-devops-molecule}"
stamp=collections/.requirements.sha256
die() { echo "$*" >&2; exit 1; }

[[ -f requirements.yml && -d molecule ]] \
  || die "scripts/molecule.sh must run from ansible/ (cwd is $PWD)"

lock_dir() {
  test -e "$1" || mkdir -m 0755 "$1" 2>/dev/null || test -e "$1" \
    || die "cannot create the molecule lock directory $1"
}
need_flock() {
  command -v flock >/dev/null || die "molecule runs need util-linux's flock on PATH"
}

# --- deps ------------------------------------------------------------------------
# Plain `ansible-galaxy collection install` is a no-op when the tree already satisfies
# requirements.yml, but it rewrites the tree when the file changed, so it must not run
# under a scenario that is reading it.
install_collections() {
  ansible-galaxy collection install -r requirements.yml -p collections
  sha256sum requirements.yml | cut -d' ' -f1 >"$stamp"
}

deps() {
  # No flock (e.g. macOS running `make deploy`) means no molecule run either: they
  # need it. Install as before.
  if ! command -v flock >/dev/null; then install_collections; return; fi
  local lock="$prefix.collections.lock" rc=0 want
  lock_dir "$lock"
  flock -n -x -o -E 75 "$lock" "$0" _install || rc=$?
  [[ $rc -eq 75 ]] || return "$rc"
  want="$(sha256sum requirements.yml | cut -d' ' -f1)"
  [[ -f "$stamp" && "$(<"$stamp")" == "$want" ]] \
    || die "requirements.yml changed while another molecule run is using collections/ ($lock) — wait for it to finish, then re-run"
  echo "collections/ is in use by another molecule run and current for requirements.yml; not reinstalling"
}

# --- selection -------------------------------------------------------------------
discover() {
  local d name
  all=() dirs=()
  for d in molecule/*/; do
    name="$(basename "$d")"
    dirs+=("$name")
    [[ -f "molecule/$name/molecule.yml" ]] && all+=("$name")
  done
  [[ ${#all[@]} -gt 0 && "${all[*]}" == "${dirs[*]}" ]] || {
    echo "scenario discovery failed: molecule.yml in [${all[*]}] but scenario dirs are [${dirs[*]}]" >&2
    die "refusing to run a silently-truncated suite (this must run from ansible/)"
  }
  for name in "${all[@]}"; do
    # The names land in a JSON array and in lock paths unquoted by anything else.
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "scenario name '$name' is not [A-Za-z0-9._-]"
  done
}

is_scenario() {
  local s
  for s in "${all[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

select_scenarios() {
  local s requested=() rest=()
  for s in ${SLOW_FIRST:-}; do
    is_scenario "$s" || die "SLOW_FIRST names '$s', which is not a scenario under molecule/ (update ansible/Makefile)"
  done
  if [[ "${SCENARIOS-all}" == all ]]; then
    requested=("${all[@]}")
  else
    read -r -a requested <<<"${SCENARIOS:-}"
    [[ ${#requested[@]} -gt 0 ]] || die "SCENARIOS is empty: name scenarios, or leave it unset for all of them"
    for s in "${requested[@]}"; do
      is_scenario "$s" || die "unknown scenario '$s' (scenarios: ${all[*]})"
    done
  fi
  # Longest first: SLOW_FIRST order for the slow ones, then the rest by name. A slow
  # scenario queued last would otherwise set the wall clock on its own.
  selected=()
  for s in ${SLOW_FIRST:-}; do
    [[ " ${requested[*]} " == *" $s "* && " ${selected[*]} " != *" $s "* ]] && selected+=("$s")
  done
  for s in "${requested[@]}"; do
    [[ " ${selected[*]} ${rest[*]} " == *" $s "* ]] || rest+=("$s")
  done
  [[ ${#rest[@]} -eq 0 ]] || mapfile -t rest < <(printf '%s\n' "${rest[@]}" | LC_ALL=C sort)
  selected+=("${rest[@]}")
}

jobs_width() {
  local jobs="${JOBS:-${#selected[@]}}"
  case "$jobs" in
    ''|*[!0-9]*) die "JOBS must be a positive integer (got '$jobs')" ;;
  esac
  [[ "$((10#$jobs))" -gt 0 ]] || {
    echo "JOBS must be a positive integer (got '$jobs'): any all-zero value — 0, 00, 000 —" >&2
    die "reaches xargs as -P 0, which means UNLIMITED concurrency, not none"
  }
  echo "$((10#$jobs))"
}

# Refuse before deps, so a busy scenario costs nothing and touches nothing.
preflight() {
  local s lock
  for s in "${selected[@]}"; do
    lock="$prefix.$s.lock"
    lock_dir "$lock"
    flock -n "$lock" true || {
      echo "another molecule run holds scenario $s ($lock) — wait for it to finish (runs of one scenario share its containers)" >&2
      exit 75
    }
  done
}

# --- one scenario (xargs and the serial loop call this) ---------------------------
run_one() {
  local s="$1" lock="$prefix.$1.lock" rc=0
  flock -n -o -E 75 "$lock" molecule test -s "$s" --no-command-borders 2>&1 \
    | sed -u "s/^/[$s] /" || rc=$?
  [[ $rc -eq 0 ]] && return 0
  [[ $rc -eq 75 ]] && echo "[$s] another molecule run took scenario $s ($lock) after the preflight"
  echo "[$s] SCENARIO FAILED"
  exit 1
}

run_selected() {
  local how="$1" jobs="$2" s
  if [[ "$how" == parallel ]]; then
    printf '%s\n' "${selected[@]}" | xargs -P "$jobs" -I{} "$0" _one {}
  else
    for s in "${selected[@]}"; do "$0" _one "$s"; done
  fi
}

mode="${1:-}"
case "$mode" in
  deps) deps ;;
  list)
    discover; select_scenarios
    printf '['; sep=''
    for s in "${selected[@]}"; do printf '%s"%s"' "$sep" "$s"; sep=','; done
    printf ']\n'
    ;;
  parallel|serial)
    need_flock; discover; select_scenarios
    jobs="$(jobs_width)"
    preflight
    deps
    lock_dir "$prefix.collections.lock"
    echo "molecule ($mode${jobs:+, JOBS=$jobs}): ${selected[*]}"
    # Shared for the whole run; waits out a concurrent deps install rather than failing.
    flock -s -o -w 600 -E 75 "$prefix.collections.lock" \
      "$0" _run "$mode" "$jobs" "${selected[@]}" || {
      rc=$?
      [[ $rc -ne 75 ]] || echo "timed out waiting for $prefix.collections.lock (a deps install held it for 10 minutes)" >&2
      exit "$rc"
    }
    ;;
  # Internal entry points, re-entered under a lock that flock itself holds.
  _install) install_collections ;;
  _run) shift; how="$1" jobs="$2"; shift 2; selected=("$@"); run_selected "$how" "$jobs" ;;
  _one) run_one "$2" ;;
  *) echo "usage: $0 deps|parallel|serial|list" >&2; exit 2 ;;
esac
