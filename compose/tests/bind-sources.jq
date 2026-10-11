# Whether Docker may create a missing bind source (create_host_path), checked by
# `make lint-compose` against compose.yaml AS WRITTEN (`yq -o=json`; no volume
# uses an anchor),
# not against `docker compose config`: Compose releases render this flag in
# opposite ways (v2.33 drops false and prints true, v5 prints false and drops
# true), and default an unset one differently too. So every bind mount sets it,
# and it is true only where a created, empty directory is harmless: the onramp's
# optional gate-page directory and the volatile journal (/run is a tmpfs that
# journald recreates). Anywhere else a mistyped path or an NFS mount that is not
# up must fail the start instead of mounting an empty directory, and
# /var/log/journal is never created (that would switch journald to persistent
# storage). A short-syntax volume always creates its source, so none is allowed.
# Prints one "<service>: <invariant>" line per violation.

def created_allowed: {
  "sponsord-onramp": ["/etc/sponsord/onramp-gate"],
  "alloy": ["/run/log/journal"]
};

.services | to_entries[] | .key as $n
| (.value.volumes // [])[]
| if type == "string" then
    "\($n): short-syntax volume \(.) (it always creates its source; write the long form)"
  elif .type == "bind" then
    .target as $t | (.bind.create_host_path) as $c
    | ((created_allowed[$n] // []) | index($t) != null) as $want
    | if ($c | type) != "boolean" then
        "\($n): bind mount \($t) sets create_host_path explicitly (Compose releases default it differently)"
      elif $c != $want then
        "\($n): create_host_path on \($t) is \($c), not its allow-list (\($want))"
      else empty end
  else empty end
