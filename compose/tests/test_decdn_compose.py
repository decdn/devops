"""Unit tests for compose/decdn-compose: the parts that decide something without a
Docker host (`make test-scripts` runs them; no root, no docker needed).

    python3 -m unittest discover -s compose/tests -p 'test_*.py'
"""

from __future__ import annotations

import argparse
import http.server
import importlib.machinery
import json
import os
import re
import threading
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
        p.write_text("# A=commented\nA=1\nB='x y'\nC=\"$z\"\n# D=2\n\n   \n")
        self.assertEqual(dc.parse_env(p), {"A": "1", "B": "x y", "C": "$z"})

    def test_every_shipped_template_parses(self) -> None:
        # init installs these; parse_env refuses a line it cannot read.
        templates = [HERE.parent / ".env.example", *sorted(HERE.parent.glob("*.env.example"))]
        self.assertGreater(len(templates), 3)
        for path in templates:
            with self.subTest(path=path.name):
                dc.parse_env(path)

    def test_parse_reads_every_form_compose_reads(self) -> None:
        # Compose's dotenv parser takes these too: skipping them would leave a
        # check looking at a default (`DECDN_ORIGIN_DIR = /var/lib` unchecked).
        p = self.tmp / ".env"
        p.write_text("A = /var/lib\nB: https://k@h/x\nC:\nexport D = 1\nURL=https://h:8545/x\n")
        self.assertEqual(
            dc.parse_env(p), {"A": "/var/lib", "B": "https://k@h/x", "C": "", "D": "1", "URL": "https://h:8545/x"}
        )

    def test_parse_refuses_what_it_cannot_read(self) -> None:
        for line in ("BARE_KEY", "not a setting at all", "KEY:value-without-space-is-not-yaml"):
            with self.subTest(line=line):
                p = self.tmp / ".env"
                p.write_text(f"A=1\n{line}\n")
                with self.assertRaises(dc.Refused) as cm:
                    dc.parse_env(p)
                self.assertIn(":2:", str(cm.exception))

    def test_set_fills_a_commented_example_not_a_prose_comment(self) -> None:
        p = self.tmp / ".env"
        p.write_text("# GC_API_TOKEN: the token, see below\n# GC_API_TOKEN=\n")
        dc.set_env(p, {"GC_API_TOKEN": "x"})
        self.assertEqual(p.read_text(), "# GC_API_TOKEN: the token, see below\nGC_API_TOKEN=x\n")

    def test_parse_follows_compose_on_export_and_comments(self) -> None:
        p = self.tmp / ".env"
        p.write_text("export A=1\nB=https://x/k # mine\nC=\"q\" # c\nD='a#b'\nE=a#b\n")
        self.assertEqual(dc.parse_env(p), {"A": "1", "B": "https://x/k", "C": "q", "D": "a#b", "E": "a#b"})

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

    def test_a_missing_gauge_is_unknown(self) -> None:
        # Every pinned sponsord exports it: a missing one is not "an old binary".
        self.assertIn("unknown", dc.hold_state(200, "sponsord_pool_keeper_failures_total 3\n") or "")

    def test_any_held_series_refuses(self) -> None:
        body = (
            "sponsord_pool_keeper_failures_total 0\n"
            'sponsord_pool_topup_unconfirmed_since_unix{pool="a"} 0\n'
            'sponsord_pool_topup_unconfirmed_since_unix{pool="b"} 1700000000\n'
        )
        self.assertIn("holds an unconfirmed pool top-up", dc.hold_state(200, body) or "")

    def test_a_timestamped_sample_is_read(self) -> None:
        body = METRICS_OK.replace("unix 0", "unix 1.7e9 1728000000000")
        self.assertIn("holds an unconfirmed pool top-up", dc.hold_state(200, body) or "")

    def test_an_unparseable_gauge_is_unknown(self) -> None:
        for value in ("garbage", "NaN", "+Inf", ""):
            with self.subTest(value=value):
                body = METRICS_OK.replace("unix 0", f"unix {value}")
                self.assertIn("unknown", dc.hold_state(200, body) or "")

    def test_help_and_type_lines_are_not_samples(self) -> None:
        body = (
            "# HELP sponsord_pool_topup_unconfirmed_since_unix x\n"
            "# TYPE sponsord_pool_topup_unconfirmed_since_unix gauge\n" + METRICS_OK
        )
        self.assertIsNone(dc.hold_state(200, body))

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
            mock.patch.object(dc, "sponsord_metrics_url", return_value=dc.SPONSORD_METRICS),
            mock.patch.object(dc, "fetch", return_value=(200, held)),
        ):
            with self.assertRaises(dc.Refused) as cm:
                dc.guard_sponsord(self.args(), "restart")
            self.assertIn("--ignore-topup-hold", str(cm.exception))

    def test_retries_then_refuses_an_unanswered_probe(self) -> None:
        with (
            mock.patch.object(dc, "container_id", return_value="abc"),
            mock.patch.object(dc, "sponsord_metrics_url", return_value=dc.SPONSORD_METRICS),
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
        self.assertFalse(dc.touches_sponsord("stop", ["--timeout=10", "decdn-node"]))

    def test_an_option_value_fails_closed(self) -> None:
        # `stop -t 10` stops everything: "10" is no service, so it must count.
        self.assertTrue(dc.touches_sponsord("stop", ["-t", "10"]))
        self.assertTrue(dc.touches_sponsord("restart", ["--timeout", "5", "decdn-node"]))

    def test_a_non_loopback_bind_refuses(self) -> None:
        with (
            mock.patch.object(dc, "container_id", return_value="abc"),
            mock.patch.object(dc, "sponsord_metrics_url", return_value=None),
            mock.patch.object(dc, "fetch") as fetch,
        ):
            with self.assertRaises(dc.Refused):
                dc.guard_sponsord(self.args(), "stop")
            fetch.assert_not_called()

    def test_the_probe_follows_the_running_bind(self) -> None:
        env = json.dumps(["PATH=/usr/bin", "SPONSORD_BIND=127.0.0.2:9000", "X=a=b"])
        with mock.patch.object(dc, "run", return_value=subprocess.CompletedProcess([], 0, env)):
            self.assertEqual(dc.sponsord_metrics_url("abc"), "http://127.0.0.2:9000/metrics")
        for bind in ("0.0.0.0:8090", "[::1]:8090", "127.0.0.1", ""):
            self.assertIsNone(dc.bind_metrics_url(bind), bind)


class ContainerEnv(unittest.TestCase):
    def test_unreadable_env_is_empty(self) -> None:
        for out in ("null", "", "not json", '{"a": 1}', '["A=1", 2, "B"]'):
            with (
                self.subTest(out=out),
                mock.patch.object(dc, "run", return_value=subprocess.CompletedProcess([], 0, out)),
            ):
                env = dc.container_env("abc")
            self.assertEqual(env, {"A": "1"} if out.startswith("[") else {})


class Fetch(unittest.TestCase):
    def test_loopback_probes_ignore_a_proxy(self) -> None:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                self.send_response(200)
                self.end_headers()
                self.wfile.write(METRICS_OK.encode())

            def log_message(self, *_) -> None:
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/metrics"
            with mock.patch.dict(os.environ, {"http_proxy": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9"}):
                self.assertEqual(dc.fetch(url), (200, METRICS_OK))
        finally:
            server.shutdown()
            server.server_close()

    def test_nothing_listening_is_status_0(self) -> None:
        server = http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler)
        port = server.server_port
        server.server_close()
        self.assertEqual(dc.fetch(f"http://127.0.0.1:{port}/metrics")[0], 0)


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
            self.assertEqual(argv[argv.index("--progress") + 1], "plain")
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
        self.assertEqual(argv[argv.index("-p") + 1], dc.PROJECT)


class ComposeOverrides(unittest.TestCase):
    def test_load_refuses_them(self) -> None:
        with (
            tempfile.TemporaryDirectory() as tmp,
            mock.patch.object(dc, "DOTENV", Path(tmp) / ".env"),
            mock.patch.dict(os.environ, {"COMPOSE_PROJECT_NAME": "other"}),
        ):
            (Path(tmp) / ".env").write_text("COMPOSE_PROFILES=node\n")
            with self.assertRaises(dc.Refused):
                dc.Project.load()

    def test_every_compose_subprocess_gets_the_scrubbed_environment(self) -> None:
        with (
            mock.patch.dict(os.environ, {"COMPOSE_PROFILES": "x", "DECDN_ENV_FILE": "/x"}),
            mock.patch.object(dc.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "{}")) as run,
        ):
            dc.run(dc.compose_argv("ps"))
            dc.rendered_environments()
        for call in run.call_args_list:
            env = call.kwargs["env"]
            self.assertNotIn("COMPOSE_PROFILES", env)
            self.assertNotIn("DECDN_ENV_FILE", env)

    def test_passthrough_execs_with_the_scrubbed_environment(self) -> None:
        with (
            mock.patch.object(dc, "require_root"),
            mock.patch.object(dc.Project, "load"),
            mock.patch.dict(os.environ, {"DECDN_ENV_FILE": "/x"}),
            mock.patch.object(dc.os, "execvpe") as execvpe,
        ):
            dc.cmd_passthrough(argparse.Namespace(command="logs", rest=["-f"]))
        argv, env = execvpe.call_args.args[1], execvpe.call_args.args[2]
        self.assertEqual(argv[-2:], ["logs", "-f"])
        self.assertNotIn("DECDN_ENV_FILE", env)

    def test_dotenv_may_not_rename_or_reroute_the_project(self) -> None:
        for key in ("COMPOSE_PROJECT_NAME", "COMPOSE_FILE", "COMPOSE_ENV_FILES"):
            with self.subTest(key=key), self.assertRaises(dc.Refused):
                dc.refuse_compose_overrides({"COMPOSE_PROFILES": "node", key: "x"}, {})

    def test_the_shell_may_not_override_dotenv(self) -> None:
        for key in ("COMPOSE_PROFILES", "COMPOSE_PROJECT_NAME", "DECDN_ENV_FILE", "SPONSORD_IMAGE_DIGEST"):
            with self.subTest(key=key), self.assertRaises(dc.Refused) as cm:
                dc.refuse_compose_overrides({"COMPOSE_PROFILES": "node"}, {key: "x", "PATH": "/bin"})
            self.assertIn(key, str(cm.exception))

    def test_an_ordinary_environment_passes(self) -> None:
        dc.refuse_compose_overrides({"COMPOSE_PROFILES": "node"}, {"PATH": "/bin", "HOME": "/root", "LANG": "C"})

    def test_escaped_dollars_are_not_variables(self) -> None:
        names = dc.interpolated_names()
        self.assertIn("DECDN_IMAGE_DIGEST", names)
        self.assertNotIn("ONRAMP_GATE_TEMPLATE", names)  # `$${…}` in the onramp's script

    def test_compose_env_drops_them(self) -> None:
        with mock.patch.dict(os.environ, {"COMPOSE_PROFILES": "x", "DECDN_ENV_FILE": "/x", "KEEP": "1"}):
            env = dc.compose_env({"DECDN_ENV_FILE": "/dev/null"})
        self.assertNotIn("COMPOSE_PROFILES", env)
        self.assertEqual(env["DECDN_ENV_FILE"], "/dev/null")
        self.assertEqual(env["KEEP"], "1")


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

    def test_appends_a_missing_cache_table(self) -> None:
        p = self.tmp / "node.toml"
        p.write_text('[identity]\n# data_dir = "~/.decdn"\n# region = "US"\n')
        with mock.patch.object(dc, "NODE_TOML", p):
            dc.edit_node_toml("DE", cache_node=True)
        self.assertTrue(dc.tomllib.loads(p.read_text())["cache"]["node_to_node_pull_through_enabled"])

    def test_refuses_what_it_cannot_fill_in(self) -> None:
        # A future `config init` that writes region active (or not at all): the
        # edit would silently do nothing, so the result is checked.
        p = self.tmp / "node.toml"
        p.write_text('[identity]\n# data_dir = "~/.decdn"\nregion = "US"\n\n[cache]\n')
        before = p.read_text()
        with mock.patch.object(dc, "NODE_TOML", p), self.assertRaises(dc.Refused) as cm:
            dc.edit_node_toml("DE", cache_node=True)
        self.assertIn("identity.region", str(cm.exception))
        self.assertEqual(p.read_text(), before)

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


class Cli(TmpDir):
    def test_env_file_values_never_reach_argv_or_the_client_env(self) -> None:
        env_file = self.tmp / "decdn.env"
        env_file.write_text(f"DECDN_RPC_URL='https://rpc.example/v2/{KEY}'\nDOCKER_HOST=tcp://evil:2375\n")
        values = dc.parse_env(env_file)
        project = dc.Project({"DECDN_UID": "1", "DECDN_GID": "1", "DECDN_IMAGE_DIGEST": "sha256:" + "a" * 64})
        seen = {}

        def fake_run(argv, **kwargs):
            copy = Path(argv[argv.index("--env-file") + 1])
            seen.update(argv=argv, kwargs=kwargs, text=copy.read_text(), mode=copy.stat().st_mode & 0o777)
            return subprocess.CompletedProcess(argv, 0, "")

        with (
            mock.patch.object(dc, "ensure_image", side_effect=lambda i: i),
            mock.patch.object(dc, "run", side_effect=fake_run),
        ):
            dc.decdn_cli(project, ["whoami"], env_values=values)
        self.assertNotIn(KEY, " ".join(seen["argv"]))
        self.assertNotIn("env", seen["kwargs"])  # the docker client's own environment is untouched
        self.assertEqual(seen["mode"], 0o600)
        # Quotes stripped, as Compose strips them for the daemon, in docker's literal format.
        self.assertIn(f"DECDN_RPC_URL=https://rpc.example/v2/{KEY}\n", seen["text"])
        self.assertFalse(Path(seen["argv"][seen["argv"].index("--env-file") + 1]).exists())

    def test_a_line_break_in_a_value_is_refused(self) -> None:
        project = dc.Project({"DECDN_UID": "1", "DECDN_GID": "1", "DECDN_IMAGE_DIGEST": "sha256:" + "a" * 64})
        with (
            mock.patch.object(dc, "ensure_image", side_effect=lambda i: i),
            mock.patch.object(dc, "run") as run,
            self.assertRaises(dc.Refused),
        ):
            dc.decdn_cli(project, ["whoami"], env_values={"DECDN_RPC_URL": "https://a\nDOCKER_HOST=x"})
        run.assert_not_called()

    def test_node_environment_prefers_the_render(self) -> None:
        with mock.patch.object(dc, "rendered_environments", return_value={"decdn-node": {"DECDN_RPC_URL": "r"}}):
            self.assertEqual(dc.node_environment(dc.Project()), {"DECDN_RPC_URL": "r"})

    def test_rpc_url_comes_from_the_environment(self) -> None:
        text = '[identity]\nregion = "DE"\n\n[blockchain]\nrpc_url = "https://public"\nchain_id = 1\n'
        out = dc.with_env_rpc_url(text)
        self.assertIn('[blockchain]\nrpc_url = "${DECDN_RPC_URL}"\nchain_id = 1\n', out)
        self.assertNotIn("https://public", out)
        self.assertIn('rpc_url = "${DECDN_RPC_URL}"', dc.with_env_rpc_url('[blockchain]\n# rpc_url = "x"\n'))
        self.assertIn('[blockchain]\nrpc_url = "${DECDN_RPC_URL}"', dc.with_env_rpc_url("[identity]\n"))


class Config(unittest.TestCase):
    def test_env_file_values_are_redacted(self) -> None:
        full = {"services": {"sponsord": {"environment": {"SPONSORD_BIND": "127.0.0.1:8090", "SPONSORD_RPC_URL": KEY}}}}
        inline = {"services": {"sponsord": {"environment": {"SPONSORD_BIND": "127.0.0.1:8090"}}}}
        with (
            mock.patch.object(dc, "require_root"),
            mock.patch.object(dc.Project, "load"),
            mock.patch.object(dc, "compose", return_value=subprocess.CompletedProcess([], 0, json.dumps(full))),
            mock.patch.object(dc, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(inline))) as run,
            mock.patch.object(dc, "say") as say,
        ):
            dc.cmd_config(argparse.Namespace(rest=[]))
        out = say.call_args.args[0]
        self.assertNotIn(KEY, out)
        self.assertIn("127.0.0.1:8090", out)
        for key in dc.DEFAULT_ENV_FILES:
            self.assertEqual(run.call_args.kwargs["env"][key], "/dev/null", key)

    def test_every_env_file_is_redactable(self) -> None:
        # cmd_config learns the inline keys by pointing every DEFAULT_ENV_FILES
        # variable at /dev/null: an env_file named any other way would print in clear.
        text = (HERE.parent / "compose.yaml").read_text()
        paths = re.findall(r"(?m)^\s*- path: (.*)$", text)
        self.assertTrue(paths)
        for path in paths:
            m = re.fullmatch(r"\$\{([A-Z_]+):-[^}]+\}", path.strip())
            self.assertIsNotNone(m, path)
            self.assertIn(m[1], dc.DEFAULT_ENV_FILES, path)

    def test_other_arguments_are_refused(self) -> None:
        for rest in (["--environment"], ["--format", "yaml"], ["--no-interpolate"], ["--services", "--environment"]):
            with (
                self.subTest(rest=rest),
                mock.patch.object(dc, "require_root"),
                mock.patch.object(dc.Project, "load"),
                mock.patch.object(dc.os, "execvpe") as execvpe,
                mock.patch.object(dc, "compose") as compose,
            ):
                with self.assertRaises(dc.Refused):
                    dc.cmd_config(argparse.Namespace(rest=rest))
                execvpe.assert_not_called()
                compose.assert_not_called()


