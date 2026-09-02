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
# Optional scoping for the deploy targets. Both are empty by default, so check/deploy
# stay fleet-wide (every host in decdn_nodes) unless you say otherwise.
#   make deploy LIMIT=decdn-node-1                        # one host
#   make deploy LIMIT='decdn-node-1,decdn-node-2'         # a list
#   make deploy ANSIBLE_ARGS='--tags decdn_node -vv'
#
# Quote both values at YOUR prompt, not just in the examples:
#   - make expands the --limit value single-quoted, so ansible host patterns reach
#     ansible intact — but your own shell runs first, and eats an unquoted '!node'
#     (history expansion) or 'decdn-node-*' (globbing) before make ever starts.
#   - ANSIBLE_ARGS is substituted unquoted on purpose: the recipe's shell splits it
#     back into separate flags (so inner quoting works —
#     ANSIBLE_ARGS='--start-at-task="Install the decdn binaries"' survives). Unquoted
#     at your prompt, make takes the extra words as goals and flags of its own — a
#     bare -vv is make's own -v. A literal $ must be written $$.
LIMIT ?=
ANSIBLE_ARGS ?=
limit_arg = $(if $(LIMIT),--limit '$(LIMIT)')

# Fail loud on the two ways a run can look scoped but silently be fleet-wide. Scoped to
# check/deploy via MAKECMDGOALS so an unrelated `make lint` is never blocked. NOTE: this
# does not catch an argument that is well-formed but selects nothing — `--tags` with a
# typo (decdn-node vs decdn_node) runs zero tasks and still exits 0. See ansible/README.md.
ifneq ($(filter check deploy,$(MAKECMDGOALS)),)
  # Echo back the goal the operator actually typed, so the hint never nudges a
  # `make check` dry-run toward the mutating `make deploy`.
  scoped_goal := $(firstword $(filter check deploy,$(MAKECMDGOALS)))
  ifeq ($(origin LIMIT),environment)
    $(error LIMIT is set in your environment ($(LIMIT)) and would silently scope this run. Unset it or pass it on the command line: make $(scoped_goal) LIMIT=<host>)
  endif
  ifeq ($(origin ANSIBLE_ARGS),environment)
    $(error ANSIBLE_ARGS is set in your environment and would silently alter this run. Unset it or pass it on the command line)
  endif
  ifeq ($(origin LIMIT),command line)
    ifeq ($(strip $(LIMIT)),)
      $(error LIMIT was supplied but expanded empty (unset shell variable?) - refusing to run fleet-wide by accident. Omit LIMIT entirely to mean "all hosts")
    endif
  endif
endif

# Dry run against the real inventory — shows diffs, mutates nothing.
check:
	ansible-playbook playbooks/site.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

# Provision the deCDN node host(s) in inventory/hosts.yml.
deploy:
	ansible-playbook playbooks/site.yml $(limit_arg) $(ANSIBLE_ARGS)

# --- Tests -------------------------------------------------------------------
# Containerised converge + idempotence + verify of the decdn_node role against a
# stub daemon (needs Docker; a privileged systemd container). See molecule/.
# Scenarios: default (rendered values + idempotence), schema (config key-set drift
# against the upstream field list), validation (bad knobs must be rejected by the
# role's own asserts), generate-keystore (opt-in host-side wallet), slow-readiness
# (advisory /metrics probe timeout).
# `--all` runs every scenario: `default` (operator-provisioned keystore) and
# `generate-keystore` (opt-in host-side wallet generation).
molecule:
	molecule test --all

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
