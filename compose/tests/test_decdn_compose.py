"""Unit tests for compose/decdn-compose: the parts that decide something without a
Docker host (`make test-scripts` runs them; no root, no docker needed).

    python3 -m unittest discover -s compose/tests -p 'test_*.py'
"""

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
_loader = importlib.machinery.SourceFileLoader("decdn_compose", str(HERE.parent / "decdn-compose"))
_spec = importlib.util.spec_from_loader("decdn_compose", _loader)
dc = importlib.util.module_from_spec(_spec)
sys.modules["decdn_compose"] = dc
_loader.exec_module(dc)

KEY = "SECRETAPIKEY0123456789"
METRICS_OK = "sponsord_pool_keeper_failures_total 0\nsponsord_pool_topup_unconfirmed_since_unix 0\n"


class TmpDir(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()


class EnvFile(TmpDir):
    def test_parse_skips_comments_and_strips_quotes(self) -> None:
        p = self.tmp / ".env"
        p.write_text("# A=commented\nA=1\nB='x y'\nC=\"$z\"\n# D=2\nnot a line\n")
        self.assertEqual(dc.parse_env(p), {"A": "1", "B": "x y", "C": "$z"})

    def test_set_replaces_active_then_commented_then_appends(self) -> None:
        p = self.tmp / ".env"
        p.write_text("# head\nA=1\n# B=example\n# A=old\n")
        p.chmod(0o640)
        dc.set_env(p, {"A": "2", "B": "3", "C": "4"})
        self.assertEqual(p.read_text(), "# head\nA=2\nB=3\n# A=old\nC=4\n")
        self.assertEqual(p.stat().st_mode & 0o777, 0o640)


class Redaction(unittest.TestCase):
    def test_drops_userinfo_path_and_query(self) -> None:
        out = dc.redact(
            f"url (https://arb-sepolia.g.alchemy.com/v2/{KEY}) and https://u:{KEY}@rpc.example "
            f"and https://rpc.example/?key={KEY}"
        )
        self.assertNotIn(KEY, out)
        self.assertIn("https://arb-sepolia.g.alchemy.com/<redacted>", out)

    def test_keeps_a_bare_host(self) -> None:
        self.assertEqual(dc.redact("see https://example.org now"), "see https://example.org now")


class WriteNew(TmpDir):
    def test_never_replaces_a_file(self) -> None:
        p = self.tmp / "secret"
        p.write_bytes(b"keep")
        uid, gid = p.stat().st_uid, p.stat().st_gid
        self.assertFalse(dc.write_new(p, b"new", 0o600, uid, gid))
        self.assertEqual(p.read_bytes(), b"keep")

    def test_creates_with_mode(self) -> None:
        p = self.tmp / "secret"
        self.assertTrue(dc.write_new(p, b"x", 0o600, -1, -1))
        self.assertEqual(p.stat().st_mode & 0o777, 0o600)

    def test_refuses_a_symlink(self) -> None:
        target = self.tmp / "elsewhere"
        (self.tmp / "secret").symlink_to(target)
        self.assertFalse(dc.write_new(self.tmp / "secret", b"x", 0o600, -1, -1))
        self.assertFalse(target.exists())


class HoldState(unittest.TestCase):
    def test_not_listening_holds_nothing(self) -> None:
        self.assertIsNone(dc.hold_state(0, ""))

    def test_zero_gauge_holds_nothing(self) -> None:
        self.assertIsNone(dc.hold_state(200, METRICS_OK))

    def test_a_binary_without_the_gauge_holds_nothing(self) -> None:
        self.assertIsNone(dc.hold_state(200, "sponsord_pool_keeper_failures_total 3\n"))

    def test_a_held_top_up_refuses(self) -> None:
        body = METRICS_OK.replace("unix 0", "unix 1.7e9")
        self.assertIn("holds an unconfirmed pool top-up", dc.hold_state(200, body) or "")

    def test_a_labelled_gauge_is_read(self) -> None:
        body = METRICS_OK.replace("unix 0", 'unix{pool="0xab"} 1700000000')
        self.assertIsNotNone(dc.hold_state(200, body))

    def test_unknown_states_refuse(self) -> None:
        for status, body in ((-1, ""), (500, METRICS_OK), (200, "other_metric 1\n")):
            with self.subTest(status=status):
                self.assertIn("unknown", dc.hold_state(status, body) or "")


class Guard(unittest.TestCase):
    def args(self, ignore: bool = False) -> argparse.Namespace:
        return argparse.Namespace(ignore_topup_hold=ignore)

    def test_refuses_while_held(self) -> None:
        held = METRICS_OK.replace("unix 0", "unix 1700000000")
        with (
            mock.patch.object(dc, "container_id", return_value="abc"),
            mock.patch.object(dc, "fetch", return_value=(200, held)),
        ):
            with self.assertRaises(dc.Refused) as cm:
                dc.guard_sponsord(self.args(), "restart")
            self.assertIn("--ignore-topup-hold", str(cm.exception))

    def test_retries_then_refuses_an_unanswered_probe(self) -> None:
        with (
            mock.patch.object(dc, "container_id", return_value="abc"),
            mock.patch.object(dc, "fetch", return_value=(-1, "")) as fetch,
            mock.patch.object(dc.time, "sleep"),
        ):
            with self.assertRaises(dc.Refused):
                dc.guard_sponsord(self.args(), "stop")
            self.assertEqual(fetch.call_count, 3)

    def test_override_skips_the_probe(self) -> None:
        with mock.patch.object(dc, "fetch") as fetch:
            dc.guard_sponsord(self.args(ignore=True), "restart")
            fetch.assert_not_called()

    def test_a_stopped_sponsord_is_not_probed(self) -> None:
        with mock.patch.object(dc, "container_id", return_value=""), mock.patch.object(dc, "fetch") as fetch:
            dc.guard_sponsord(self.args(), "restart")
            fetch.assert_not_called()

    def test_which_commands_touch_sponsord(self) -> None:
        self.assertTrue(dc.touches_sponsord("down", ["caddy"]))
        self.assertTrue(dc.touches_sponsord("restart", []))
        self.assertTrue(dc.touches_sponsord("stop", ["sponsord", "caddy"]))
        self.assertFalse(dc.touches_sponsord("restart", ["sponsord-onramp"]))
        self.assertFalse(dc.touches_sponsord("stop", ["decdn-node"]))


class UpRecreates(unittest.TestCase):
    RECREATE = (
        " DRY-RUN MODE -  Container decdn-sponsord-1  Recreate\n"
        " DRY-RUN MODE -  Container decdn-sponsord-1  Recreated\n"
    )

    def run_with(self, *, cid: str = "c", dry_run: str = "", rc: int = 0) -> bool:
        def fake_run(argv, **_):
            if argv[:2] == ["docker", "inspect"]:
                return subprocess.CompletedProcess(argv, 0, "/decdn-sponsord-1\n")
            self.assertIn("--dry-run", argv)
            return subprocess.CompletedProcess(argv, rc, dry_run)

        with (
            mock.patch.object(dc, "container_id", return_value=cid),
            mock.patch.object(dc, "run", side_effect=fake_run),
        ):
            return dc.up_recreates_sponsord(["sponsord-onramp"])

    def test_running_keeps_it(self) -> None:
        self.assertFalse(self.run_with(dry_run=" DRY-RUN MODE -  Container decdn-sponsord-1  Running\n"))

    def test_recreate_is_caught(self) -> None:
        self.assertTrue(self.run_with(dry_run=self.RECREATE))

    def test_another_container_recreated_leaves_it(self) -> None:
        self.assertFalse(self.run_with(dry_run=self.RECREATE.replace("sponsord-1", "sponsord-onramp-1")))

    def test_orphan_removal_is_caught(self) -> None:
        self.assertTrue(self.run_with(dry_run=" DRY-RUN MODE -  Container decdn-sponsord-1  Stopping\n"))

    def test_a_failed_dry_run_counts_as_yes(self) -> None:
        self.assertTrue(self.run_with(rc=1))

    def test_not_running_is_not_recreated(self) -> None:
        self.assertFalse(self.run_with(cid="", dry_run=self.RECREATE))


class ComposeArgv(TmpDir):
    def test_override_is_included_when_present(self) -> None:
        override = self.tmp / "compose.override.yaml"
        with mock.patch.object(dc, "OVERRIDE_FILE", override):
            self.assertNotIn(str(override), dc.compose_argv("up"))
            override.write_text("services: {}\n")
            argv = dc.compose_argv("up", "-d")
        self.assertEqual(argv[-4:], ["-f", str(override), "up", "-d"])
        self.assertIn("--project-directory", argv)


class NodeToml(TmpDir):
    # The shape `decdn config init` writes (v0.0.2), cut down.
    SAMPLE = (
        '# deCDN node configuration\n\n[identity]\n# data_dir = "~/.decdn"\n# region = "US"\n\n'
        '[network]\n# bind_port = 4433\n\n[cache]\n# region = "us-east-1"\n'
    )

    def edit(self, cache_node: bool) -> str:
        p = self.tmp / "node.toml"
        p.write_text(self.SAMPLE)
        with mock.patch.object(dc, "NODE_TOML", p):
            dc.edit_node_toml("DE", cache_node=cache_node)
            dc.edit_node_toml("DE", cache_node=cache_node)  # idempotent
        return p.read_text()

    def test_cache_node(self) -> None:
        self.assertEqual(
            self.edit(True),
            '# deCDN node configuration\n\n[identity]\ndata_dir = "/var/lib/decdn"\nregion = "DE"\n\n'
            "[network]\n# bind_port = 4433\n\n[cache]\n"
            'node_to_node_pull_through_enabled = true\n# region = "us-east-1"\n',
        )

    def test_refuses_a_file_without_identity(self) -> None:
        p = self.tmp / "node.toml"
        p.write_text("[cache]\n")
        with mock.patch.object(dc, "NODE_TOML", p), self.assertRaises(dc.Refused):
            dc.edit_node_toml("DE", cache_node=True)

    def test_origin_has_no_pull_through(self) -> None:
        self.assertNotIn("pull_through", self.edit(False))


class Mirror(TmpDir):
    def test_reads_the_generated_mirrors(self) -> None:
        sd = dc.network_profile("sponsord", "arbitrum-sepolia")
        self.assertEqual(sd["chain_id"], "421614")
        self.assertRegex(sd["payment_pool_address"], r"^0x[0-9a-fA-F]{40}$")
        onramp = dc.network_profile("sponsord_onramp", "arbitrum-sepolia")
        self.assertRegex(onramp["capacity_bond_address"], r"^0x[0-9a-fA-F]{40}$")
        self.assertEqual(dc.network_profile("sponsord", "no-such-chain"), {})

    def test_fills_only_empty_values(self) -> None:
        p = self.tmp / "sponsord.env"
        p.write_text("SPONSORD_CHAIN_ID=1\nSPONSORD_PAYMENT_POOL_ADDR=\n")
        dc.fill_from_mirror(
            p,
            "sponsord",
            "arbitrum-sepolia",
            {"SPONSORD_CHAIN_ID": "chain_id", "SPONSORD_PAYMENT_POOL_ADDR": "payment_pool_address"},
        )
        env = dc.parse_env(p)
        self.assertEqual(env["SPONSORD_CHAIN_ID"], "1")
        self.assertRegex(env["SPONSORD_PAYMENT_POOL_ADDR"], r"^0x[0-9a-fA-F]{40}$")


class Validate(unittest.TestCase):
    def test_a_refusal_is_shown_redacted(self) -> None:
        out = f"error: rpc https://rpc.example/v2/{KEY} unreachable\n"
        cp = subprocess.CompletedProcess([], 1, out)
        with mock.patch.object(dc, "decdn_cli", return_value=cp):
            found = dc.validate_node(dc.Project({"DECDN_ENV_FILE": "/nonexistent"}))
        self.assertEqual(len(found), 1)
        self.assertNotIn(KEY, found[0])
        self.assertIn("https://rpc.example/<redacted>", found[0])


class FileProblem(TmpDir):
    def test_modes_and_owners(self) -> None:
        p = self.tmp / "f"
        self.assertIn("missing", dc.file_problem(p, None) or "")
        p.write_text("x")
        p.chmod(0o640)
        self.assertIn("0640", dc.file_problem(p, None) or "")
        p.chmod(0o600)
        self.assertIsNone(dc.file_problem(p, None))
        self.assertIn("owned by", dc.file_problem(p, p.stat().st_uid + 1) or "")
        p.write_text("")
        self.assertIn("empty", dc.file_problem(p, None) or "")
        self.assertIsNone(dc.file_problem(p, None, nonempty=False))


class Profiles(unittest.TestCase):
    def test_onramp_starts_its_daemon(self) -> None:
        project = dc.Project({"COMPOSE_PROFILES": "origin, onramp,caddy"})
        self.assertEqual(project.services, {"decdn-node", "sponsord", "sponsord-onramp", "caddy"})

    def test_profiles_match_compose_yaml(self) -> None:
        text = (HERE.parent / "compose.yaml").read_text()
        for profile, services in dc.PROFILES.items():
            for svc in services:
                self.assertRegex(text, rf"(?ms)^  {svc}:\n.*?^    profiles: \[[^\]]*\b{profile}\b")

    def test_project_name_matches_compose_yaml(self) -> None:
        text = (HERE.parent / "compose.yaml").read_text()
        self.assertRegex(text, rf"(?m)^name: {dc.PROJECT}$")

    def test_init_refuses_node_and_origin_together(self) -> None:
        args = argparse.Namespace(
            profiles=["node", "origin"], origin=None, region="DE", domain=None, chain="x", generate_treasury=False
        )
        with mock.patch.object(dc, "require_root"), self.assertRaises(dc.Refused):
            dc.init(args)


if __name__ == "__main__":
    unittest.main()