class OriginDir(TmpDir):
    def test_checks(self) -> None:
        content = self.tmp / "content"
        content.mkdir()
        self.assertEqual(dc.origin_dir_problems(str(content)), [])
        self.assertTrue(dc.origin_dir_problems("relative/path"))
        self.assertTrue(dc.origin_dir_problems(str(self.tmp / "missing")))
        # Inside, equal to, or containing a protected directory: /var/lib holds
        # decdn/node.secret, which the fs origin would serve.
        for bad in ("/", "/etc", "/etc/ssl", "/proc", "/var", "/var/lib", "/var/lib/decdn/cache"):
            self.assertTrue(dc.origin_dir_problems(bad), bad)
        link = self.tmp / "link"
        link.symlink_to("/etc")
        self.assertTrue(dc.origin_dir_problems(str(link)))

    def test_a_protected_dir_behind_a_symlink_is_still_protected(self) -> None:
        # /var/lib/decdn moved to a data disk behind a symlink: serving the disk
        # would serve the key.
        disk = self.tmp / "data"
        (disk / "decdn").mkdir(parents=True)
        state = self.tmp / "state-link"
        state.symlink_to(disk / "decdn")
        with mock.patch.object(dc, "NOT_ORIGIN", (str(state),)):
            self.assertTrue(dc.origin_dir_problems(str(disk)))
            self.assertEqual(dc.origin_dir_problems(str(self.tmp)), dc.origin_dir_problems(str(self.tmp)))

    def test_the_rendered_mount_is_checked(self) -> None:
        def render(source):
            return {"services": {"decdn-node": {"volumes": [{"target": dc.ORIGIN_TARGET, "source": source}]}}}

        self.assertTrue(dc.rendered_origin_problems(render("/var/lib")))
        self.assertEqual(dc.rendered_origin_problems(render(str(dc.NO_ORIGIN))), [])
        self.assertEqual(dc.rendered_origin_problems({"services": {}}), [])

    def test_init_refuses_an_empty_or_protected_file_origin(self) -> None:
        for origin in ("file://", "file:///var/lib", "file:///"):
            args = argparse.Namespace(
                profiles=["origin"], origin=origin, region="DE", domain=None, chain="x", generate_treasury=False
            )
            with (
                self.subTest(origin=origin),
                mock.patch.object(dc, "require_root"),
                mock.patch.object(dc.shutil, "which", return_value="/usr/bin/docker"),
                mock.patch.object(dc, "NODE_TOML", self.tmp / "absent.toml"),
                mock.patch.object(dc, "DOTENV", self.tmp / ".env"),
                mock.patch.object(dc, "ensure_account", return_value=(1, 1)),
                mock.patch.object(dc, "set_env") as set_env,
                self.assertRaises(dc.Refused),
            ):
                (self.tmp / ".env").write_text("COMPOSE_PROFILES=\n")
                dc.init(args)
            set_env.assert_not_called()


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
        with mock.patch.object(dc, "require_root"), self.assertRaises(dc.Refused):
            dc.init(init_args(["node", "origin"]))

    def test_relay_conflicts_with_the_onramp_and_caddy(self) -> None:
        self.assertEqual(dc.conflicts(["node", "relay"]), [])
        for other in ("onramp", "caddy"):
            with self.subTest(other=other):
                self.assertIn("tcp/80 and tcp/443", dc.conflicts(["relay", other])[0])
                with mock.patch.object(dc, "require_root"), self.assertRaises(dc.Refused) as cm:
                    dc.init(init_args(["relay", other], hostname="relay.example.net", contact="noc@decdn.org"))
                self.assertIn("cannot share a host", str(cm.exception))

    def test_check_refuses_conflicting_profiles(self) -> None:
        found = dc.problems(dc.Project({"COMPOSE_PROFILES": "relay,caddy"}), files_only=True)
        self.assertTrue(any("cannot share a host" in p for p in found), found)

    def test_dns_conflicts_with_every_tcp_443_profile(self) -> None:
        self.assertEqual(dc.conflicts(["origin", "dns"]), [])
        for other in ("relay", "onramp", "caddy"):
            with self.subTest(other=other):
                self.assertIn("tcp/443", dc.conflicts(["dns", other])[0])
                with mock.patch.object(dc, "require_root"), self.assertRaises(dc.Refused) as cm:
                    dc.init(init_args(["dns", other], hostname="dns.example.net", contact="noc@decdn.org"))
                self.assertIn("cannot share a host", str(cm.exception))


