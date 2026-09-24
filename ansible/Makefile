# Convenience targets for the deCDN Ansible project.
# Always run from the ansible/ directory.
.PHONY: deps lint check deploy backup decommission molecule molecule-serial build galaxy-check
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
#     ANSIBLE_ARGS='--start-at-task="Install decdn-node + decdn CLI"' survives). Unquoted
#     at your prompt, make takes the extra words as goals and flags of its own — a
#     bare -vv is make's own -v. A literal $ must be written $$.
LIMIT ?=
ANSIBLE_ARGS ?=
limit_arg = $(if $(LIMIT),--limit '$(LIMIT)')

# Which inventory check/deploy run against. The default is the git-ignored
# inventory/hosts.yml (copy hosts.yml.example). A real fleet keeps its inventory in a
# private overlay outside this public repo and points at it here:
#   make deploy INVENTORY=../../decdn-fleet/hosts.yml LIMIT=<host>
# The overlay's own group_vars/ and host_vars/ must sit beside that hosts.yml, where
# Ansible loads them automatically. See ansible/README.md "Private fleet inventory".
INVENTORY ?= inventory/hosts.yml
# A missing or unparseable inventory fails the run. Ansible's default only warns,
# skips the `hosts: decdn_nodes` play and exits 0, so a mistyped INVENTORY= would
# report a successful deploy that did nothing. This applies to the playbook targets
# (check/deploy/backup/decommission) only:
# ansible.cfg can't set it globally, because ansible-lint's own syntax checks run
# with no inventory present.
strict_inventory = ANSIBLE_INVENTORY_UNPARSED_FAILED=True

# Fail loud on the two ways a run can look scoped but silently be fleet-wide. Scoped to
# the playbook targets (check/deploy/backup/decommission) via MAKECMDGOALS so an
# unrelated `make lint` is never blocked. NOTE: this
# does not catch an argument that is well-formed but selects nothing — `--tags` with a
# typo (decdn-node vs decdn_node) runs zero tasks and still exits 0. See ansible/README.md.
ifneq ($(filter check deploy backup decommission,$(MAKECMDGOALS)),)
  # Echo back the goal the operator actually typed, so the hint never nudges a
  # `make check` dry-run toward the mutating `make deploy`.
  scoped_goal := $(firstword $(filter check deploy backup decommission,$(MAKECMDGOALS)))
  ifeq ($(origin LIMIT),environment)
    $(error LIMIT is set in your environment ($(LIMIT)) and would silently scope this run. Unset it or pass it on the command line: make $(scoped_goal) LIMIT=<host>)
  endif
  ifeq ($(origin ANSIBLE_ARGS),environment)
    $(error ANSIBLE_ARGS is set in your environment and would silently alter this run. Unset it or pass it on the command line)
  endif
  ifeq ($(origin INVENTORY),environment)
    $(error INVENTORY is set in your environment ($(INVENTORY)) and would silently retarget this run. Unset it or pass it on the command line: make $(scoped_goal) INVENTORY=<path>)
  endif
  ifeq ($(strip $(INVENTORY)),)
    $(error INVENTORY expanded empty (unset shell variable?) - refusing to guess which fleet to target)
  endif
  ifeq ($(origin LIMIT),command line)
    ifeq ($(strip $(LIMIT)),)
      $(error LIMIT was supplied but expanded empty (unset shell variable?) - refusing to run fleet-wide by accident. Omit LIMIT entirely to mean "all hosts")
    endif
  endif
  # Decommission is never fleet-wide by default: it needs an explicit LIMIT on the
  # command line (the role also caps it at decdn_decommission_max_hosts and asks for
  # typed confirmation).
  ifneq ($(filter decommission,$(MAKECMDGOALS)),)
    ifneq ($(origin LIMIT),command line)
      $(error make decommission needs LIMIT=<host> on the command line - it never runs fleet-wide by default)
    endif
  endif
endif

# Dry run against $(INVENTORY) — shows diffs, mutates nothing.
check:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/site.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

# Provision the deCDN node host(s) in $(INVENTORY) (default inventory/hosts.yml).
deploy:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/site.yml $(limit_arg) $(ANSIBLE_ARGS)

# Encrypted backup of each node (identity by default; -e decdn_backup_scope=full for
# the whole data dir, which stops the node for the copy). One host at a time.
# Needs decdn_backup_age_recipients. See docs/lifecycle.md.
backup:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/backup.yml $(limit_arg) $(ANSIBLE_ARGS)

# Stop the node and remove its unit on LIMIT (required). Keeps the identity; prints
# the on-chain exit steps. Asks for typed confirmation. See docs/lifecycle.md.
decommission:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/decommission.yml $(limit_arg) $(ANSIBLE_ARGS)

