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

# promtool (from the Prometheus image) checks the chart's alert rules. Digest-pinned
# for the same reason as KICS. v3.14.0.
PROMTOOL_IMAGE := prom/prometheus:v3.14.0@sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0

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
# (1c1325ff-…) flags every host-path mount: /etc/decdn (ro) and /var/lib/decdn, the
# /etc/sponsord gate-page directory (ro) and /var/lib/caddy. They are the Ansible
# roles' host layout, which is what lets backups and restores (docs/lifecycle.md)
# work unchanged; lint-compose pins each container's exact mounts (and secrets)
# instead. The MEDIUMs (host network, no healthcheck on the sponsor's, Caddy's and
# the iroh services' images, NET_BIND_SERVICE on Caddy and the iroh services) are
# the documented design; see compose/README.md. KICS has no query for the iroh
# services' uid 0 (the only root services, NET_BIND_SERVICE alone): lint-compose
# pins that instead.
security-compose:    ## KICS scan of compose/ (pinned engine image)
	mkdir -p kics-results
	docker run --rm --user $(shell id -u):$(shell id -g) -w /repo -v "$(CURDIR):/repo" $(KICS_IMAGE) \
		scan --path /repo/compose --type DockerCompose \
		--exclude-queries 1c1325ff-831d-43a1-973e-839ae57dfcc0 \
		--report-formats json,sarif --output-path /repo/kics-results/compose \
		--no-progress --fail-on high

# Renders compose/compose.yaml with every profile on, three times, and checks each:
#  - with the example .env, against compose/tests/invariants.jq: the properties the
#    README promises (host network, nothing published, images by digest, read-only
#    rootfs, no capabilities beyond NET_BIND_SERVICE for Caddy and the iroh
#    services, exact security_opt, non-root users (uid 0 for the iroh relay and DNS
#    server only, with that one capability), each container's exact mounts, loopback sponsord listeners,
#    secret files only, stop graces long enough for each daemon's drain);
#  - with every service env file empty (/dev/null), against
#    compose/tests/inline-env.jq: compose.yaml itself sets only the allowed
#    environment keys, so no secret (DECDN_RPC_URL, SPONSORD_RPC_URL) moves into the
#    tracked file. (Not `config --no-env-resolution`: older Compose releases, such
#    as the CI runner's, still merge the env files with it.)
#  - with an empty .env, against compose/tests/fail-closed.jq: an unset variable
#    renders a value its service refuses, since compose.yaml cannot use `:?`.
# check <jq program> <.env file> <examples|none> does one of them: the service env
# files are compose/'s examples, or /dev/null for each. All run
# under `env -i`, because the caller's shell variables would override the
# .env and the lint would check something other than the committed defaults.
# LINT_COMPOSE_FILE (not Compose's own COMPOSE_FILE, which operators export) is
# overridable so tests/scripts-test.sh can feed it broken variants.
LINT_COMPOSE_FILE ?= compose/compose.yaml
lint-compose:        ## render compose/ with its examples and check its security invariants (needs docker, jq)
	@set -o pipefail; \
	check() { \
		mode="$$3"; ef() { if [ "$$mode" = none ]; then echo /dev/null; else echo "$(CURDIR)/compose/$$1"; fi; }; \
		rendered="$$(env -i PATH="$$PATH" HOME="$$HOME" \
			DECDN_ENV_FILE="$$(ef decdn.env.example)" \
			SPONSORD_SECRET_ENV_FILE="$$(ef sponsord-secret.env.example)" \
			SPONSORD_ENV_FILE="$$(ef sponsord.env.example)" \
			SPONSORD_ONRAMP_ENV_FILE="$$(ef sponsord-onramp.env.example)" \
			docker compose -f '$(LINT_COMPOSE_FILE)' --env-file "$$2" --profile '*' config --format json)" \
			|| { echo "lint-compose: docker compose could not render $(LINT_COMPOSE_FILE) (see above)" >&2; exit 2; }; \
		[ -n "$$rendered" ] || { echo "lint-compose: docker compose rendered nothing" >&2; exit 2; }; \
		violations="$$(jq -r -f "$$1" <<<"$$rendered")" \
			|| { printf '%s\n' "$$violations" >&2; echo "lint-compose: $$1 failed (see above)" >&2; exit 2; }; \
		[ -z "$$violations" ] \
			|| { sed 's/^/  /' <<<"$$violations" >&2; echo "$(LINT_COMPOSE_FILE) violates an invariant (see $$1)" >&2; exit 1; }; \
	}; \
	check compose/tests/invariants.jq compose/.env.example examples; \
	check compose/tests/inline-env.jq compose/.env.example none; \
	check compose/tests/fail-closed.jq /dev/null examples
	@echo "compose invariants hold: $(LINT_COMPOSE_FILE)"