def init_args(profiles: list[str], **kw: object) -> argparse.Namespace:
    base = dict(
        profiles=profiles,
        origin=None,
        region="DE",
        domain=None,
        chain="x",
        generate_treasury=False,
        hostname=None,
        contact=None,
        access="allowlist",
        staging=False,
        dns_bind=None,
        public_ipv4=None,
    )
    return argparse.Namespace(**(base | kw))


ID1 = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"


class RelayConfig(TmpDir):
    """The relay's config checks (`check`): iroh-relay itself ignores an unknown key
    and starts on most bad values."""

    def setUp(self) -> None:
        super().setUp()
        self.v6only = self.tmp / "bindv6only"
        self.v6only.write_text("0\n")
        patcher = mock.patch.object(dc, "BINDV6ONLY", self.v6only)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.good = dc.render_relay_toml("relay.example.net", "noc@decdn.org", "everyone", staging=False)

    def problems(self, text: str) -> list[str]:
        p = self.tmp / "iroh-relay.toml"
        p.write_text(text)
        return dc.relay_problems(p)

    def refused(self, text: str, fragment: str) -> None:
        found = self.problems(text)
        self.assertTrue(any(fragment in f for f in found), f"no {fragment!r} in {found}")

    def sub(self, old: str, new: str) -> str:
        """Replace <old> in the first setting (not comment) line that holds it."""
        lines = self.good.splitlines(keepends=True)
        for i, line in enumerate(lines):
            if not line.startswith("#") and old in line:
                lines[i] = line.replace(old, new, 1)
                return "".join(lines)
        self.fail(f"no setting line holds {old!r}")

    def test_rendered_config_passes(self) -> None:
        self.assertEqual(self.problems(self.good), [])
        allow = self.sub('access = "everyone"', f'access = {{ allowlist = [\n  "{ID1}",\n] }}')
        self.assertEqual(self.problems(allow), [])

    def test_render(self) -> None:
        text = dc.render_relay_toml("relay.example.net", "noc@decdn.org", "allowlist", staging=True)
        cfg = dc.tomllib.loads(text)
        self.assertEqual(cfg["access"], {"allowlist": []})
        self.assertIs(cfg["tls"]["prod_tls"], False)
        self.assertEqual(cfg["tls"]["hostname"], "relay.example.net")
        self.assertEqual(cfg["tls"]["cert_dir"], str(dc.RELAY_CERT_DIR))

    def test_example_needs_its_placeholders_and_ids(self) -> None:
        found = self.problems((HERE.parent / "iroh-relay.toml.example").read_text())
        self.assertEqual(len(found), 3, found)
        for fragment in ("hostname is still the example's", "contact is still the example's", "allowlist is empty"):
            self.assertTrue(any(fragment in f for f in found), found)

    def test_unknown_keys(self) -> None:
        self.refused("key_cache_capacty = 10\n" + self.good, "unknown key(s) in the top level: key_cache_capacty")
        self.refused(self.sub("hostname =", "host_name ="), "unknown key(s) in [tls]: host_name")
        self.refused(self.good + "\n[limits]\nconn_limit = 1.0\n", "unknown key(s) in [limits]: conn_limit")

    def test_metrics(self) -> None:
        for addr in ('"0.0.0.0:9092"', '"[::]:9090"', '"127.0.0.1:9100"'):
            # Public, or a loopback port the alloy profile does not scrape.
            self.refused(self.sub('"127.0.0.1:9092"', addr), 'metrics_bind_addr must be "127.0.0.1:9092"')
        self.refused(self.sub("enable_metrics = true", "enable_metrics = false"), "enable_metrics must be true")

    def test_cert_dir(self) -> None:
        self.refused(self.sub('"/var/lib/iroh-relay/acme"', '"/tmp/acme"'), "cert_dir must be")
        self.refused(self.sub('"/var/lib/iroh-relay/acme"', '"/var/lib/iroh-relay/../acme"'), "cert_dir must be")
        self.refused(self.sub('"/var/lib/iroh-relay/acme"', '"/var/lib/iroh-relay"'), "cert_dir must be")

    def test_tls(self) -> None:
        self.refused(self.sub('cert_mode = "LetsEncrypt"', 'cert_mode = "Manual"'), "cert_mode must be")
        self.refused(self.sub('hostname = "relay.example.net"', 'hostname = "https://relay"'), "hostname must be")
        self.refused(self.sub('contact = "noc@decdn.org"', 'contact = "mailto:noc@decdn.org"'), "contact must be")
        self.refused(self.good + "dangerous_http_only = true\n", "dangerous_http_only is not for this profile")
        # Let's Encrypt refuses these (e2e: "contact email has forbidden domain").
        for contact in ("ops@example.net", "ops@mail.example.com", "ops@relay.invalid", "ops@host.test"):
            self.refused(self.sub('contact = "noc@decdn.org"', f'contact = "{contact}"'), "reserved domain")
        self.assertFalse(dc.reserved_mail_domain("ops@notexample.com"))

    def test_access(self) -> None:
        self.refused(self.sub('access = "everyone"', "access = { allowlist = [] }"), "allowlist is empty")
        self.refused(self.sub('access = "everyone"', 'access = { allowlist = ["ABC"] }'), "64 lowercase hex")
        self.refused(self.sub('access = "everyone"', f'access = {{ allowlist = ["{ID1}", "{ID1}"] }}'), "twice")
        self.assertEqual(self.problems(self.sub('access = "everyone"', "access = { denylist = [] }")), [])

    def test_binds(self) -> None:
        self.refused(self.sub('"[::]:443"', '"[::]:8443"'), "must use port 443")
        self.refused(self.sub('http_bind_addr = "[::]:80"', 'http_bind_addr = "127.0.0.1:80"'), "serves no peer")
        self.refused(self.sub('"[::]:7842"', '"relay:7842"'), "is not an address:port")
        self.v6only.write_text("1\n")
        self.refused(self.good, "bindv6only=1")
        v4 = self.good.replace('"[::]:', '"0.0.0.0:')
        self.assertEqual(self.problems(v4), [])

    def test_ports_follow_the_config(self) -> None:
        p = self.tmp / "iroh-relay.toml"
        p.write_text(self.good)
        self.assertEqual(dc.relay_ports(p), (("tcp", 80), ("tcp", 443), ("udp", 7842), ("tcp", 9092)))
        p.write_text(self.sub("enable_quic_addr_discovery = true", "enable_quic_addr_discovery = false"))
        self.assertNotIn(("udp", 7842), dc.relay_ports(p))
        p.write_text("not toml [")
        self.assertEqual(dc.relay_ports(p), dc.PORTS["iroh-relay"])

    def test_keys_match_the_molecule_stub(self) -> None:
        sets = stub_key_sets("iroh-relay", "iroh-relay-stub")
        self.assertEqual(dc.RELAY_KEYS["the top level"], sets["TOP_KEYS"])
        self.assertEqual(dc.RELAY_KEYS["[tls]"], sets["TLS_KEYS"])
        self.assertEqual(dc.RELAY_KEYS["[limits]"], sets["LIMIT_KEYS"])
        self.assertEqual(dc.RELAY_KEYS["[limits.client.rx]"], sets["RX_KEYS"])


