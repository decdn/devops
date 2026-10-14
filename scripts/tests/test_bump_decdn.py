"""Unit tests for scripts/bump_decdn.py, the file rewrites behind
scripts/open-decdn-bump.sh (`make test-scripts` runs them).

    python3 -m unittest discover -s scripts/tests -p 'test_*.py'

Each test runs on a throwaway git repository holding copies of this repo's real pin
files, so a reshaped pin file fails here before it fails a bump.
"""

from __future__ import annotations

import importlib.util
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
_spec = importlib.util.spec_from_file_location("bump_decdn", HERE.parent / "bump_decdn.py")
bd = importlib.util.module_from_spec(_spec)
sys.modules["bump_decdn"] = bd
_spec.loader.exec_module(bd)

FILES = [
    bd.NODE_DEFAULTS,
    bd.ONRAMP_DEFAULTS,
    bd.ONRAMP_ENV,
    bd.COMPOSE_ENV,
    bd.CHART,
    bd.CHART_VALUES,
    *dict.fromkeys(rel for rel, _, _ in bd.EXAMPLES),
    bd.AGENTS[0],
]
# rewrite never touches these: release.sh writes them.
CHANGELOGS = [
    "ansible/galaxy/node/CHANGELOG.md",
    "ansible/galaxy/publisher/CHANGELOG.md",
    "charts/decdn-node/CHANGELOG.md",
]
SUMS = "a" * 64
DIGEST = "sha256:" + "b" * 64


def flat(text: str) -> str:
    """Whitespace runs as single spaces: AGENTS.md's wrapping is not the test's concern."""
    return " ".join(text.split())


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        for rel in FILES + CHANGELOGS:
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / rel, self.root / rel)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        self.original = {rel: (self.root / rel).read_text() for rel in FILES}
        self.line = bd.pinned(self.root)
        self.version = bd.synced(self.root)
        self.sums = bd.env_value(self.text(bd.ONRAMP_ENV), "ONRAMP_DECDN_SUMS_SHA256", bd.ONRAMP_ENV)
        self.digest = bd.env_value(self.text(bd.COMPOSE_ENV), "DECDN_IMAGE_DIGEST", bd.COMPOSE_ENV)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def text(self, rel: str) -> str:
        return (self.root / rel).read_text()

    def write(self, rel: str, text: str) -> None:
        (self.root / rel).write_text(text)

    def next_patch(self) -> str:
        major, minor, patch = (int(p) for p in self.version.split("."))
        return f"{major}.{minor}.{patch + 1}"


class Compare(Fixture):
    def test_the_synced_release_is_in_the_line(self) -> None:
        self.assertEqual(self.version.rsplit(".", 1)[0], self.line)

    def test_relations(self) -> None:
        major, minor, _ = (int(p) for p in self.version.split("."))
        self.assertEqual(bd.compare(self.root, f"v{self.version}"), "same")
        self.assertEqual(bd.compare(self.root, f"v{self.next_patch()}"), "behind")
        self.assertEqual(bd.compare(self.root, f"v{major}.{minor + 1}.0"), "behind")

    def test_numeric_not_lexical(self) -> None:
        self.write(bd.COMPOSE_ENV, self.text(bd.COMPOSE_ENV).replace(
            f"# decdn/decdn v{self.version}\n", "# decdn/decdn v0.0.9\n"))
        self.assertEqual(bd.compare(self.root, "v0.0.10"), "behind")
        self.assertEqual(bd.compare(self.root, "v0.0.8"), "ahead")

    def test_kind(self) -> None:
        major, minor, _ = (int(p) for p in self.version.split("."))
        self.assertEqual(bd.kind(self.root, f"v{self.next_patch()}"), "patch")
        self.assertEqual(bd.kind(self.root, f"v{major}.{minor + 1}.0"), "line")
        self.assertEqual(bd.kind(self.root, f"v{major + 1}.{minor}.0"), "line")

    def test_refuses_a_non_release_tag(self) -> None:
        for tag in ("0.0.3", "v0.0.3-rc.1", "v1.2"):
            with self.subTest(tag=tag), self.assertRaises(bd.ShapeError):
                bd.compare(self.root, tag)
            with self.subTest(tag=tag), self.assertRaises(bd.ShapeError):
                bd.kind(self.root, tag)

    def test_refuses_an_exact_role_pin(self) -> None:
        self.write(bd.NODE_DEFAULTS, self.text(bd.NODE_DEFAULTS).replace(
            f'decdn_node_version: "{self.line}"', f'decdn_node_version: "{self.version}"'))
        with self.assertRaisesRegex(bd.ShapeError, "not a release line"):
            bd.pinned(self.root)


