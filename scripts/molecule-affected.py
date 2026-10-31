#!/usr/bin/env python3
"""Select the Molecule scenarios a change can affect.

    scripts/molecule-affected.py [--explain] < changed-paths
    scripts/molecule-affected.py [--explain] --since <ref>

Prints one line: `all`, `none`, or the affected scenario names, space-separated and
sorted. With `--since`, the changed paths are everything that differs from the merge
base of <ref> and HEAD: commits, the working tree and untracked files (git
`--no-renames`, so a rename counts as its old path and its new one). Otherwise they
are read from stdin, one repo-relative path per line. `--explain` writes, to
stderr, what each path selected.

Molecule CI runs this on a pull request (`.github/workflows/molecule.yml`, `discover`)
and `make molecule-changed` (ansible/Makefile) runs it locally; a push to main runs
every scenario regardless.

The dependencies come from the tree on every run, not from a table, so a new scenario,
include or stub is covered with no edit here. Comments are ignored throughout: they
name scenarios, roles and playbooks they do not read.

- scenario -> files: its own files, and every file under ansible/molecule/ they name
  by path (`../<s>/<file>` or `molecule/<s>/<file>`: playbook overrides, includes,
  stubs), transitively. A name that is not a file stands for the whole directory;
- scenario -> playbook: every `playbooks/<p>.yml` those files name, and what that one
  imports (`import_playbook:`), transitively;
- scenario -> role: every role named as a whole word in those files or playbooks;
- role -> role: a role that reaches into another by path (`/../<role>/`).

`select()` then maps each changed path to scenarios; a path it does not recognise
under the workflow's trigger paths selects `all`. Over-selecting costs runner time,
under-selecting lets a broken role merge, so every uncertain case selects more.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from functools import cache
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ANSIBLE = REPO / "ansible"

# Any change here can affect every scenario: how they are run, with which collections.
ALL_PATHS = {
    "scripts/molecule.sh",
    "scripts/molecule-affected.py",
    "ansible/Makefile",
    "ansible/requirements.yml",
    ".github/workflows/molecule.yml",
}

# Read by no scenario: lint config, docs, the firewall-holes tests (make test-scripts),
# the inventory templates (molecule writes its own inventory).
NO_SCENARIO = [
    re.compile(r"ansible/inventory/.*"),
    re.compile(r"ansible/tests/.*"),
    re.compile(r"ansible/(\.ansible-lint|\.yamllint|\.gitignore|README\.md)"),
    re.compile(r"ansible/roles/[^/]+/README\.md"),
]

# The cloud-init scenarios pack the whole working tree into the instance, run the
# playbooks there and syntax-check every role and playbook (cloud-init/bootstrap.sh),
# so any role or playbook change reaches them, named or not.
CLOUD_INIT = ("cloud-init", "cloud-init-publisher")
# `collection` builds decdn.node from ansible/galaxy/ and runs it.
COLLECTION = "collection"
NODE_ROLES = ANSIBLE / "galaxy/node/roles.txt"
NODE_PLAYBOOKS = ANSIBLE / "galaxy/node/playbooks.txt"


class Tree:
    """The scenarios, roles and playbooks under ansible/, and what refers to what."""

    def __init__(self, root: Path = ANSIBLE) -> None:
        self.root = root
        mol = root / "molecule"
        self.scenarios = sorted(
            d.name for d in mol.iterdir() if (d / "molecule.yml").is_file()
        )
        self.roles = sorted(d.name for d in (root / "roles").iterdir() if d.is_dir())
        self.playbooks = sorted(p.stem for p in (root / "playbooks").glob("*.yml"))
        if not self.scenarios or not self.roles or not self.playbooks:
            sys.exit(
                f"molecule-affected: found scenarios {self.scenarios}, roles "
                f"{self.roles}, playbooks {self.playbooks} under {root}; refusing to "
                "select from a partial tree"
            )
        for name in (*CLOUD_INIT, COLLECTION):
            if name not in self.scenarios:
                sys.exit(
                    f"molecule-affected: scenario '{name}' is named here but is not under "
                    f"{mol} (update scripts/molecule-affected.py)"
                )
        # Role names hold `_`, scenario and stub names `-`: `sponsord` is neither
        # `sponsord_onramp` nor `sponsord-stub`.
        self._role_re = {
            r: re.compile(rf"(?<![\w-]){re.escape(r)}(?![\w-])") for r in self.roles
        }
        self._mol = mol.resolve()
        self.files = {s: _files(self._mol / s) for s in self.scenarios}

    @staticmethod
    def _text(d: Path) -> str:
        return "\n".join(_code(p) for p in _files(d))

    @cache
    def file_refs(self, f: Path) -> frozenset[Path]:
        """The files under ansible/molecule/ that f names by path. A name that is
        not a file on disk (a directory, a templated or a deleted name) stands for
        every file under the longest prefix of it that is."""
        out: set[Path] = set()
        for t, rest in _SCENARIO_REF.findall(_code(f)):
            if t not in self.files:
                continue
            target = self._mol / t
            for part in rest.split("/"):
                if part and (target / part).exists():
                    target = target / part
                else:
                    break
            out |= {target} if target.is_file() else set(_files(target))
        return frozenset(out)

    @cache
    def scenario_files(self, s: str) -> frozenset[Path]:
        """s's own files and every file under ansible/molecule/ they name, transitively."""
        seen = set(self.files[s])
        todo = list(seen)
        while todo:
            for g in self.file_refs(todo.pop()):
                if g not in seen:
                    seen.add(g)
                    todo.append(g)
        return frozenset(seen)

    @cache
    def scenario_text(self, s: str) -> str:
        return "\n".join(_code(p) for p in sorted(self.scenario_files(s)))

    @cache
    def playbook_text(self, p: str) -> str:
        return _code(self.root / "playbooks" / f"{p}.yml")

    def _imported_playbooks(self, text: str) -> set[str]:
        named = set(re.findall(r"import_playbook:\s*[\"']?(?:\./)?([\w-]+)\.yml", text))
        return named & set(self.playbooks)

    @cache
    def playbook_closure(self, p: str) -> frozenset[str]:
        """p and every playbook it imports, transitively."""
        seen, todo = {p}, [p]
        while todo:
            for q in self._imported_playbooks(self.playbook_text(todo.pop())):
                if q not in seen:
                    seen.add(q)
                    todo.append(q)
        return frozenset(seen)

    @cache
    def scenario_playbooks(self, s: str) -> frozenset[str]:
        text = self.scenario_text(s)
        named = {
            p
            for p in self.playbooks
            if re.search(rf"playbooks/{re.escape(p)}\.yml", text)
        }
        return frozenset(q for p in named for q in self.playbook_closure(p))

    @cache
    def scenario_roles(self, s: str) -> frozenset[str]:
        text = "\n".join(
            [self.scenario_text(s)]
            + [self.playbook_text(p) for p in self.scenario_playbooks(s)]
        )
        return frozenset(r for r, rx in self._role_re.items() if rx.search(text))

    @cache
    def role_refs(self, r: str) -> frozenset[str]:
        """Roles whose files r reads by path (`/../<role>/`)."""
        text = self._text(self.root / "roles" / r)
        return frozenset(
            t for t in self.roles if t != r and f"/../{t}/" in text
        )

    @cache
    def dependent_roles(self, r: str) -> frozenset[str]:
        """r and every role that reads r's files, transitively."""
        seen, todo = {r}, [r]
        while todo:
            cur = todo.pop()
            for u in self.roles:
                if u not in seen and cur in self.role_refs(u):
                    seen.add(u)
                    todo.append(u)
        return frozenset(seen)

    def using_file(self, s: str, path: Path) -> set[str]:
        """Scenarios that read path, a file under scenario s. One no longer on disk
        (deleted, or renamed away) selects s and every scenario reading any of s's
        files: whatever named it now names nothing, and resolved to the directory."""
        path = path.resolve()
        if path.is_file():
            return {u for u in self.scenarios if path in self.scenario_files(u)}
        mine = set(self.files[s])
        return {s} | {u for u in self.scenarios if self.scenario_files(u) & mine}

    def using_roles(self, roles: frozenset[str]) -> set[str]:
        return {u for u in self.scenarios if self.scenario_roles(u) & roles}

    def using_playbook(self, p: str) -> set[str]:
        return {u for u in self.scenarios if p in self.scenario_playbooks(u)}

    def using_any_playbook(self) -> set[str]:
        return {u for u in self.scenarios if self.scenario_playbooks(u)}


