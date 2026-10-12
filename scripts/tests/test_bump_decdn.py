"""Unit tests for scripts/bump_decdn.py, the file rewrites behind
scripts/open-decdn-bump.sh (`make test-scripts` runs them).

    python3 -m unittest discover -s scripts/tests -p 'test_*.py'

Each test runs on a throwaway git repository holding copies of this repo's real pin
files, so a reshaped pin file fails here before it fails a bump.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
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
    "ansible/molecule/validation-sponsord/converge.yml",
    *bd.CHANGELOGS,
]
SUMS = "a" * 64
DIGEST = "sha256:" + "b" * 64


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        for rel in FILES:
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / rel, self.root / rel)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        self.original = {rel: (self.root / rel).read_text() for rel in FILES}
        onramp = self.text(bd.ONRAMP_DEFAULTS)
        self.version = bd.pinned(self.root)
        self.sums = bd.scalar(onramp, "sponsord_onramp_decdn_sums_sha256", bd.ONRAMP_DEFAULTS)
        self.digest = bd.env_value(self.text(bd.COMPOSE_ENV), "DECDN_IMAGE_DIGEST", bd.COMPOSE_ENV)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def text(self, rel: str) -> str:
        return (self.root / rel).read_text()

    def write(self, rel: str, text: str) -> None:
        (self.root / rel).write_text(text)


class Compare(Fixture):
    def test_relations(self) -> None:
        major, minor, patch = (int(p) for p in self.version.split("."))
        self.assertEqual(bd.compare(self.root, f"v{self.version}"), "same")
        self.assertEqual(bd.compare(self.root, f"v{major}.{minor}.{patch + 1}"), "behind")
        self.assertEqual(bd.compare(self.root, f"v{major}.{minor + 1}.0"), "behind")

    def test_numeric_not_lexical(self) -> None:
        self.write(bd.NODE_DEFAULTS, self.text(bd.NODE_DEFAULTS).replace(
            f'decdn_node_version: "{self.version}"', 'decdn_node_version: "0.0.9"'))
        self.assertEqual(bd.compare(self.root, "v0.0.10"), "behind")
        self.assertEqual(bd.compare(self.root, "v0.0.8"), "ahead")

    def test_refuses_a_non_release_tag(self) -> None:
        for tag in ("0.0.3", "v0.0.3-rc.1", "v1.2"):
            with self.subTest(tag=tag), self.assertRaises(bd.ShapeError):
                bd.compare(self.root, tag)


class Rewrite(Fixture):
    def test_moves_every_pin(self) -> None:
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        onramp = self.text(bd.ONRAMP_DEFAULTS)
        self.assertEqual(bd.pinned(self.root), "9.8.7")
        self.assertIn("sponsord_onramp_decdn_release: v9.8.7 ", onramp)
        self.assertIn("Default: decdn/decdn v9.8.7.", onramp)
        self.assertIn("defaults to: decdn/decdn v9.8.7.", self.text(bd.ONRAMP_ENV))
        self.assertIn(f"ONRAMP_DECDN_SUMS_SHA256={SUMS}\n", self.text(bd.ONRAMP_ENV))
        self.assertIn(f"# decdn/decdn v9.8.7\nDECDN_IMAGE_DIGEST={DIGEST}\n", self.text(bd.COMPOSE_ENV))
        self.assertIn(f"e.g. for v9.8.7\n  # {DIGEST}\n", self.text(bd.CHART_VALUES))
        self.assertIn('appVersion: "9.8.7"', self.text(bd.CHART))
        self.assertIn("image: ghcr.io/decdn/decdn-node:9.8.7\n", self.text(bd.CHART))
        # The pin-pair molecule case carries a copy of the digest.
        self.assertIn(SUMS, self.text("ansible/molecule/validation-sponsord/converge.yml"))
        self.assertNotIn(self.sums, self.text("ansible/molecule/validation-sponsord/converge.yml"))

    def test_round_trip_is_byte_identical(self) -> None:
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        bd.rewrite(self.root, self.version, self.sums, self.digest)
        for rel in FILES:
            with self.subTest(rel=rel):
                self.assertEqual(self.text(rel), self.original[rel])

    def test_leaves_the_sponsord_pin(self) -> None:
        onramp = self.text(bd.ONRAMP_DEFAULTS)
        sponsord = bd.scalar(onramp, "sponsord_onramp_version", bd.ONRAMP_DEFAULTS)
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        self.assertEqual(bd.scalar(self.text(bd.ONRAMP_DEFAULTS), "sponsord_onramp_version",
                                   bd.ONRAMP_DEFAULTS), sponsord)

    def test_leaves_the_changelogs(self) -> None:
        for rel in bd.CHANGELOGS:
            self.write(rel, self.text(rel) + f"\n{self.sums}\n")
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)
        for rel in bd.CHANGELOGS:
            self.assertIn(self.sums, self.text(rel))

    def test_refuses_a_reshaped_file(self) -> None:
        self.write(bd.COMPOSE_ENV, self.text(bd.COMPOSE_ENV).replace(f"# decdn/decdn v{self.version}\n", ""))
        with self.assertRaisesRegex(bd.ShapeError, "compose/.env.example: 0 matches"):
            bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)

    def test_refuses_a_second_pin_line(self) -> None:
        self.write(bd.CHART, self.text(bd.CHART) + f'appVersion: "{self.version}"\n')
        with self.assertRaisesRegex(bd.ShapeError, "2 matches"):
            bd.rewrite(self.root, "9.8.7", SUMS, DIGEST)

    def test_refuses_bad_arguments(self) -> None:
        for args in (("9.8", SUMS, DIGEST), ("9.8.7", "A" * 64, DIGEST), ("9.8.7", SUMS, "b" * 64)):
            with self.subTest(args=args), self.assertRaises(bd.ShapeError):
                bd.rewrite(self.root, *args)

    def test_refuses_a_drifted_copy(self) -> None:
        # The copies are found by the old value, so one that drifted from it is left
        # behind; the read-back must catch it.
        drifted = "c" * 64
        self.write(bd.ONRAMP_ENV, self.text(bd.ONRAMP_ENV).replace(self.sums, drifted))
        with self.assertRaisesRegex(bd.ShapeError, "ONRAMP_DECDN_SUMS_SHA256"):
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


class Changelog(Fixture):
    def unreleased_entries(self, rel: str) -> list[str]:
        marker = bd.CHANGELOGS[rel][0]
        return [line for line in self.text(rel).splitlines() if line.startswith(marker)]

    def test_replaces_the_entry_in_place(self) -> None:
        bd.changelog(self.root, "9.8.7")
        for rel in bd.CHANGELOGS:
            with self.subTest(rel=rel):
                entries = self.unreleased_entries(rel)
                self.assertEqual(len(entries), 1)
                self.assertIn("9.8.7", entries[0])
                # Only the entry moved.
                old = self.original[rel].splitlines()
                new = self.text(rel).splitlines()
                self.assertEqual(len(old), len(new))
                self.assertEqual(sum(a != b for a, b in zip(old, new)), 1)

    def test_current_version_is_a_no_op(self) -> None:
        bd.changelog(self.root, self.version)
        for rel in bd.CHANGELOGS:
            self.assertEqual(self.text(rel), self.original[rel])

    def test_inserts_first_under_changed(self) -> None:
        rel = "ansible/galaxy/node/CHANGELOG.md"
        marker = bd.CHANGELOGS[rel][0]
        lines = self.text(rel).splitlines(keepends=True)
        at = next(i for i, line in enumerate(lines) if line.startswith(marker))
        while lines[at + 1].startswith("  "):
            del lines[at + 1]
        del lines[at]
        self.write(rel, "".join(lines))
        bd.changelog(self.root, "9.8.7")
        text = self.text(rel)
        self.assertIn("### Changed\n\n" + bd.CHANGELOGS[rel][1].format(v="9.8.7"), text)

    def test_refuses_an_unreleased_without_changed(self) -> None:
        rel = "ansible/galaxy/node/CHANGELOG.md"
        marker = bd.CHANGELOGS[rel][0]
        lines = [line for line in self.text(rel).splitlines(keepends=True)
                 if line != "### Changed\n" and not line.startswith(marker)]
        self.write(rel, "".join(lines))
        with self.assertRaisesRegex(bd.ShapeError, "no ### Changed"):
            bd.changelog(self.root, "9.8.7")

    def test_refuses_two_entries(self) -> None:
        rel = "ansible/galaxy/publisher/CHANGELOG.md"
        entry = bd.CHANGELOGS[rel][1].format(v="0.0.0")
        self.write(rel, self.text(rel).replace("### Changed\n\n", "### Changed\n\n" + entry, 1))
        with self.assertRaisesRegex(bd.ShapeError, "2 \\[Unreleased\\] entries"):
            bd.changelog(self.root, "9.8.7")

    def test_skips_a_released_collection(self) -> None:
        rel = "ansible/galaxy/node/CHANGELOG.md"
        released = self.text(rel).replace("## [Unreleased]\n", "## [0.1.0] — 2026-01-01\n")
        self.write(rel, released)
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertNotIn(rel, bd.changelog(self.root, "9.8.7"))
        self.assertIn(f"{rel} has no [Unreleased] section", err.getvalue())
        self.assertEqual(self.text(rel), released)


class Cli(Fixture):
    """open-decdn-bump.sh reads stdout and the exit code; a refusal must exit 1."""

    def run_cli(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HERE.parent / "bump_decdn.py"), "--root", str(self.root), *args],
            capture_output=True, text=True, check=False,
        )

    def test_pinned_and_compare_print_one_word(self) -> None:
        self.assertEqual(self.run_cli("pinned").stdout, f"{self.version}\n")
        r = self.run_cli("compare", "v99.0.0")
        self.assertEqual((r.returncode, r.stdout), (0, "behind\n"))

    def test_a_refusal_exits_1(self) -> None:
        self.write(bd.COMPOSE_ENV, self.text(bd.COMPOSE_ENV).replace(f"# decdn/decdn v{self.version}\n", ""))
        r = self.run_cli("rewrite", "9.8.7", "--sums-sha256", SUMS, "--image-digest", DIGEST)
        self.assertEqual(r.returncode, 1)
        self.assertTrue(r.stderr.startswith("bump_decdn: "), r.stderr)
        self.assertEqual(self.run_cli("compare", "v1.2").returncode, 1)

    def test_usage_exits_2(self) -> None:
        self.assertEqual(self.run_cli().returncode, 2)
        self.assertEqual(self.run_cli("rewrite", "9.8.7").returncode, 2)


if __name__ == "__main__":
    unittest.main()