class Rewrite(Fixture):
    def assert_exact_copies(self, version: str, sums: str, digest: str) -> None:
        self.assertIn(f"ONRAMP_DECDN_RELEASE=v{version}\n", self.text(bd.ONRAMP_ENV))
        self.assertIn(f"last moved:\n# decdn/decdn v{version}.\n", self.text(bd.ONRAMP_ENV))
        self.assertIn(f"ONRAMP_DECDN_SUMS_SHA256={sums}\n", self.text(bd.ONRAMP_ENV))
        self.assertIn(f"# decdn/decdn v{version}\nDECDN_IMAGE_DIGEST={digest}\n", self.text(bd.COMPOSE_ENV))
        self.assertIn(f"e.g. for v{version}\n  # {digest}\n", self.text(bd.CHART_VALUES))
        for tree in ("ansible/inventory", "examples/collection-fleet/inventory"):
            for host in ("decdn-node-1", "origin-1"):
                host_vars = self.text(f"{tree}/host_vars/{host}/main.yml")
                self.assertIn(f'\n# decdn_node_version: "{version}"\n', host_vars)
                self.assertIn(f" decdn_node_source_ref: v{version}\n", host_vars)
            self.assertIn(f"\n# sponsord_onramp_decdn_release: v{version}\n",
                          self.text(f"{tree}/group_vars/sponsord_onramp_hosts.yml"))
        self.assertIn(f'# sponsord_onramp_decdn_release: "v{version}"\n',
                      self.text("cloud-init/user-data-publisher.yaml"))

    def assert_line_copies(self, line: str) -> None:
        self.assertEqual(bd.pinned(self.root), line)
        self.assertIn(f"sponsord_onramp_decdn_release: v{line} ", self.text(bd.ONRAMP_DEFAULTS))
        self.assertIn(f'appVersion: "{line}"', self.text(bd.CHART))
        self.assertIn(f"image: ghcr.io/decdn/decdn-node:{line}\n", self.text(bd.CHART))
        self.assertIn(f"`decdn_node_version`, today `{line}`)", flat(self.text("AGENTS.md")))

    def test_a_new_line_moves_every_pin(self) -> None:
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        self.assert_line_copies("9.8")
        self.assert_exact_copies("9.8.7", SUMS, DIGEST)
        self.assertEqual(bd.synced(self.root), "9.8.7")

    def test_a_patch_leaves_the_line(self) -> None:
        line_files = (bd.NODE_DEFAULTS, bd.ONRAMP_DEFAULTS, bd.CHART, "AGENTS.md")
        changed = bd.rewrite(self.root, self.next_patch(), SUMS, DIGEST)
        for rel in line_files:
            with self.subTest(rel=rel):
                self.assertNotIn(rel, changed)
                self.assertEqual(self.text(rel), self.original[rel])
        self.assert_line_copies(self.line)
        self.assert_exact_copies(self.next_patch(), SUMS, DIGEST)

    def test_round_trip_is_byte_identical(self) -> None:
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        bd.rewrite(self.root, self.version, self.sums, self.digest)
        for rel in FILES:
            with self.subTest(rel=rel):
                self.assertEqual(self.text(rel), self.original[rel])

    def test_leaves_the_sponsord_pin(self) -> None:
        onramp = self.text(bd.ONRAMP_DEFAULTS)
        sponsord = bd.scalar(onramp, "sponsord_onramp_version", bd.ONRAMP_DEFAULTS)
        agents = self.text("AGENTS.md")
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        self.assertEqual(bd.scalar(self.text(bd.ONRAMP_DEFAULTS), "sponsord_onramp_version",
                                   bd.ONRAMP_DEFAULTS), sponsord)
        # AGENTS.md names both pins in one sentence; only decdn's moves.
        sponsord_today = f"`sponsord_onramp_version`, today `{sponsord}`;"
        self.assertIn(sponsord_today, flat(agents))
        self.assertIn(sponsord_today, flat(self.text("AGENTS.md")))

    def test_moves_agents_md_wrapped_either_way(self) -> None:
        original = self.text("AGENTS.md")
        for sep in (" ", "\n"):
            with self.subTest(sep=sep):
                text, n = re.subn(r"(`decdn_node_version`, today)\s+`", rf"\g<1>{sep}`", original)
                self.assertEqual(n, 1)
                self.write("AGENTS.md", text)
                bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
                self.assertIn(f"`decdn_node_version`, today{sep}`9.8`", self.text("AGENTS.md"))
                bd.rewrite(self.root, self.version, self.sums, self.digest)

    def test_leaves_the_changelogs(self) -> None:
        image = self.digest.removeprefix("sha256:")
        for rel in CHANGELOGS:
            self.write(rel, self.text(rel) + f"\n{self.sums}\n{image}\n")
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        for rel in CHANGELOGS:
            self.assertIn(self.sums, self.text(rel))
            self.assertIn(image, self.text(rel))

    def test_refuses_a_reshaped_file(self) -> None:
        self.write(bd.COMPOSE_ENV, self.text(bd.COMPOSE_ENV).replace(f"# decdn/decdn v{self.version}\n", ""))
        with self.assertRaisesRegex(bd.ShapeError, "compose/.env.example: 0 matches"):
            bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)

    def test_refuses_a_second_pin_line(self) -> None:
        self.write(bd.CHART, self.text(bd.CHART) + f'appVersion: "{self.line}"\n')
        with self.assertRaisesRegex(bd.ShapeError, "2 matches"):
            bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)

    def test_refuses_bad_arguments(self) -> None:
        for args in (("9.8", SUMS, DIGEST), ("9.8.7", "A" * 64, DIGEST), ("9.8.7", SUMS, "b" * 64)):
            with self.subTest(args=args), self.assertRaises(bd.ShapeError):
                bd.rewrite(self.root, *args)

    def test_refuses_a_digest_beside_the_line(self) -> None:
        # The role reads a line's digest from the release; a default one would be stale.
        self.write(bd.ONRAMP_DEFAULTS, self.text(bd.ONRAMP_DEFAULTS).replace(
            'sponsord_onramp_decdn_sums_sha256: "" ', f'sponsord_onramp_decdn_sums_sha256: {self.sums} '))
        with self.assertRaisesRegex(bd.ShapeError, "sponsord_onramp_decdn_sums_sha256"):
            bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)

    def test_refuses_a_second_artifacthub_image(self) -> None:
        # Not a version the anchored edit moves, so only the read-back sees it.
        self.write(bd.CHART, self.text(bd.CHART) + "#     image: ghcr.io/decdn/decdn-node:latest\n")
        with self.assertRaisesRegex(bd.ShapeError, "artifacthub.io/images"):
            bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)

    def test_refuses_a_drifted_chart_example(self) -> None:
        bare = self.digest.removeprefix("sha256:")
        self.write(bd.CHART_VALUES, self.text(bd.CHART_VALUES).replace(bare, "d" * 64))
        with self.assertRaisesRegex(bd.ShapeError, "example digest"):
            bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)

    def test_refuses_an_empty_current_digest_without_writing(self) -> None:
        # Replacing "" would rewrite every tracked file.
        self.write(bd.COMPOSE_ENV, self.text(bd.COMPOSE_ENV).replace(
            f"DECDN_IMAGE_DIGEST={self.digest}", "DECDN_IMAGE_DIGEST="))
        before = {rel: self.text(rel) for rel in FILES}
        with self.assertRaisesRegex(bd.ShapeError, "is not a digest"):
            bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        for rel in FILES:
            self.assertEqual(self.text(rel), before[rel])

    def test_skips_binary_and_refuses_undecodable_files(self) -> None:
        (self.root / "logo.bin").write_bytes(b"\0" + self.sums.encode())
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        self.assertEqual((self.root / "logo.bin").read_bytes(), b"\0" + self.sums.encode())

        (self.root / "notes.txt").write_bytes(b"\xff" + SUMS.encode())
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        with self.assertRaisesRegex(bd.ShapeError, "notes.txt: not UTF-8"):
            bd.rewrite(self.root, "1.2.3", "e" * 64, DIGEST)


