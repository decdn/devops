# Convenience targets for the deCDN Ansible project.
# Always run from the ansible/ directory.
.PHONY: deps lint check deploy check-node deploy-node check-origin deploy-origin check-publisher deploy-publisher check-sponsord deploy-sponsord check-relay deploy-relay check-dns deploy-dns backup decommission molecule molecule-serial molecule-list build build-node build-publisher galaxy-check galaxy-check-node galaxy-check-publisher
SHELL := /bin/bash

# Install the required Galaxy collections (>= constraints in requirements.yml)
# into ./collections (git-ignored). Safe beside a running molecule suite: it refuses
# to rewrite the tree under one (see scripts/molecule.sh).
deps:
	@$(molecule_env) ../scripts/molecule.sh deps

# Static analysis: YAML style + Ansible best-practice linting.
lint:
	yamllint .
	ansible-lint

# --- Deploys: node operators and publishers -----------------------------------
# Optional scoping for the deploy targets. Both are empty by default, so check/deploy
# stay fleet-wide (every host in the inventory) unless you say otherwise.
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
# inventory/hosts.yml (copy hosts-node.yml.example or hosts-publisher.yml.example). A real fleet keeps its inventory in a
# private overlay outside this public repo and points at it here:
#   make deploy INVENTORY=../../decdn-fleet/hosts.yml LIMIT=<host>
# The overlay's own group_vars/ and host_vars/ must sit beside that hosts.yml, where
# Ansible loads them automatically. See ansible/README.md "Private fleet inventory".
INVENTORY ?= inventory/hosts.yml
# A missing or unparseable inventory fails the run. Ansible's default only warns,
# skips the `hosts: decdn_nodes` play and exits 0, so a mistyped INVENTORY= would
# report a successful deploy that did nothing. This applies to the playbook targets
# (check/deploy and their -node/-origin/-publisher/-sponsord/-relay/-dns variants,
# backup/decommission) only:
# ansible.cfg can't set it globally, because ansible-lint's own syntax checks run
# with no inventory present.
strict_inventory = ANSIBLE_INVENTORY_UNPARSED_FAILED=True

# Fail loud on the two ways a run can look scoped but silently be fleet-wide. Scoped to
# the playbook targets (check/deploy[-node|-origin|-publisher|-sponsord|-relay|-dns]/backup/decommission) via MAKECMDGOALS so an
# unrelated `make lint` is never blocked. NOTE: this
# does not catch an argument that is well-formed but selects nothing — `--tags` with a
# typo (decdn-node vs decdn_node) runs zero tasks and still exits 0. See ansible/README.md.
ifneq ($(filter check deploy check-node deploy-node check-origin deploy-origin check-publisher deploy-publisher check-sponsord deploy-sponsord check-relay deploy-relay check-dns deploy-dns backup decommission,$(MAKECMDGOALS)),)
  # Echo back the goal the operator actually typed, so the hint never nudges a
  # `make check` dry-run toward the mutating `make deploy`.
  scoped_goal := $(firstword $(filter check deploy check-node deploy-node check-origin deploy-origin check-publisher deploy-publisher check-sponsord deploy-sponsord check-relay deploy-relay check-dns deploy-dns backup decommission,$(MAKECMDGOALS)))
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

# Dry run of everything in $(INVENTORY) (site.yml: node.yml, then publisher.yml) —
# shows diffs, mutates nothing.
check:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/site.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

# Provision every host in $(INVENTORY) (default inventory/hosts.yml).
deploy:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/site.yml $(limit_arg) $(ANSIBLE_ARGS)

# Node operators: the cache nodes alone (playbooks/node.yml, decdn_nodes that are not
# in decdn_origin_nodes).
check-node:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/node.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

deploy-node:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/node.yml $(limit_arg) $(ANSIBLE_ARGS)

# Publishers: everything a publisher runs (playbooks/publisher.yml: origins, sponsord
# and its onramp, iroh relays, iroh DNS servers), leaving the cache nodes untouched.
check-publisher:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/publisher.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

deploy-publisher:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/publisher.yml $(limit_arg) $(ANSIBLE_ARGS)

