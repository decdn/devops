"""Unit tests for scripts/molecule-affected.py, which picks the Molecule scenarios a
pull request runs (`make test-scripts` runs them).

    python3 -m unittest discover -s scripts/tests -p 'test_*.py'

They hold against the real tree, as properties rather than a golden list: a new
scenario or role is covered without editing them, and the cases below name only
dependencies that exist to be caught (a stub read by path from another scenario, a
role reading another role's file).
"""

from __future__ import annotations

import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
_spec = importlib.util.spec_from_file_location(
    "molecule_affected", HERE.parent / "molecule-affected.py"
)
ma = importlib.util.module_from_spec(_spec)
sys.modules["molecule_affected"] = ma
_spec.loader.exec_module(ma)

TREE = ma.Tree()


def pick(*paths: str) -> str:
    out = io.StringIO()
    stdin = sys.stdin
    sys.stdin = io.StringIO("".join(f"{p}\n" for p in paths))
    try:
        with redirect_stdout(out):
            ma.main([])
    finally:
        sys.stdin = stdin
    return out.getvalue().strip()


def names(*paths: str) -> set[str]:
    got = pick(*paths)
    assert got not in ("all", "none"), f"{paths} selected {got}"
    return set(got.split())


class Properties(unittest.TestCase):
    def test_every_scenario_is_selected_by_its_own_files(self):
        for s in TREE.scenarios:
            with self.subTest(s):
                self.assertIn(s, names(f"ansible/molecule/{s}/molecule.yml"))

    def test_every_role_selects_its_own_scenarios(self):
        # Beyond cloud-init's pair, which every role change selects.
        for r in TREE.roles:
            with self.subTest(r):
                self.assertTrue(names(f"ansible/roles/{r}/tasks/main.yml") - set(ma.CLOUD_INIT))

    def test_every_playbook_selects_a_scenario(self):
        for p in TREE.playbooks:
            with self.subTest(p):
                self.assertTrue(names(f"ansible/playbooks/{p}.yml"))

    def test_a_role_change_selects_the_scenarios_named_after_it(self):
        for r in TREE.roles:
            stem = r.replace("_", "-")
            own = {s for s in TREE.scenarios if s == stem or s.startswith(f"{stem}-")}
            own |= {s for s in TREE.scenarios if s == f"validation-{stem}"}
            with self.subTest(r):
                self.assertLessEqual(own, names(f"ansible/roles/{r}/defaults/main.yml"))