class RelayInit(TmpDir):
    def test_needs_hostname_and_contact(self) -> None:
        with mock.patch.object(dc, "RELAY_TOML", self.tmp / "absent.toml"):
            self.assertIn("--hostname", dc.check_relay_args(init_args(["relay"])) or "")
            self.assertIn("--hostname", dc.check_relay_args(init_args(["relay"], hostname="r.example.net")) or "")
            ok = init_args(["relay"], hostname="r.example.net", contact="noc@decdn.org")
            self.assertIsNone(dc.check_relay_args(ok))
            bad = init_args(["relay"], hostname="r.example.net", contact="mailto:noc@decdn.org")
            self.assertIn("--contact", dc.check_relay_args(bad) or "")
            with mock.patch.object(dc, "require_root"), self.assertRaises(dc.Refused):
                dc.init(init_args(["relay"]))

    def test_never_replaces_the_config(self) -> None:
        cfg = self.tmp / "etc" / "iroh-relay.toml"
        cfg.parent.mkdir()
        cfg.write_text("keep")
        with (
            mock.patch.object(dc, "ETC_RELAY", cfg.parent),
            mock.patch.object(dc, "RELAY_TOML", cfg),
            mock.patch.object(dc, "VAR_RELAY", self.tmp / "var"),
            mock.patch.object(dc, "RELAY_CERT_DIR", self.tmp / "var" / "acme"),
            mock.patch.object(dc.os, "chown", lambda *a: None),
        ):
            dc.init_relay(init_args(["relay"], hostname="r.example.net", contact="noc@decdn.org"))
        self.assertEqual(cfg.read_text(), "keep")
        self.assertEqual((self.tmp / "var").stat().st_mode & 0o777, 0o700)