# A publisher's origin nodes alone (playbooks/origin.yml, hosts in decdn_origin_nodes).
check-origin:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/origin.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

deploy-origin:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/origin.yml $(limit_arg) $(ANSIBLE_ARGS)

# sponsord alone (playbooks/sponsord.yml, hosts in sponsord_hosts). check/deploy and
# check/deploy-publisher above already include it; these leave every decdn-node untouched.
check-sponsord:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/sponsord.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

deploy-sponsord:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/sponsord.yml $(limit_arg) $(ANSIBLE_ARGS)

# iroh relays alone (playbooks/iroh_relay.yml, hosts in iroh_relay_hosts). check/deploy
# and check/deploy-publisher above already include them; these leave every other host
# untouched.
check-relay:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/iroh_relay.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

deploy-relay:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/iroh_relay.yml $(limit_arg) $(ANSIBLE_ARGS)

# iroh DNS servers alone (playbooks/iroh_dns_server.yml, hosts in iroh_dns_server_hosts).
# check/deploy and check/deploy-publisher above already include them; these leave every
# other host untouched.
check-dns:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/iroh_dns_server.yml --check --diff $(limit_arg) $(ANSIBLE_ARGS)

deploy-dns:
	$(strict_inventory) ansible-playbook -i '$(INVENTORY)' playbooks/iroh_dns_server.yml $(limit_arg) $(ANSIBLE_ARGS)

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
# Containerised converge + idempotence + verify of the roles against stub daemons
# (needs Docker; privileged systemd containers). See molecule/.
# Scenarios: default (rendered values + idempotence), schema (config key-set drift
# against the upstream field list), validation, validation-alloy and
# validation-sponsord (bad knobs, every role, must be rejected by their own asserts;
# split by role so they run side by side), generate-keystore (opt-in host-side
# wallet), host-env (host-provisioned /etc/decdn/decdn.env), slow-readiness (advisory
# /metrics probe timeout), grafana-cloud and grafana-cloud-token (opt-in Grafana
# Cloud observability, host-provisioned vs inventory token), os-matrix (default's
# plays on Debian 13, Ubuntu 24.04 and 26.04), lifecycle (network profile,
# backup + decommission), sponsord and sponsord-install (the sponsord role on a host
# with no node, through playbooks/sponsord.yml, on Debian 12 and Ubuntu 24.04; the
# install-method, wallet and secret.env provenance side effects run in
# sponsord-install), sponsord-onramp and sponsord-onramp-caddy (the onramp beside its
# daemon, behind the real distro Caddy; the proxy, gate-page and inventory Turnstile
# side effects run in sponsord-onramp-caddy), sponsord-onramp-source
# (that converge, then both sponsord roles built from source), sponsord-onramp-lifecycle
# (that converge, then sponsord's backup and decommission), iroh-relay,
# iroh-relay-certificate, iroh-relay-gate, iroh-relay-lifecycle and
# iroh-relay-install (the relay through playbooks/iroh_relay.yml against a stub on
# Debian 12 and Ubuntu 24.04: restarts, the fatal gate, the port guard; then the
# certificate check, the gate's other refusals with the bind and access modes, its
# decommission, and its release install from a local mirror), validation-iroh-relay
# (the relay's bad knobs), iroh-dns-server, iroh-dns-server-certificate,
# iroh-dns-server-gate, iroh-dns-server-install and iroh-dns-server-lifecycle (the
# DNS server through playbooks/iroh_dns_server.yml against a stub, the same split as
# the relay's), validation-iroh-dns-server (its bad knobs), source-build,
# source-build-rollback and
# source-build-recovery (the node built from source on the host: sandbox, stamps;
# then a rollback from a broken commit; then the install-method switch, an untrusted
# build home and a lost restart), and cloud-init and
# cloud-init-sponsord (the cloud-init/ templates, booted for real). The glob in
# scripts/molecule.sh is the authority; this list is a guide.
#
#   make molecule                               every scenario, in parallel
#   make molecule SCENARIOS='sponsord schema'   a subset
#   make molecule JOBS=2                        narrower fan-out on a small machine
#   make molecule-serial                        one at a time, stops at the first failure
#   make molecule-list                          the selection as JSON (CI's matrix)
#
# The scenarios run concurrently: distinct container names, no published host ports,
# per-scenario ephemeral dirs, and what they share on the control machine (the
# vendored collections, roles/, the stubs under */files/) they only read.
# 595s -> 151s on a 16-core box. They DO share one Docker daemon and the host cgroup
# hierarchy (every platform is a privileged systemd container), which is why CI gives
# each scenario its own runner (.github/workflows/molecule.yml). Output interleaves,
# hence the [scenario] prefix; `molecule-serial` is the escape hatch when a failure
# needs reading in order.
#
# Molecule's own --workers is not usable here: it refuses to run outside collection
# mode ("--workers > 1 is only supported in collection mode (galaxy.yml required)"),
# and this project deliberately has no galaxy.yml at its root — that would make
# ansible-lint reinterpret the deploy project as a collection (see README.md, "Packaging as Galaxy collections").
#
# Fail-loud discovery, the per-scenario locks (two agents can run disjoint scenarios
# at once, never the same one) and the lock that keeps deps from rewriting
# collections/ under a running scenario live in scripts/molecule.sh, with the
# reasoning; tests/scripts-test.sh pins them.
#
# SLOW_FIRST is the start order of the heavy scenarios, longest first as measured in
# CI; the rest follow by name. A name here that is not a scenario fails the run, so a
# rename cannot leave it silently stale.
SCENARIOS ?= all
JOBS ?=
SLOW_FIRST ?= sponsord-onramp-source sponsord-install cloud-init source-build-recovery \
	iroh-relay-gate cloud-init-sponsord sponsord source-build sponsord-onramp \
	sponsord-onramp-caddy iroh-relay source-build-rollback iroh-relay-certificate \
	validation iroh-relay-install os-matrix grafana-cloud