# --- Tests -------------------------------------------------------------------
# Containerised converge + idempotence + verify of the decdn_node role against a
# stub daemon (needs Docker; a privileged systemd container). See molecule/.
# Scenarios: default (rendered values + idempotence), schema (config key-set drift
# against the upstream field list), validation (bad knobs, both roles, must be
# rejected by their own asserts), generate-keystore (opt-in host-side wallet),
# host-env (host-provisioned /etc/decdn/decdn.env), slow-readiness (advisory
# /metrics probe timeout), grafana-cloud and grafana-cloud-token (opt-in Grafana
# Cloud observability, host-provisioned vs inventory token), os-matrix (default's
# plays on Debian 13, Ubuntu 24.04 and 26.04) and lifecycle (network profile,
# backup + decommission). The glob below is the authority; this list is a guide.
#
# The scenarios run concurrently: distinct container names, no published host ports,
# per-scenario ephemeral dirs, and what they share on the control machine (the
# vendored collections, roles/, the stub under default/files/) they only read.
# 595s -> 151s on a 16-core box. They DO share one Docker daemon and the host cgroup
# hierarchy — every platform is a privileged systemd container — which is why CI caps
# JOBS. Output interleaves, hence the [scenario] prefix; `molecule-serial` is the
# escape hatch when a failure needs reading in order. Override the fan-out width with
# e.g. `make molecule JOBS=2` on a small machine.
#
# Molecule's own --workers is not usable here: it refuses to run outside collection
# mode ("--workers > 1 is only supported in collection mode (galaxy.yml required)"),
# and this project deliberately has no galaxy.yml at its root — that would make
# ansible-lint reinterpret the deploy project as a collection (see galaxy/README.md).
#
# Fail loud (hard rule 4), in three places, because a test harness that passes when it
# did not run is worse than a slow one:
#   - the guard below refuses an empty or truncated scenario set. Discovery moved from
#     molecule to a glob, and a glob that matches nothing (wrong cwd, renamed layout)
#     would otherwise run zero scenarios and exit 0 — a green build that tested nothing.
#   - pipefail stops the [scenario] prefixing pipe from masking molecule's status, and
#     each scenario announces its own failure by name (the bare xargs message does not).
#   - xargs then exits non-zero. The `|| exit 1` in the wrapper normalises every
#     scenario failure to 1, which is what keeps xargs off its own abort-on-255 path —
#     that one stops launching queued scenarios, so a single unlucky exit code would
#     otherwise cut the suite short. So: 123 when a scenario failed, 125 if one was
#     killed by a signal, and every scenario always gets to run.
SCENARIOS := $(notdir $(patsubst %/,%,$(dir $(wildcard molecule/*/molecule.yml))))
SCENARIO_DIRS := $(notdir $(patsubst %/,%,$(wildcard molecule/*/)))
JOBS ?= $(words $(SCENARIOS))

molecule: deps
	@test -n "$(strip $(SCENARIOS))" && test "$(strip $(SCENARIOS))" = "$(strip $(SCENARIO_DIRS))" || { \
	  echo "scenario discovery failed: molecule.yml in [$(SCENARIOS)] but scenario dirs are [$(SCENARIO_DIRS)]"; \
	  echo "refusing to run a silently-truncated suite (this target must run from ansible/)"; exit 1; }
	@case '$(JOBS)' in ''|*[!0-9]*) \
	  echo "JOBS must be a positive integer (got '$(JOBS)')"; exit 1 ;; esac
	@test "$$((10#$(JOBS)))" -gt 0 || { \
	  echo "JOBS must be a positive integer (got '$(JOBS)'): any all-zero value — 0, 00, 000 —"; \
	  echo "reaches xargs as -P 0, which means UNLIMITED concurrency, not none"; exit 1; }
	@printf '%s\n' $(SCENARIOS) | xargs -P $(JOBS) -I{} \
		bash -c 'set -euo pipefail; molecule test -s {} --no-command-borders 2>&1 | sed -u "s/^/[{}] /" \
		  || { echo "[{}] SCENARIO FAILED"; exit 1; }'

# The same suite, one scenario at a time (molecule's own --all). It stops at the FIRST
# failing scenario (--continue-on-failure defaults off), so it reports less than the
# parallel target — but readably, which is the point.
molecule-serial: deps
	molecule test --all

# --- Galaxy collection (decdn.node) ------------------------------------------
# Stage baseline + decdn_node + grafana_alloy into a clean collection tree and build the
# artifact under build/. Only the three roles ship; see galaxy/README.md. Publishing
# runs from a vX.Y.Z tag in .github/workflows/release.yml (see RELEASING.md).
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
