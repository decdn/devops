# Convenience targets for the deCDN Ansible project.
# Always run from the ansible/ directory.
.PHONY: deps lint check deploy molecule build galaxy-check
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

# --- Tests -------------------------------------------------------------------
# Containerised converge + idempotence + verify of the decdn_node role against a
# stub daemon (needs Docker; a privileged systemd container). See molecule/.
molecule:
	molecule test

# --- Galaxy collection (decdn.node) ------------------------------------------
# Stage baseline + decdn_node into a clean collection tree and build the artifact
# under build/. Only those two roles ship; see galaxy/README.md. Publishing stays
# a manual step (ansible-galaxy collection publish build/decdn-node-*.tar.gz).
build:
	./galaxy/build.sh

# Validate the built artifact with galaxy-importer — the same checks Galaxy runs
# on upload (metadata, license file, README, embedded ansible-lint). build.sh
# leaves exactly one tarball, so the glob is unambiguous. We gate on BOTH the
# pipeline exit (set -o pipefail catches a crash / "No module named …" that prints
# no error keyword) AND the importer's explicit success line (it can log content
# errors while still exiting 0). Warnings are kept in build/importer.log.
galaxy-check: build
	@set -o pipefail; \
	  tarball=$$(ls -1 build/decdn-node-*.tar.gz); \
	  echo "galaxy-importer: $$tarball"; \
	  if ! python -m galaxy_importer.main "$$tarball" 2>&1 | tee build/importer.log \
	     || ! grep -q "Importer processing completed successfully" build/importer.log; then \
	    echo "FAIL: galaxy-importer reported errors or did not complete (see build/importer.log)"; exit 1; \
	  fi
