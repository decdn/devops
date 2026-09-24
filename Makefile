# Convenience targets for the deCDN DevOps monorepo.
# Run from the repo root. Ansible-specific work is delegated to ansible/Makefile.
.PHONY: help hooks lint lint-ansible lint-helm lint-alloy lint-compose lint-cloud-init test-scripts security security-ansible security-helm security-compose molecule molecule-serial galaxy-build galaxy-check
SHELL := /bin/bash

# KICS runs straight from the engine image, pinned by digest. This target IS the
# CI security gate (.github/workflows/ci.yml calls it), so local and CI runs are
# byte-identical. Pinning by digest means a re-pointed tag can't ship malicious
# code (cf. the March 2026 KICS action compromise); the digest is verified
# against Docker Hub on each bump. v2.1.20 (March 2026).
KICS_IMAGE := checkmarx/kics:v2.1.20-alpine@sha256:990ae994fbbe59760c8e4f7e89b1193a39a0c2968909058ec29335cb6d80efc1

# kubeconform validates rendered chart manifests against the Kubernetes schemas.
# Digest-pinned for the same reason as KICS. v0.7.0.
KUBECONFORM_IMAGE := ghcr.io/yannh/kubeconform:v0.7.0@sha256:85dbef6b4b312b99133decc9c6fc9495e9fc5f92293d4ff3b7e1b30f5611823c

CHART := charts/decdn-node

help:                ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

hooks:               ## install the pre-commit git hooks
	pre-commit install

lint:                ## run all pre-commit hooks on all files (mirrors CI)
	pre-commit run --all-files

lint-ansible:        ## full ansible-lint locally (installs collections first)
	$(MAKE) -C ansible deps
	$(MAKE) -C ansible lint

# All three scans always run, so a finding in one never hides the others' results.
security:            ## KICS IaC security scan of ansible/, the Helm chart and compose/ (CI runs this)
	@rc=0; $(MAKE) security-ansible || rc=1; $(MAKE) security-helm || rc=1; $(MAKE) security-compose || rc=1; exit $$rc

# -w /repo so findings carry repo-relative paths (not ../../repo/...), which is
# what the CI job summary prints and what SARIF code-scanning uploads need.
security-ansible:    ## KICS scan of ansible/ (pinned engine image)
	mkdir -p kics-results
	docker run --rm --user $(shell id -u):$(shell id -g) -w /repo -v "$(CURDIR):/repo" $(KICS_IMAGE) \
		scan --path /repo/ansible --type Ansible \
		--exclude-paths /repo/ansible/collections \
		--report-formats json,sarif --output-path /repo/kics-results \
		--no-progress --fail-on high

# The chart cannot render with its defaults (required values fail loud), so KICS
# scans the manifests rendered from the widest CI values file instead of the chart
# directory (which it would try, and fail, to render itself). Findings therefore
# point at kics-results/helm-render/decdn-node.yaml, not at the chart sources.
security-helm:       ## KICS scan of the decdn-node chart's rendered manifests (needs helm)
	mkdir -p kics-results/helm-render
	helm template decdn-node $(CHART) -f $(CHART)/ci/ci-values.yaml > kics-results/helm-render/decdn-node.yaml
	docker run --rm --user $(shell id -u):$(shell id -g) -w /repo -v "$(CURDIR):/repo" $(KICS_IMAGE) \
		scan --path /repo/kics-results/helm-render --type Kubernetes \
		--report-formats json,sarif --output-path /repo/kics-results/helm \
		--no-progress --fail-on high

# One query is excluded, deliberately: "Volume Has Sensitive Host Directory"
# (1c1325ff-…) fires on the read-only /etc/decdn mount. That directory is the node's
# own config dir, mounted :ro, and keeping the Ansible host layout is what lets the
# host CLI, backups and restores (docs/lifecycle.md) work unchanged. The two MEDIUMs
# (host network, no healthcheck) are the documented design; see compose/README.md.
security-compose:    ## KICS scan of compose/ (pinned engine image)
	mkdir -p kics-results
	docker run --rm --user $(shell id -u):$(shell id -g) -w /repo -v "$(CURDIR):/repo" $(KICS_IMAGE) \
		scan --path /repo/compose --type DockerCompose \
		--exclude-queries 1c1325ff-831d-43a1-973e-839ae57dfcc0 \
		--report-formats json,sarif --output-path /repo/kics-results/compose \
		--no-progress --fail-on high

