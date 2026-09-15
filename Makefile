# Convenience targets for the deCDN DevOps monorepo.
# Run from the repo root. Ansible-specific work is delegated to ansible/Makefile.
.PHONY: help hooks lint lint-ansible lint-helm security security-ansible security-helm molecule galaxy-build galaxy-check
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

# Both scans always run, so a finding in one never hides the other's results.
security:            ## KICS IaC security scan of ansible/ and the Helm chart (CI runs this)
	@rc=0; $(MAKE) security-ansible || rc=1; $(MAKE) security-helm || rc=1; exit $$rc

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

lint-helm:           ## helm lint + render tests + kubeconform + shared schema-key check (needs helm, yq, python3>=3.11, docker)
	KUBECONFORM="docker run --rm -i $(KUBECONFORM_IMAGE)" $(CHART)/tests/render-test.sh

molecule:            ## containerised converge/verify of the decdn_node role (needs Docker)
	$(MAKE) -C ansible molecule

galaxy-build:        ## stage + build the decdn.node Galaxy collection artifact
	$(MAKE) -C ansible build

galaxy-check:        ## build + validate the decdn.node collection (galaxy-importer)
	$(MAKE) -C ansible galaxy-check
