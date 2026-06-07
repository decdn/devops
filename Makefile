# Convenience targets for the deCDN DevOps monorepo.
# Run from the repo root. Ansible-specific work is delegated to ansible/Makefile.
.PHONY: help hooks lint lint-ansible security molecule galaxy-build galaxy-check
SHELL := /bin/bash

# Local KICS runs use the engine image pinned by digest. CI runs the official
# Checkmarx/kics-github-action instead (a GitHub Action can't run outside CI).
# Pinning by digest means a re-pointed tag can't ship malicious code (cf. the
# March 2026 KICS action compromise); the digest is verified against Docker Hub
# on each bump. v2.1.20 (March 2026).
KICS_IMAGE := checkmarx/kics:v2.1.20-alpine@sha256:990ae994fbbe59760c8e4f7e89b1193a39a0c2968909058ec29335cb6d80efc1

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

security:            ## KICS IaC security scan of ansible/ (CI runs the official action)
	mkdir -p kics-results
	docker run --rm --user $(shell id -u):$(shell id -g) -v "$(CURDIR):/repo" $(KICS_IMAGE) \
		scan --path /repo/ansible --type Ansible \
		--exclude-paths /repo/ansible/collections \
		--report-formats json --output-path /repo/kics-results \
		--no-progress --fail-on high

molecule:            ## containerised converge/verify of the anvil stack
	$(MAKE) -C ansible molecule

galaxy-build:        ## stage + build the decdn.node Galaxy collection artifact
	$(MAKE) -C ansible build

galaxy-check:        ## build + validate the decdn.node collection (galaxy-importer)
	$(MAKE) -C ansible galaxy-check