# `../<scenario>/<rest>` or `molecule/<scenario>/<rest>`: a provisioner playbook
# override, an include, `${MOLECULE_PROJECT_DIRECTORY}/molecule/<s>/files/<stub>`.
_SCENARIO_REF = re.compile(r"(?:\.\./|molecule/)([\w.-]+)/([\w./-]*)")
_COMMENT = re.compile(r"(?:^|\s)#(?!!).*$", re.MULTILINE)


def _files(d: Path) -> list[Path]:
    return sorted(p.resolve() for p in d.rglob("*") if p.is_file())


@cache
def _code(path: Path) -> str:
    """A file's text without its `#` comments, which name scenarios, roles and
    playbooks in passing ("same note as ../default/molecule.yml") that the file does
    not read. Only a `#` at a line's start or after whitespace opens one, so a shebang
    stays, as does a reference before a trailing comment."""
    return _COMMENT.sub("", path.read_text(encoding="utf-8", errors="replace"))


def _listed(path: Path) -> set[str]:
    return {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


ALL = "all"


def select(tree: Tree, path: str) -> set[str] | str:
    """The scenarios one changed path can affect: a set (maybe empty), or ALL."""
    if path in ALL_PATHS:
        return ALL
    if any(rx.fullmatch(path) for rx in NO_SCENARIO):
        return set()
    if m := re.fullmatch(r"ansible/molecule/([^/]+)/.+", path):
        s = m.group(1)
        # A scenario not on disk (deleted or renamed away) cannot be traced.
        return tree.using_file(s, REPO / path) if s in tree.scenarios else ALL
    if m := re.fullmatch(r"ansible/roles/([^/]+)/.+", path):
        r = m.group(1)
        if r not in tree.roles:
            return ALL
        hit = tree.using_roles(tree.dependent_roles(r)) | set(CLOUD_INIT)
        if r in _listed(NODE_ROLES):
            hit.add(COLLECTION)
        return hit
    if path.startswith("ansible/playbooks/group_vars/"):
        return tree.using_any_playbook() | set(CLOUD_INIT) | {COLLECTION}
    if m := re.fullmatch(r"ansible/playbooks/([^/]+)\.yml", path):
        p = m.group(1)
        if p not in tree.playbooks:
            return ALL
        hit = tree.using_playbook(p) | set(CLOUD_INIT)
        if f"{p}.yml" in _listed(NODE_PLAYBOOKS):
            hit.add(COLLECTION)
        return hit
    if path.startswith("ansible/galaxy/"):
        return {COLLECTION}
    if path.startswith("cloud-init/") or path == "ansible/ansible.cfg":
        return set(CLOUD_INIT)
    # Outside the workflow's trigger paths (docs, compose/, the chart): no scenario
    # reads them, and they reach a run only beside a change that does.
    if not path.startswith(("ansible/", "scripts/molecule")):
        return set()
    return ALL


def changed_since(ref: str) -> list[str]:
    def git(*args: str) -> str:
        r = subprocess.run(["git", *args], cwd=REPO, capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"molecule-affected: git {' '.join(args)} failed: {r.stderr.strip()}")
        return r.stdout

    base = git("merge-base", ref, "HEAD").strip()
    out = git("diff", "--no-renames", "--name-only", base)  # commits + working tree
    out += git("ls-files", "--others", "--exclude-standard")
    return out.splitlines()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--since", metavar="REF", help="diff against the merge base of REF and HEAD")
    ap.add_argument("--explain", action="store_true", help="say what each path selected, on stderr")
    args = ap.parse_args(argv)

    paths = changed_since(args.since) if args.since else sys.stdin.read().splitlines()
    paths = sorted({p.strip() for p in paths if p.strip()})
    tree = Tree()
    chosen: set[str] = set()
    every = False
    for path in paths:
        hit = select(tree, path)
        if args.explain:
            shown = ALL if hit == ALL else (" ".join(sorted(hit)) or "(none)")
            print(f"{path} -> {shown}", file=sys.stderr)
        if hit == ALL:
            every = True
        else:
            chosen |= hit
    print(ALL if every else (" ".join(sorted(chosen)) or "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