# Renders compose/compose.yaml with the example env files and asserts the invariants
# the README promises: host networking and no published ports (so metrics and the
# admin RPC stay loopback), a digest-pinned image, read-only rootfs, every capability
# dropped, no-new-privileges, and a stop grace long enough for the daemon's drain.
COMPOSE_INVARIANTS := .services["decdn-node"] as $$s | \
	($$s.network_mode == "host") and ($$s.ports == null) and \
	($$s.image | test("@sha256:[0-9a-f]{64}$$")) and ($$s.read_only == true) and \
	($$s.cap_drop == ["ALL"]) and ($$s.security_opt | index("no-new-privileges:true") != null) and \
	($$s.stop_signal == "SIGTERM") and ($$s.stop_grace_period == "5m0s") and \
	($$s.user | test("^[0-9]+:[0-9]+$$"))

# COMPOSE_FILE is overridable so tests/scripts-test.sh can feed it broken variants.
COMPOSE_FILE ?= compose/compose.yaml
lint-compose:        ## render compose/ with its examples and check its security invariants (needs docker, jq)
	@set -o pipefail; \
	rendered="$$(DECDN_ENV_FILE=$(CURDIR)/compose/decdn.env.example docker compose -f '$(COMPOSE_FILE)' \
		--env-file compose/.env.example config --format json)" \
		|| { echo "lint-compose: docker compose could not render $(COMPOSE_FILE) (see above)" >&2; exit 2; }; \
	jq -e '$(COMPOSE_INVARIANTS)' <<<"$$rendered" >/dev/null \
		|| { echo "$(COMPOSE_FILE) violates an invariant (see the lint-compose comment in Makefile)" >&2; exit 1; }
	@echo "compose invariants hold"

# The cloud-init user-data (cloud-init/README.md): `cloud-init schema` for its shape, then
# cloud-init/tests/lint.py for what a schema cannot see. That covers no secrets, no
# hardening skip, a signed release install with a host-generated wallet, localhost in
# decdn_nodes, a keyed admin account, runcmd exactly stage 1, shellcheck-clean scripts,
# and a collection lock that covers ansible/requirements.yml.
# CLOUD_INIT_FILE is overridable so operators can check their filled-in copy and
# tests/scripts-test.sh can feed it broken variants.
CLOUD_INIT_FILE ?= cloud-init/user-data.yaml
lint-cloud-init:     ## schema-check cloud-init/user-data.yaml and its invariants (needs cloud-init, shellcheck, yq)
	@command -v cloud-init >/dev/null || { echo "lint-cloud-init: needs cloud-init on PATH" >&2; exit 2; }
	@cloud-init schema -c '$(CLOUD_INIT_FILE)' >/dev/null 2>&1 \
		|| { cloud-init schema -c '$(CLOUD_INIT_FILE)' 2>&1 | grep -v WARNING >&2; \
		     echo "lint-cloud-init: $(CLOUD_INIT_FILE) is not a valid cloud-config (see above)" >&2; exit 2; }
	@cloud-init/tests/lint.py '$(CLOUD_INIT_FILE)'
	@echo "cloud-init invariants hold"

# The guard rails nothing else exercises: ansible/Makefile's scoping guards, the
# release gate, the lint-compose and lint-cloud-init negative cases, and (with
# UPSTREAM=<decdn checkout>) the upstream-mirror generators' exit codes. CI job `scripts`.
test-scripts:        ## test the Makefile guards, release gate, lint-compose and lint-cloud-init negatives (needs docker, jq, cloud-init, yq)
	tests/scripts-test.sh

lint-helm:           ## helm lint + render tests + kubeconform + shared schema-key check (needs helm, yq, python3>=3.11, docker)
	KUBECONFORM="docker run --rm -i $(KUBECONFORM_IMAGE)" $(CHART)/tests/render-test.sh

# The molecule grafana-cloud scenario runs the role against a stub that exits 0
# for every subcommand, so it can only prove plumbing. This target renders the
# grafana_alloy templates and feeds them to the REAL pinned Alloy binary
# (`alloy validate` + an ExecStart flag check) — the only thing that catches an
# unknown component, a misplaced block or a non-existent CLI flag before a host
# crash-loops. Downloads the role's pinned .deb once, then caches it under
# ansible/.cache (git-ignored); ALLOY_BIN=<path> skips the download.
lint-alloy:          ## validate grafana_alloy's rendered config against the real pinned Alloy binary
	ansible/tests/alloy-config/validate.sh

molecule:            ## containerised converge/verify of the decdn_node role, scenarios in parallel (needs Docker)
	$(MAKE) -C ansible molecule

molecule-serial:     ## same suite, one scenario at a time (readable output on failure)
	$(MAKE) -C ansible molecule-serial

galaxy-build:        ## stage + build the decdn.node Galaxy collection artifact
	$(MAKE) -C ansible build

galaxy-check:        ## build + validate the decdn.node collection (galaxy-importer)
	$(MAKE) -C ansible galaxy-check