class RelayHealth(TmpDir):
    def run_with(self, prod: bool, tls: str) -> list[tuple[str, bool, str, bool]]:
        p = self.tmp / "iroh-relay.toml"
        p.write_text(dc.render_relay_toml("relay.example.net", "noc@decdn.org", "everyone", staging=not prod))
        with (
            mock.patch.object(dc, "fetch", return_value=(200, "relayserver_accepts_total 0\n")),
            mock.patch.object(dc, "tls_healthz", return_value=tls) as th,
        ):
            out = dc.relay_health(p)
        th.assert_called_once_with("relay.example.net", "127.0.0.1")
        return out

    def test_metrics_and_certificate(self) -> None:
        (_, ok_m, _, _), (_, ok_c, _, warn) = self.run_with(prod=True, tls="ok")
        self.assertTrue(ok_m and ok_c and not warn)

    def test_an_untrusted_production_certificate_fails(self) -> None:
        _, (_, ok, _, warn) = self.run_with(prod=True, tls="certificate verify failed")
        self.assertFalse(ok or warn)

    def test_staging_only_warns(self) -> None:
        _, (_, ok, detail, warn) = self.run_with(prod=False, tls="certificate verify failed")
        self.assertTrue(warn and not ok)
        self.assertIn("staging", detail)


class RestartChecksConfig(TmpDir):
    def test_restart_refuses_a_config_the_service_would_misread(self) -> None:
        bad = lambda: ["iroh-relay.toml: unknown key metrics_bind_adr"]  # noqa: E731
        project = dc.Project({"COMPOSE_PROFILES": "relay"})
        for rest in ([], ["iroh-relay"], ["--timeout", "5"]):
            with (
                self.subTest(rest=rest),
                mock.patch.object(dc, "require_root"),
                mock.patch.object(dc.Project, "load", return_value=project),
                mock.patch.dict(dc.CONFIG_CHECKS, {"iroh-relay": bad}),
                mock.patch.object(dc, "compose") as compose,
                self.assertRaises(dc.Refused),
            ):
                dc.cmd_stopping(argparse.Namespace(command="restart", rest=rest, ignore_topup_hold=False))
            compose.assert_not_called()

    def test_every_iroh_service_is_checked(self) -> None:
        self.assertEqual(set(dc.CONFIG_CHECKS), {"iroh-relay", "iroh-dns-server"})

    def test_restart_of_another_service_skips_it(self) -> None:
        project = dc.Project({"COMPOSE_PROFILES": "node,relay"})
        bad = mock.Mock(return_value=["x"])
        with (
            mock.patch.object(dc, "require_root"),
            mock.patch.object(dc.Project, "load", return_value=project),
            mock.patch.dict(dc.CONFIG_CHECKS, {"iroh-relay": bad}),
            mock.patch.object(dc, "compose") as compose,
        ):
            dc.cmd_stopping(argparse.Namespace(command="restart", rest=["decdn-node"], ignore_topup_hold=False))
        bad.assert_not_called()
        compose.assert_called_once_with("restart", "decdn-node")


class CommandGuard(unittest.TestCase):
    """The guard must run before compose, for every command that can stop sponsord."""

    HELD = METRICS_OK.replace("unix 0", "unix 1700000000")

    def held(self):
        return (
            mock.patch.object(dc, "require_root"),
            mock.patch.object(dc.Project, "load"),
            mock.patch.object(dc, "container_id", return_value="abc"),
            mock.patch.object(dc, "sponsord_metrics_url", return_value=dc.SPONSORD_METRICS),
            mock.patch.object(dc, "fetch", return_value=(200, self.HELD)),
        )

    def test_stop_restart_down_refuse_before_compose(self) -> None:
        for command, rest in (("stop", []), ("restart", ["sponsord"]), ("down", []), ("stop", ["-t", "10"])):
            with self.subTest(command=command, rest=rest), mock.patch.object(dc, "compose") as compose:
                p = self.held()
                with p[0], p[1], p[2], p[3], p[4], self.assertRaises(dc.Refused):
                    dc.cmd_stopping(argparse.Namespace(command=command, rest=rest, ignore_topup_hold=False))
                compose.assert_not_called()

    def test_the_override_lets_it_through(self) -> None:
        with mock.patch.object(dc, "compose") as compose:
            p = self.held()
            with p[0], p[1], p[2], p[3], p[4]:
                dc.cmd_stopping(argparse.Namespace(command="stop", rest=[], ignore_topup_hold=True))
            compose.assert_called_once_with("stop")

    def test_up_refuses_a_recreate_while_held(self) -> None:
        p = self.held()
        with (
            p[2],
            p[3],
            p[4],
            mock.patch.object(dc, "check"),
            mock.patch.object(dc, "up_recreates_sponsord", return_value=True),
            mock.patch.object(dc, "compose") as compose,
        ):
            with self.assertRaises(dc.Refused):
                dc.cmd_up(argparse.Namespace(rest=[], ignore_topup_hold=False))
            compose.assert_not_called()
            dc.cmd_up(argparse.Namespace(rest=["sponsord"], ignore_topup_hold=True))
            compose.assert_called_once_with("up", "-d", "sponsord")

    def test_the_override_flag_goes_before_the_command(self) -> None:
        ns = dc.parser().parse_args(["--ignore-topup-hold", "stop", "-t", "10"])
        self.assertTrue(ns.ignore_topup_hold)
        self.assertEqual(ns.rest, ["-t", "10"])
        # After it, it is Compose's argument: the guard still runs (and Compose
        # refuses the unknown flag), so it is never silently ignored.
        ns = dc.parser().parse_args(["stop", "--ignore-topup-hold"])
        self.assertFalse(ns.ignore_topup_hold)
        self.assertTrue(dc.touches_sponsord("stop", ns.rest))


