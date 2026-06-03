# Convenience targets for the deCDN Ansible project.
# Always run from the ansible/ directory.
.PHONY: deps lint check deploy check-anvil deploy-anvil add-dev molecule
SHELL := /bin/bash

# Install the required Galaxy collections (>= constraints in requirements.yml)
# into ./collections (git-ignored).
deps:
	ansible-galaxy collection install -r requirements.yml -p collections

# Static analysis: YAML style + Ansible best-practice linting.
lint:
	yamllint .
	ansible-lint

# --- Primary: the public deCDN node ------------------------------------------
# Dry run against the real inventory — shows diffs, mutates nothing.
check:
	ansible-playbook playbooks/site.yml --check --diff

# Provision the deCDN node host(s) in inventory/hosts.yml.
deploy:
	ansible-playbook playbooks/site.yml

# --- Internal: the anvil devnet ----------------------------------------------
check-anvil:
	ansible-playbook playbooks/anvil.yml --check --diff

deploy-anvil:
	ansible-playbook playbooks/anvil.yml

# Mint (and reveal once) a new anvil basic-auth dev user: make add-dev USER_NAME=alice
add-dev:
	@test -n "$(USER_NAME)" || { echo "usage: make add-dev USER_NAME=<name>"; exit 1; }
	ansible-playbook playbooks/add-dev-user.yml -e user=$(USER_NAME)

# Containerised converge + verify + idempotence for the anvil stack (requires docker).
molecule:
	molecule test