# The cloud-init user-data templates (cloud-init/README.md): `cloud-init schema` for their
# shape, then cloud-init/tests/lint.py for what a schema cannot see. That covers no
# secrets, no hardening skip, signed release installs with a host-generated node wallet,
# localhost in decdn_nodes and/or sponsord_hosts, a keyed admin account, runcmd exactly
# stage 1, shellcheck-clean scripts, and a collection lock that covers
# ansible/requirements.yml.
# CLOUD_INIT_FILE (one path or several) is overridable so operators can check their
# filled-in copy and tests/scripts-test.sh can feed it broken variants.
CLOUD_INIT_FILE ?= cloud-init/user-data-node.yaml cloud-init/user-data-publisher.yaml
lint-cloud-init:     ## schema-check the cloud-init/ user-data templates and their invariants (needs cloud-init, shellcheck, yq)
	@command -v cloud-init >/dev/null || { echo "lint-cloud-init: needs cloud-init on PATH" >&2; exit 2; }
	@# An empty list would loop zero times and report success with nothing checked.
	@test -n "$(strip $(CLOUD_INIT_FILE))" || { echo "lint-cloud-init: CLOUD_INIT_FILE is empty" >&2; exit 2; }
	@for f in $(CLOUD_INIT_FILE); do \
		cloud-init schema -c "$$f" >/dev/null 2>&1 \
			|| { cloud-init schema -c "$$f" 2>&1 | grep -v WARNING >&2; \
			     echo "lint-cloud-init: $$f is not a valid cloud-config (see above)" >&2; exit 2; }; \
		cloud-init/tests/lint.py "$$f" || exit; \
	done
	@echo "cloud-init invariants hold: $(strip $(CLOUD_INIT_FILE))"

# The guard rails nothing else exercises: ansible/Makefile's scoping guards, the
# release gate, the lint-compose and lint-cloud-init negative cases, compose/'s
# decdn-compose unit tests (compose/tests/test_decdn_compose.py), the cloud-init
# bootstrap's baseline guard and template contracts, and (with UPSTREAM=<decdn
# checkout>) the upstream-mirror generators' exit codes. CI job `scripts`.
test-scripts:        ## test the Makefile and molecule-driver guards, release gate, lint-compose and lint-cloud-init negatives, decdn-compose unit tests (needs docker, jq, python3>=3.11, cloud-init, yq)
	tests/scripts-test.sh

lint-helm:           ## helm lint + render tests + kubeconform + promtool + shared schema-key check (needs helm, yq, python3>=3.11, docker)
	KUBECONFORM="docker run --rm -i $(KUBECONFORM_IMAGE)" \
	PROMTOOL="docker run --rm -i --entrypoint promtool $(PROMTOOL_IMAGE)" \
	PROMTOOL_IMAGE="$(PROMTOOL_IMAGE)" \
	$(CHART)/tests/render-test.sh

# The molecule grafana-cloud scenario runs the role against a stub that exits 0
# for every subcommand, so it can only prove plumbing. This target renders the
# grafana_alloy templates and feeds them to the REAL pinned Alloy binary
# (`alloy validate` + an ExecStart flag check) — the only thing that catches an
# unknown component, a misplaced block or a non-existent CLI flag before a host
# crash-loops. Downloads the role's pinned .deb once, then caches it under
# ansible/.cache (git-ignored); ALLOY_BIN=<path> skips the download.
lint-alloy:          ## validate grafana_alloy's rendered config against the real pinned Alloy binary
	ansible/tests/alloy-config/validate.sh

molecule:            ## containerised converge/verify of the roles, scenarios in parallel (needs Docker; SCENARIOS='a b', JOBS=<n>)
	$(MAKE) -C ansible molecule

molecule-serial:     ## same selection, one scenario at a time (readable output on failure)
	$(MAKE) -C ansible molecule-serial

galaxy-build:        ## stage + build the decdn.node and decdn.publisher Galaxy collection artifacts
	$(MAKE) -C ansible build

galaxy-check:        ## build + validate both collections (galaxy-importer)
	$(MAKE) -C ansible galaxy-check