class InitNeverReplaces(TmpDir):
    def paths(self):
        etc, var = self.tmp / "etc", self.tmp / "var"
        for d in (etc, var):
            d.mkdir(exist_ok=True)
            for f in d.iterdir():
                f.unlink()
        return (
            mock.patch.object(dc, "ETC_DECDN", etc),
            mock.patch.object(dc, "VAR_DECDN", var),
            mock.patch.object(dc, "NODE_PASSWORD", etc / "keystore.password"),
            mock.patch.object(dc, "NODE_TOML", etc / "node.toml"),
            mock.patch.object(dc, "NODE_SECRET", var / "node.secret"),
            mock.patch.object(dc, "NODE_KEYSTORE", var / "keystore.json"),
            mock.patch.object(dc, "NO_ORIGIN", self.tmp / "no-origin" / "x"),
            mock.patch.object(dc, "ensure_dir"),
            mock.patch.object(dc, "install_template"),
        )

    def run_init_node(self, *present: str) -> mock.MagicMock:
        uid, gid = os.geteuid(), os.getegid()
        project = dc.Project({"DECDN_UID": str(uid), "DECDN_GID": str(gid)})
        args = argparse.Namespace(chain="arbitrum-sepolia", region="DE")
        p = self.paths()
        with p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], mock.patch.object(dc, "decdn_cli") as cli:
            (self.tmp / "etc" / "node.toml").write_text("x")  # config init is not under test here
            for name in present:
                (self.tmp / "var" / name).write_text("keep")
            try:
                dc.init_node(project, args, None)
            finally:
                for name in present:
                    self.assertEqual((self.tmp / "var" / name).read_text(), "keep")
        return cli

    def test_a_half_identity_is_refused(self) -> None:
        for name in ("node.secret", "keystore.json"):
            with self.subTest(present=name), self.assertRaises(dc.Refused):
                self.run_init_node(name)

    def test_an_existing_identity_is_kept(self) -> None:
        cli = self.run_init_node("node.secret", "keystore.json")
        cli.assert_not_called()

    def test_the_treasury_is_never_regenerated(self) -> None:
        for present in (
            ("treasury-password",),
            ("treasury-keystore.json",),
            ("treasury-password", "treasury-keystore.json"),
        ):
            with (
                self.subTest(present=present),
                tempfile.TemporaryDirectory() as tmp,
                mock.patch.object(dc, "SD_KEYSTORE", Path(tmp) / "treasury-keystore.json"),
                mock.patch.object(dc, "SD_PASSWORD", Path(tmp) / "treasury-password"),
                mock.patch.object(dc, "run") as run,
            ):
                for name in present:
                    (Path(tmp) / name).write_text("keep")
                dc.generate_treasury(dc.Project(), os.geteuid(), os.getegid())
                run.assert_not_called()
                for name in present:
                    self.assertEqual((Path(tmp) / name).read_text(), "keep")


class SecretFileChecks(unittest.TestCase):
    """problems() checks every secret file private (and env files root-owned)."""

    def test_every_secret_is_checked_private(self) -> None:
        seen: dict[str, tuple] = {}

        def record(path, uid, *, private=True, nonempty=True, what=""):
            seen[str(path)] = (uid, private)
            return None

        project = dc.Project(
            {
                "COMPOSE_PROFILES": "node,onramp,caddy",
                "DECDN_UID": "1",
                "DECDN_GID": "1",
                "SPONSORD_UID": "2",
                "SPONSORD_GID": "2",
                "CADDY_UID": "3",
                "CADDY_GID": "3",
                "SPONSORD_ONRAMP_DOMAIN": "onramp.decdn.org",
            }
        )
        with (
            mock.patch.object(dc, "file_problem", side_effect=record),
            mock.patch.object(dc, "rendered_environments", return_value={}),
            mock.patch.object(dc.pwd, "getpwnam", side_effect=KeyError),
            mock.patch.object(dc, "origin_dir_problems", return_value=[]),
        ):
            dc.problems(project, files_only=True)
        private = [
            dc.NODE_PASSWORD,
            dc.NODE_SECRET,
            dc.NODE_KEYSTORE,
            dc.SD_TOKEN,
            dc.SD_KEYSTORE,
            dc.SD_PASSWORD,
            dc.SD_TURNSTILE,
        ]
        for p in private:
            self.assertTrue(seen[str(p)][1], p)
        for key in ("DECDN_ENV_FILE", "SPONSORD_SECRET_ENV_FILE"):
            path = dc.DEFAULT_ENV_FILES[key]
            self.assertEqual(seen[path], (0, True), path)
        for key in ("SPONSORD_ENV_FILE", "SPONSORD_ONRAMP_ENV_FILE"):
            path = dc.DEFAULT_ENV_FILES[key]
            self.assertEqual(seen[path], (0, False), path)

    def run_problems(self, profiles: str, rendered: dict) -> list[str]:
        project = dc.Project(
            {
                "COMPOSE_PROFILES": profiles,
                "SPONSORD_UID": "2",
                "SPONSORD_GID": "2",
                "SPONSORD_ONRAMP_DOMAIN": "onramp.decdn.org",
            }
        )
        with (
            mock.patch.object(dc, "file_problem", return_value=None),
            mock.patch.object(dc, "rendered_environments", return_value=rendered),
            mock.patch.object(dc.pwd, "getpwnam", side_effect=KeyError),
            mock.patch.object(Path, "exists", return_value=True),
            mock.patch.object(dc, "parse_env", return_value={}),
        ):
            return dc.problems(project, files_only=True)

    def test_the_onramp_rpc_url_is_public(self) -> None:
        base = {"ONRAMP_CAPACITY_BOND_ADDR": "0x1", "ONRAMP_TURNSTILE_SITEKEY": "k"}
        for url, ok in (
            ("https://h/v2", True),
            (f"https://u:{KEY}@h/", False),
            (f"https://h/?key={KEY}", False),
            (f"https://h/#{KEY}", False),
        ):
            with self.subTest(url=url):
                found = self.run_problems("onramp", {"sponsord-onramp": base | {"ONRAMP_RPC_URL": url}})
                self.assertEqual(not any("ONRAMP_RPC_URL must be" in f for f in found), ok)

    def test_values_come_from_the_render(self) -> None:
        # A value Compose renders empty (an unset ${VAR}) is missing, whatever the file says.
        found = self.run_problems("sponsord", {"sponsord": {"SPONSORD_RPC_URL": "", "SPONSORD_CHAIN_ID": "1"}})
        self.assertTrue(any("set SPONSORD_RPC_URL" in f for f in found))

    def test_a_uid_that_is_not_the_accounts_is_flagged(self) -> None:
        project = dc.Project({"COMPOSE_PROFILES": "caddy", "CADDY_UID": "0", "CADDY_GID": "0"})
        account = mock.Mock(pw_uid=997)
        with (
            mock.patch.object(dc, "rendered_environments", return_value={}),
            mock.patch.object(dc.pwd, "getpwnam", return_value=account),
        ):
            found = dc.problems(project, files_only=True)
        self.assertTrue(any("CADDY_UID=0" in f for f in found))


