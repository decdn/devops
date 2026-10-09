# Run by bootstrap.sh on the output of
#   ansible-playbook playbooks/site.yml --tags baseline --list-hosts --list-tasks
# with -v groups="<the base groups localhost is in>" (decdn_nodes and/or sponsord_hosts).
#
# Phase 1 relies on `--tags baseline` hardening the host, which is true only if every
# play that targets one of those groups, and lists localhost, still selects a baseline
# task under that tag. --list-tasks lists every play, hostless ones included, so one
# grep over the whole output would be satisfied by another group's play (#90). This
# checks play by play, and names each group whose play would harden nothing.
#
# The output it reads, per play:
#   play #3 (sponsord_hosts): Provision sponsord	TAGS: []
#     pattern: ['sponsord_hosts']
#     hosts (1):
#       localhost
#     tasks:
#       baseline : Validate the admin accounts	TAGS: [baseline]
#
# Exit 0 when each group has such a play and every one of them selects a baseline task;
# 1 otherwise, with one line per group on stderr.

function end_play() {
  if (pattern != "" && has_localhost) {
    plays[pattern]++
    if (baseline == 0) bare[pattern]++
  }
  pattern = ""; has_localhost = 0; baseline = 0; section = ""
}

BEGIN { n = split(groups, want, " ") }

/^  play #[0-9]+ / { end_play(); next }
/^    pattern: \['[^']*'\]$/ {
  pattern = $0
  sub(/^    pattern: \['/, "", pattern)
  sub(/'\]$/, "", pattern)
  next
}
/^    hosts \([0-9]+\):$/ { section = "hosts"; next }
/^    tasks:$/ { section = "tasks"; next }
section == "hosts" && /^      localhost$/ { has_localhost = 1; next }
section == "tasks" && /^      baseline : / { baseline++; next }

END {
  end_play()
  bad = 0
  if (n == 0) {
    print "baseline-plays.awk: no groups given" > "/dev/stderr"
    exit 2
  }
  for (i = 1; i <= n; i++) {
    g = want[i]
    if (!(g in plays)) {
      print "no play targets " g " with localhost in it" > "/dev/stderr"
      bad = 1
    } else if (g in bare) {
      print "a play for " g " selects no baseline task under --tags baseline" > "/dev/stderr"
      bad = 1
    }
  }
  exit bad
}