class Cli(Fixture):
    """open-decdn-bump.sh reads stdout and the exit code; a refusal must exit 1."""

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HERE.parent / "bump_decdn.py"), "--root", str(self.root), *args],
            capture_output=True, text=True, check=False,
        )

    def test_pinned_synced_compare_and_kind_print_one_word(self) -> None:
        self.assertEqual(self.run_cli("pinned").stdout, f"{self.line}\n")
        self.assertEqual(self.run_cli("synced").stdout, f"{self.version}\n")
        r = self.run_cli("compare", "v99.0.0")
        self.assertEqual((r.returncode, r.stdout), (0, "behind\n"))
        r = self.run_cli("kind", "v99.0.0")
        self.assertEqual((r.returncode, r.stdout), (0, "line\n"))

    def test_a_refusal_exits_1(self) -> None:
        self.write(bd.COMPOSE_ENV, self.text(bd.COMPOSE_ENV).replace(f"# decdn/decdn v{self.version}\n", ""))
        r = self.run_cli("rewrite", "9.8.7", "--sums-sha256", SUMS, "--image-digest", DIGEST)
        self.assertEqual(r.returncode, 1)
        self.assertTrue(r.stderr.startswith("bump_decdn: "), r.stderr)
        self.assertEqual(self.run_cli("compare", "v1.2").returncode, 1)
        self.assertEqual(self.run_cli("kind", "v1.2").returncode, 1)

    def test_usage_exits_2(self) -> None:
        self.assertEqual(self.run_cli().returncode, 2)
        self.assertEqual(self.run_cli("rewrite", "9.8.7").returncode, 2)


if __name__ == "__main__":
    unittest.main()