class Backup(TmpDir):
    def test_covers_every_key_and_secret(self) -> None:
        project = dc.Project({"COMPOSE_PROFILES": "node,onramp"})
        paths = set(map(str, dc.backup_paths(project)))
        for p in (
            dc.NODE_SECRET,
            dc.NODE_KEYSTORE,
            dc.NODE_PASSWORD,
            dc.SD_KEYSTORE,
            dc.SD_PASSWORD,
            dc.SD_TOKEN,
            dc.SD_TURNSTILE,
        ):
            self.assertIn(str(p), paths)
        for key in ("DECDN_ENV_FILE", "SPONSORD_SECRET_ENV_FILE", "SPONSORD_ENV_FILE", "SPONSORD_ONRAMP_ENV_FILE"):
            self.assertIn(dc.DEFAULT_ENV_FILES[key], paths)

    def test_an_incomplete_set_is_refused(self) -> None:
        present = self.tmp / "present"
        present.write_text("x")
        with (
            mock.patch.object(dc, "require_root"),
            mock.patch.object(dc.Project, "load", return_value=dc.Project({"COMPOSE_PROFILES": "node"})),
            mock.patch.object(dc.shutil, "which", return_value="/usr/bin/age"),
            mock.patch.object(dc, "backup_paths", return_value=[present, self.tmp / "missing"]),
            mock.patch.object(dc.subprocess, "Popen") as popen,
        ):
            with self.assertRaises(dc.Refused) as cm:
                dc.cmd_backup(argparse.Namespace(recipient=["age1x"], output=str(self.tmp / "out.age")))
            popen.assert_not_called()
        self.assertIn("missing", str(cm.exception))
        self.assertFalse((self.tmp / "out.age").exists())


class Ports(unittest.TestCase):
    def test_a_failing_ss_is_refused_not_empty(self) -> None:
        with (
            mock.patch.object(dc.shutil, "which", return_value="/usr/bin/ss"),
            mock.patch.object(dc, "run", return_value=subprocess.CompletedProcess([], 1, "")),
            self.assertRaises(dc.Refused),
        ):
            dc.listeners()


class InstallTemplate(TmpDir):
    def test_a_dangling_symlink_is_refused(self) -> None:
        dst = self.tmp / "decdn.env"
        dst.symlink_to(self.tmp / "nowhere")
        with self.assertRaises(dc.Refused):
            dc.install_template("decdn.env.example", dst, 0o600)
        self.assertFalse((self.tmp / "nowhere").exists())


def stub_key_sets(scenario: str, stub: str) -> dict[str, set[str]]:
    """The *_KEYS sets a role's molecule stub enforces."""
    import ast

    path = HERE.parent.parent / "ansible" / "molecule" / scenario / "files" / stub
    return {
        t.id: ast.literal_eval(node.value)
        for node in ast.parse(path.read_text()).body
        if isinstance(node, ast.Assign) and isinstance(node.value, ast.Set)
        for t in node.targets
        if isinstance(t, ast.Name) and t.id.endswith("_KEYS")
    }


class DnsConfig(TmpDir):
    """The DNS server's config checks (`check`)."""

    def setUp(self) -> None:
        super().setUp()
        self.v6only = self.tmp / "bindv6only"
        self.v6only.write_text("0\n")
        patcher = mock.patch.object(dc, "BINDV6ONLY", self.v6only)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.good = dc.render_dns_toml("dns.example.net", "noc@decdn.org", "198.51.100.7", "203.0.113.10", False)

    def problems(self, text: str) -> list[str]:
        p = self.tmp / "config.toml"
        p.write_text(text)
        return dc.dns_problems(p)

    def refused(self, text: str, fragment: str) -> None:
        found = self.problems(text)
        self.assertTrue(any(fragment in f for f in found), f"no {fragment!r} in {found}")

    def sub(self, old: str, new: str) -> str:
        """Replace <old> in the first setting (not comment) line that holds it."""
        lines = self.good.splitlines(keepends=True)
        for i, line in enumerate(lines):
            if not line.startswith("#") and old in line:
                lines[i] = line.replace(old, new, 1)
                return "".join(lines)
        self.fail(f"no setting line holds {old!r}")

    def test_rendered_config_passes(self) -> None:
        self.assertEqual(self.problems(self.good), [])
        cfg = dc.tomllib.loads(self.good)
        self.assertEqual(cfg["dns"]["origins"], ["dns.example.net.", "."])
        self.assertEqual(cfg["dns"]["bind_addr"], "198.51.100.7")
        self.assertEqual(cfg["https"]["domains"], ["dns.example.net"])
        self.assertEqual(cfg["data_dir"], str(dc.VAR_DNS))

    def test_render_without_a_public_address_leaves_rr_a_out(self) -> None:
        text = dc.render_dns_toml("dns.example.net", "noc@decdn.org", "10.0.0.5", None, True)
        cfg = dc.tomllib.loads(text)
        self.assertNotIn("rr_a", cfg["dns"])
        self.assertIs(cfg["https"]["letsencrypt_prod"], False)
        self.refused(text, "no rr_a")

    def test_example_needs_its_placeholders(self) -> None:
        found = self.problems((HERE.parent / "iroh-dns-server.toml.example").read_text())
        for fragment in ("domains is still", "letsencrypt_contact is still", "bind_addr is still", "rr_a is still"):
            self.assertTrue(any(fragment in f for f in found), (fragment, found))

    def test_unknown_keys(self) -> None:
        self.refused("dataa_dir = 1\n" + self.good, "unknown key(s) at the top level: dataa_dir")
        self.refused(self.sub("default_ttl = 30", "default_ttl = 30\nttl = 5"), "unknown key(s) in [dns]: ttl")
        self.refused(
            self.sub("letsencrypt_prod = true", "letsencrypt_prod = true\ncontact = 'x'"), "in [https]: contact"
        )

    def test_origins(self) -> None:
        self.refused(self.sub('["dns.example.net.", "."]', '["dns.example.net", "."]'), "trailing dot")
        self.refused(self.sub('["dns.example.net.", "."]', '["dns.example.net."]'), 'must include "."')
        self.refused(self.sub('["dns.example.net.", "."]', '["other.example.net.", "."]'), "do not cover the hostname")

    def test_rate_limit(self) -> None:
        self.refused(self.sub('"simple"', '"smart"'), "X-Forwarded-For")
        self.assertEqual(self.problems(self.sub('"simple"', '"disabled"')), [])

    def test_loopback_listeners(self) -> None:
        self.refused(self.sub('bind_addr = "127.0.0.1"', 'bind_addr = "0.0.0.0"'), "[http] bind_addr must be loopback")
        self.refused(self.sub('"127.0.0.1:9117"', '"0.0.0.0:9117"'), "[metrics] bind_addr must be loopback")
        self.refused(self.sub("disabled = false", "disabled = true"), "[metrics] disabled must be false")

    def test_addresses(self) -> None:
        self.refused(self.sub('rr_a = "203.0.113.10"', 'rr_a = "10.1.2.3"'), "is private")
        self.refused(self.sub('rr_a = "203.0.113.10"', 'rr_a = "2001:db8::1"'), "must be a public IPv4")
        self.refused(self.sub('bind_addr = "198.51.100.7"', 'bind_addr = "127.0.0.1"'), "serves no peer")
        self.v6only.write_text("1\n")
        self.refused(self.good, "bindv6only=1")
        self.assertEqual(self.problems(self.sub('bind_addr = "::"', 'bind_addr = "0.0.0.0"')), [])

    def test_tls_and_state(self) -> None:
        self.refused(self.sub('"noc@decdn.org"', '"ops@example.com"'), "reserved domain")
        self.refused(self.sub('cert_mode = "lets_encrypt"', 'cert_mode = "manual"'), "cert_mode must be")
        self.refused(self.sub('data_dir = "/var/lib/iroh-dns-server"', 'data_dir = "/tmp/dns"'), "data_dir must be")
        self.refused(self.sub("port = 443", "port = 8443"), "[https] port must be 443")

    def test_keys_match_the_molecule_stub(self) -> None:
        sets = stub_key_sets("iroh-dns-server", "iroh-dns-server-stub")
        names = {"TOP_KEYS": "the top level", "HTTP_KEYS": "[http]", "HTTPS_KEYS": "[https]", "DNS_KEYS": "[dns]"}
        names |= {"METRICS_KEYS": "[metrics]", "MAINLINE_KEYS": "[mainline]", "STORE_KEYS": "[zone_store]"}
        self.assertEqual(set(sets), set(names))
        for stub_name, section in names.items():
            self.assertEqual(dc.DNS_KEYS[section], sets[stub_name], section)