MOLECULE_LOCK_PREFIX ?= /tmp/decdn-devops-molecule
molecule_env = SCENARIOS='$(SCENARIOS)' JOBS='$(JOBS)' SLOW_FIRST='$(SLOW_FIRST)' \
	MOLECULE_LOCK_PREFIX='$(MOLECULE_LOCK_PREFIX)'

molecule:
	@$(molecule_env) ../scripts/molecule.sh parallel

molecule-serial:
	@$(molecule_env) ../scripts/molecule.sh serial

molecule-list:
	@$(molecule_env) ../scripts/molecule.sh list

# --- Galaxy collections (decdn.node, decdn.publisher) -------------------------
# Stage each collection's roles (galaxy/<collection>/roles.txt) into a clean collection
# tree and build the artifact under build/: decdn.node is what a node operator runs
# (baseline + decdn_node + grafana_alloy), decdn.publisher what a publisher runs beside
# its origins (sponsord + sponsord_onramp + iroh_relay + iroh_dns_server). See
# galaxy/*/README.md. Publishing runs from a node-collection-vX.Y.Z or
# publisher-collection-vX.Y.Z tag in .github/workflows/release-collection.yml (see
# RELEASING.md).
build: build-node build-publisher

build-node build-publisher: build-%:
	./galaxy/build.sh $*

# Validate a built artifact with galaxy-importer — the same checks Galaxy runs on
# upload (metadata, license file, README, embedded ansible-lint). build.sh leaves
# exactly one tarball per collection, so the glob is unambiguous. We gate on BOTH the
# pipeline exit (set -o pipefail catches a crash / "No module named …" that prints
# no error keyword) AND the importer's explicit success line (it can log content
# errors while still exiting 0). Warnings are kept in build/importer-<collection>.log.
galaxy-check: galaxy-check-node galaxy-check-publisher

galaxy-check-node galaxy-check-publisher: galaxy-check-%: build-%
	@set -o pipefail; \
	  tarball=$$(ls -1 build/decdn-$*-*.tar.gz); \
	  echo "galaxy-importer: $$tarball"; \
	  if ! python -m galaxy_importer.main "$$tarball" 2>&1 | tee build/importer-$*.log \
	     || ! grep -q "Importer processing completed successfully" build/importer-$*.log; then \
	    echo "FAIL: galaxy-importer reported errors or did not complete (see build/importer-$*.log)"; exit 1; \
	  fi
