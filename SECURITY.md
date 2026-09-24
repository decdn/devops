# Security

## Reporting a vulnerability

Email `security@decdn.org`. Please do not open a public issue for security
reports. That includes a secret or real host address you find committed here.

## Scope

This repo holds the deployment tooling for a deCDN node: the Ansible roles, the
`decdn.node` Galaxy collection, the cloud-init user-data, the Docker Compose file, and the Helm chart. Reports about the node daemon or
protocol belong to [decdn/decdn](https://github.com/decdn/decdn), but the same address
reaches both.

The security model these tools follow is described in [README.md § Security
model](README.md#security-model): nothing secret committed, loopback-only backends,
default-deny inbound, DevSec host hardening.

## Release verification

In `release` install mode, and while `decdn_verify_release_signature` keeps its
default of `true`, the `decdn_node` role checks every downloaded tarball against the
release's GPG-signed `SHA256SUMS`, using the maintainer key
vendored at `ansible/roles/decdn_node/files/decdn-release-KEYS.asc`. That key is a
copy of upstream's `KEYS`:

```
Ant Somers <ant@decdn.org>
Fingerprint: DA75 1570 6F18 73D2 74D8  A369 9E11 A9FF D62D AADB
```

The same fingerprint is published in
[decdn/decdn's SECURITY.md](https://github.com/decdn/decdn/blob/main/SECURITY.md).
Check a new copy of the vendored key against it before trusting that copy, with
`gpg --show-keys --with-fingerprint <file>`.

Setting `decdn_verify_release_signature: false` (meant for an air-gapped mirror that
strips signatures) drops that guarantee, and the role prints a warning when it's off.
`manual` mode verifies nothing: it installs whatever binaries you point it at.

Published Helm charts (`oci://ghcr.io/decdn/charts/decdn-node`) are signed with a
keyless cosign signature from this repo's release workflow; see
[RELEASING.md § Verifying a release](RELEASING.md#verifying-a-release).