class DnsPorts(unittest.TestCase):
    SS = (
        'udp UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=13))\n'
        'tcp LISTEN 0 4096 127.0.0.54:53 0.0.0.0:* users:(("systemd-resolve",pid=1,fd=14))\n'
        'tcp LISTEN 0 4096 [::]:22 [::]:* users:(("sshd",pid=2,fd=3))\n'
    )

    def test_rows(self) -> None:
        rows = dc.listener_rows(self.SS)
        self.assertEqual(rows[0], ("udp", "127.0.0.53%lo", 53, "systemd-resolve"))
        self.assertEqual(rows[2], ("tcp", "[::]", 22, "sshd"))

    def test_the_resolved_stub_is_fine_beside_one_address(self) -> None:
        self.assertEqual(dc.dns_port_problems("198.51.100.7", dc.listener_rows(self.SS)), [])

    def test_a_wildcard_bind_names_the_stub(self) -> None:
        found = dc.dns_port_problems("::", dc.listener_rows(self.SS))
        self.assertEqual(len(found), 2)
        self.assertIn("DNSStubListener=no", found[0])

    def test_a_holder_on_the_bind_address_or_a_wildcard(self) -> None:
        rows = dc.listener_rows(
            'udp UNCONN 0 0 198.51.100.7:53 0.0.0.0:* users:(("dnsmasq",pid=3,fd=4))\n'
            'tcp LISTEN 0 64 *:53 *:* users:(("named",pid=4,fd=5))\n'
        )
        found = dc.dns_port_problems("198.51.100.7", rows)
        self.assertEqual(len(found), 2)
        self.assertIn("dnsmasq", found[0])

    def test_port_53_is_left_to_the_address_aware_check(self) -> None:
        self.assertNotIn(53, [p for _, p in dc.service_ports("iroh-dns-server")])


class DnsInit(TmpDir):
    def test_inputs(self) -> None:
        with mock.patch.object(dc, "DNS_TOML", self.tmp / "absent.toml"):
            self.assertIn("--hostname", dc.check_dns_args(init_args(["dns"])) or "")
            ok = dict(hostname="dns.example.net", contact="noc@decdn.org")
            self.assertIsNone(dc.check_dns_args(init_args(["dns"], **ok)))
            self.assertIn("--dns-bind", dc.check_dns_args(init_args(["dns"], dns_bind="::1", **ok)) or "")
            self.assertIn("--dns-bind", dc.check_dns_args(init_args(["dns"], dns_bind="dns", **ok)) or "")
            self.assertIn("private", dc.check_dns_args(init_args(["dns"], public_ipv4="10.0.0.1", **ok)) or "")
            self.assertIn(
                "reserved", dc.check_dns_args(init_args(["dns"], hostname="d.example.net", contact="a@b.test")) or ""
            )

    def test_writes_once_with_a_public_bind_as_rr_a(self) -> None:
        etc = self.tmp / "etc"
        with (
            mock.patch.object(dc, "ETC_DNS", etc),
            mock.patch.object(dc, "DNS_TOML", etc / "config.toml"),
            mock.patch.object(dc, "VAR_DNS", self.tmp / "var"),
            mock.patch.object(dc.os, "chown", lambda *a: None),
            mock.patch.object(dc, "write_new", lambda p, data, *a: p.write_bytes(data) or True),
        ):
            dc.init_dns(init_args(["dns"], hostname="dns.example.net", contact="noc@decdn.org", dns_bind="8.8.4.4"))
            cfg = dc.tomllib.loads((etc / "config.toml").read_text())
            self.assertEqual(cfg["dns"]["rr_a"], "8.8.4.4")
            dc.init_dns(init_args(["dns"], hostname="other.example.net", contact="noc@decdn.org"))
            self.assertIn("dns.example.net", (etc / "config.toml").read_text())
        self.assertEqual((self.tmp / "var").stat().st_mode & 0o777, 0o700)


class DnsHealth(TmpDir):
    def run_with(self, body: str, prod: bool = True, dig: str | None = "dns.example.net.", pinned: bool = True):
        p = self.tmp / "config.toml"
        p.write_text(dc.render_dns_toml("dns.example.net", "noc@decdn.org", "198.51.100.7", "203.0.113.10", not prod))
        with (
            mock.patch.object(dc, "fetch", return_value=(200, body)),
            mock.patch.object(dc, "tls_healthz", return_value="certificate verify failed"),
            mock.patch.object(dc.shutil, "which", return_value=None if dig is None else "/usr/bin/dig"),
            mock.patch.object(dc, "dig_soa", return_value=dig) as ds,
        ):
            out = dc.dns_health(p, pinned)
        return {name: (ok, detail, warn) for name, ok, detail, warn in out}, ds

    def test_version_soa_and_staging(self) -> None:
        out, ds = self.run_with(f'{{"status":"ok","version":"{dc.DNS_VERSION}"}}', prod=False)
        self.assertTrue(out["iroh-dns-server"][0])
        self.assertTrue(out["iroh-dns-server SOA dns.example.net. udp"][0])
        self.assertTrue(out["iroh-dns-server SOA dns.example.net. tcp"][0])
        ds.assert_any_call("dns.example.net.", "198.51.100.7", True)
        ok, _, warn = out["iroh-dns-server certificate"]
        self.assertTrue(warn and not ok)

    def test_another_version_fails_only_on_the_pinned_image(self) -> None:
        out, _ = self.run_with('{"status":"ok","version":"9.9.9"}')
        self.assertFalse(out["iroh-dns-server"][0])
        out, _ = self.run_with('{"status":"ok","version":"9.9.9"}', pinned=False)
        self.assertTrue(out["iroh-dns-server"][0])

    def test_a_wrong_soa_fails_and_no_dig_warns(self) -> None:
        out, _ = self.run_with(f'{{"version":"{dc.DNS_VERSION}"}}', dig="no answer")
        self.assertFalse(out["iroh-dns-server SOA dns.example.net. udp"][0])
        out, _ = self.run_with(f'{{"version":"{dc.DNS_VERSION}"}}', dig=None)
        self.assertEqual(out["iroh-dns-server DNS"][2], True)
        ok, _, warn = out["iroh-dns-server certificate"]
        self.assertFalse(ok or warn)


if __name__ == "__main__":
    unittest.main()