class Dependencies(unittest.TestCase):
    def test_a_stub_selects_the_scenarios_that_read_it_by_path(self):
        got = names("ansible/molecule/default/files/decdn-node-stub")
        self.assertLessEqual({"default", "os-matrix", "collection", "sponsord-install"}, got)

    def test_reading_one_file_of_a_scenario_is_not_reading_it_all(self):
        # iroh-relay reads grafana-cloud's alloy-stub, not its converge.
        self.assertIn("iroh-relay", names("ansible/molecule/grafana-cloud/files/alloy-stub"))
        self.assertEqual({"grafana-cloud"}, names("ansible/molecule/grafana-cloud/converge.yml"))

    def test_a_shared_include_selects_its_readers_but_not_the_reverse(self):
        self.assertIn("iroh-relay-gate", names("ansible/molecule/iroh-relay/converge.yml"))
        self.assertNotIn("iroh-relay", names("ansible/molecule/iroh-relay-gate/side_effect.yml"))

    def test_a_role_read_by_path_selects_the_reading_roles_scenarios(self):
        # sponsord_onramp's source build runs sponsord's install-build-output.py.
        got = names("ansible/roles/sponsord/files/install-build-output.py")
        self.assertIn("sponsord-onramp-source", got)

    def test_a_stub_under_a_templated_root_is_a_dependency(self):
        # cloud-init-publisher's mirror copies `{{ stubs }}/sponsord/files/sponsord-stub`.
        for stub in ("sponsord/files/sponsord-stub", "sponsord-onramp/files/sponsord-onramp-stub"):
            with self.subTest(stub):
                self.assertIn("cloud-init-publisher", names(f"ansible/molecule/{stub}"))

    def test_a_deleted_file_selects_every_reader_of_its_scenario(self):
        got = names("ansible/molecule/default/files/no-such-file")
        self.assertLessEqual({"default", "os-matrix", "sponsord-install"}, got)

    def test_a_deleted_file_alone_in_its_directory_keeps_its_readers(self):
        # Simulate deleting grafana-cloud's alloy-stub, the only file in files/:
        # its readers' references then resolve to nothing on disk.
        stub = REPO / "ansible/molecule/grafana-cloud/files/alloy-stub"
        tree = ma.Tree()
        tree.files["grafana-cloud"] = [f for f in tree.files["grafana-cloud"] if f != stub.resolve()]
        real_is_file = Path.is_file
        Path.is_file = lambda p: p.resolve() != stub.resolve() and real_is_file(p)
        try:
            got = ma.select(tree, "ansible/molecule/grafana-cloud/files/alloy-stub")
        finally:
            Path.is_file = real_is_file
        self.assertLessEqual({"grafana-cloud", "iroh-relay", "sponsord"}, got)

    def test_cloud_init_and_the_collection(self):
        self.assertEqual(set(ma.CLOUD_INIT), names("cloud-init/bootstrap.sh"))
        self.assertLessEqual(set(ma.CLOUD_INIT), names("ansible/roles/iroh_relay/tasks/main.yml"))
        self.assertIn("collection", names("ansible/roles/decdn_node/tasks/main.yml"))
        self.assertNotIn("collection", names("ansible/roles/iroh_relay/tasks/main.yml"))
        self.assertEqual({"collection"}, names("ansible/galaxy/build.sh"))

    def test_group_vars_select_every_playbook_scenario(self):
        got = names("ansible/playbooks/group_vars/all.yml")
        self.assertLessEqual({"decdn-gateway", "iroh-relay", "sponsord", "lifecycle"}, got)
        self.assertNotIn("default", got)


class Edges(unittest.TestCase):
    def test_the_runner_itself_selects_all(self):
        for p in sorted(ma.ALL_PATHS):
            with self.subTest(p):
                self.assertEqual("all", pick(p))

    def test_an_unknown_path_selects_all(self):
        for p in ("ansible/foo", "ansible/molecule/no-such-scenario/molecule.yml",
                  "ansible/roles/no_such_role/tasks/main.yml", "ansible/playbooks/gone.yml",
                  "ansible/playbooks/notes.txt"):
            with self.subTest(p):
                self.assertEqual("all", pick(p))

    def test_paths_no_scenario_reads_select_none(self):
        for p in ("ansible/inventory/hosts.yml.example", "ansible/README.md",
                  "ansible/roles/decdn_node/README.md", "ansible/tests/x", "compose/compose.yaml",
                  "docs/node-operators.md"):
            with self.subTest(p):
                self.assertEqual("none", pick(p))
        self.assertEqual("none", pick())

    def test_all_wins_over_names(self):
        self.assertEqual("all", pick("ansible/roles/iroh_relay/tasks/main.yml", "ansible/Makefile"))

    def test_the_output_is_what_molecule_list_accepts(self):
        got = pick("ansible/roles/decdn_gateway/tasks/main.yml")
        subprocess.run(
            ["make", "-s", "-C", str(REPO / "ansible"), "molecule-list", f"SCENARIOS={got}"],
            check=True, capture_output=True,
        )

    def test_since_reads_commits_the_working_tree_and_untracked_files(self):
        # Away from the caller's git config: commit signing or hooks would fail it.
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        with tempfile.TemporaryDirectory() as d:
            def git(*a: str) -> str:
                return subprocess.run(["git", *a], cwd=d, env=env, check=True,
                                      capture_output=True, text=True).stdout
            git("init", "-q", "-b", "main")
            git("commit", "-q", "--allow-empty", "-m", "0")
            Path(d, "a").write_text("a")
            git("add", "a")
            git("commit", "-q", "-m", "1")
            Path(d, "a").write_text("b")          # working tree
            Path(d, "u").write_text("u")          # untracked
            repo, ma.REPO = ma.REPO, Path(d)
            try:
                self.assertEqual(["a", "u"], sorted(ma.changed_since("HEAD~1")))
            finally:
                ma.REPO = repo


if __name__ == "__main__":
    unittest.main()
