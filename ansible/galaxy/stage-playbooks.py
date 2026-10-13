#!/usr/bin/env python3
"""Stage a collection's playbooks for galaxy/build.sh.

    galaxy/stage-playbooks.py <node|publisher> <stage-dir>

Copies into <stage-dir>/playbooks/:
  - the playbooks galaxy/<collection>/playbooks.txt lists, from ansible/playbooks/;
  - ansible/playbooks/group_vars/, which a collection playbook loads as it does in
    this repo (the loader's basedir is the playbook's directory), so the firewall
    holes and the Alloy toggles ship with the same precedence;
  - the overlay galaxy/<collection>/playbooks/, if any.

Role references become FQCNs (`role: baseline` -> `role: decdn.node.baseline`, and
an include_role/import_role `name:` likewise), line by line so the comments
survive. The repo's own playbooks stay unqualified: a `collections:` keyword there
would let an installed decdn.node shadow ansible/roles/ on a deploy.

A role reference is one of exactly two forms, its name bare or quoted:
  - a `roles:` item written `- role: <name>`;
  - the `name:` key of a block-mapping include_role/import_role (any prefix).
Anything else that names a role is refused, not guessed at: a flow-style or inline
`roles:` list or include_role, a `- <name>` or `- name: <name>` roles item, a
templated or block-scalar name, an include_role without a name. That matters
because `ansible-playbook --syntax-check` does not resolve an include_role: a name
left short there would fail only at a consumer's runtime.

After the rewrite it fails on a reference that is not an FQCN of this collection
or of one it depends on, an include_role `tasks_from:` the role does not have, and
an import_playbook whose target is not staged (a run never leaves the collection,
so it never mixes two releases' group_vars/).
Stdlib only: build.sh runs it with whatever python3 is on PATH.
"""

from __future__ import annotations

import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

ANSIBLE_DIR = Path(__file__).resolve().parent.parent
GALAXY_DIR = ANSIBLE_DIR / "galaxy"
PLAYBOOKS_DIR = ANSIBLE_DIR / "playbooks"
ROLES_DIR = ANSIBLE_DIR / "roles"
COLLECTIONS = ("node", "publisher")
# The collections each one's playbooks may call into: its own and its dependencies
# (galaxy/publisher/galaxy.yml depends on decdn.node).
CALLS_INTO = {"node": ("node",), "publisher": ("publisher", "node")}

# A role name, bare or in matching quotes: `baseline`, "baseline", 'decdn.node.baseline'.
NAME_VALUE = re.compile(r"""^(?P<q>["']?)(?P<name>[A-Za-z0-9_.]+)(?P=q)$""")
# A tasks_from file name (node-ids, topup-hold), bare or quoted.
TASKS_FROM_VALUE = re.compile(r"""^(?P<q>["']?)(?P<name>[A-Za-z0-9_.-]+)(?P=q)$""")
COMMENT_TAIL = re.compile(r"\s+#.*$")
ROLE_TASK = re.compile(r"^(?:-\s+)?(?:ansible\.(?:builtin|legacy)\.)?(?:include|import)_role:(?P<rest>.*)$")
ANY_ROLE_TASK = re.compile(r"(?:include|import)_role\s*:")
ROLES_KEY = re.compile(r"^(?:-\s+)?roles:(?P<rest>.*)$")
KEY_VALUE = re.compile(r"^(?:-\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_]*):(?:\s+(?P<value>.*))?$")
IMPORT_PLAYBOOK = re.compile(r"^(?:-\s+)?(?:ansible\.builtin\.)?import_playbook:(?P<rest>.*)$")


class StageError(Exception):
    pass


@dataclass
class Site:
    """A role reference: the line it is on, its name, and (for an include_role) the
    tasks_from it names."""

    line: int
    name: str
    quote: str
    tasks_from: str | None = None


def listed(path: Path) -> list[str]:
    if not path.is_file():
        raise StageError(f"{path} is missing")
    names = [s for line in path.read_text().splitlines() if (s := line.strip()) and not s.startswith("#")]
    if not names:
        raise StageError(f"{path} lists nothing")
    return names


def role_owners() -> dict[str, str]:
    owners: dict[str, str] = {}
    for collection in COLLECTIONS:
        for role in listed(GALAXY_DIR / collection / "roles.txt"):
            if role in owners:
                raise StageError(f"{role} is in both {owners[role]}/roles.txt and {collection}/roles.txt")
            owners[role] = collection
    return owners


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def value_of(raw: str | None) -> str:
    return COMMENT_TAIL.sub("", raw or "").strip()


def scan(lines: list[str], where: str) -> tuple[list[Site], list[str]]:
    """Every role reference in a playbook, and every reference form it refuses."""
    sites: list[Site] = []
    errors: list[str] = []
    task = None   # an open include_role/import_role: [indent, child indent, Site | None, line]
    roles = None  # an open `roles:` key: [indent, item indent]

    def close_task() -> None:
        if task is not None and task[2] is None:
            errors.append(f"{where}:{task[3]}: an include_role/import_role without a name: key")

    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        ind = indent_of(line)
        if task is not None and ind <= task[0]:
            close_task()
            task = None
        # A `roles:` sequence may sit at the key's own indent; anything else there, or
        # anything shallower, ends it.
        if roles is not None and (ind < roles[0] or (ind == roles[0] and not stripped.startswith("- "))):
            roles = None

        if m := ROLE_TASK.match(stripped):
            if value_of(m["rest"]):
                errors.append(f"{where}:{n}: write `{stripped}` as a block mapping, so its role name can be qualified")
            task = [ind, None, None, n]
            continue
        if ANY_ROLE_TASK.search(stripped):
            errors.append(f"{where}:{n}: `{stripped}` names a role in a form this script does not parse")
            continue
        if m := ROLES_KEY.match(stripped):
            if value_of(m["rest"]):
                errors.append(f"{where}:{n}: write roles as a block sequence of `- role: <name>`, not `{stripped}`")
            roles = [ind, None]
            continue

        if task is not None:
            if task[1] is None:
                task[1] = ind
            if ind == task[1] and (kv := KEY_VALUE.match(stripped)) and kv["key"] in ("name", "tasks_from"):
                value = value_of(kv["value"])
                if not (v := (NAME_VALUE if kv["key"] == "name" else TASKS_FROM_VALUE).match(value)):
                    errors.append(f"{where}:{n}: write the role's {kv['key']} as a bare name, not `{value}`")
                elif kv["key"] == "name":
                    task[2] = Site(n, v["name"], v["q"])
                    sites.append(task[2])
                elif task[2] is not None:
                    task[2].tasks_from = v["name"]
                else:
                    errors.append(f"{where}:{n}: put an include_role's name: before its tasks_from:")
            continue

        if roles is not None and stripped.startswith("- "):
            if roles[1] is None:
                roles[1] = ind
            if ind == roles[1]:
                kv = KEY_VALUE.match(stripped)
                if kv is None or kv["key"] != "role":
                    errors.append(f"{where}:{n}: write a roles item as `- role: <name>`, not `{stripped}`")
                elif not (v := NAME_VALUE.match(value_of(kv["value"]))):
                    errors.append(f"{where}:{n}: write the role as a bare name, not `{stripped}`")
                else:
                    sites.append(Site(n, v["name"], v["q"]))
    close_task()
    return sites, errors


def rewrite(path: Path, owners: dict[str, str]) -> None:
    """Qualify every role reference in place, keeping the line's quotes and comment."""
    lines = path.read_text().splitlines(keepends=True)
    sites, errors = scan([raw.rstrip("\n") for raw in lines], path.name)
    if errors:
        raise StageError("\n".join(errors))
    for site in sites:
        if site.name not in owners:
            continue  # check() names it
        raw = lines[site.line - 1]
        old = f"{site.quote}{site.name}{site.quote}"
        new = f"{site.quote}decdn.{owners[site.name]}.{site.name}{site.quote}"
        head, sep, tail = raw.partition(": ")
        lines[site.line - 1] = head + sep + tail.replace(old, new, 1)
    path.write_text("".join(lines))


def check(path: Path, collection: str, owners: dict[str, str], staged: set[str]) -> list[str]:
    """Every role reference an FQCN this collection can resolve, with the tasks_from it
    names; every import local."""
    allowed = {f"decdn.{owners[r]}.{r}": r for r in owners if owners[r] in CALLS_INTO[collection]}
    lines = path.read_text().splitlines()
    sites, problems = scan(lines, path.name)
    for site in sites:
        if site.name not in allowed:
            problems.append(f"{path.name}:{site.line}: role {site.name} is not one decdn.{collection} can resolve")
        elif site.tasks_from is not None and not any(
            (ROLES_DIR / allowed[site.name] / "tasks" / f"{site.tasks_from}{ext}").is_file() for ext in (".yml", ".yaml")
        ):
            problems.append(f"{path.name}:{site.line}: {site.name} has no tasks_from {site.tasks_from}")
    for n, line in enumerate(lines, 1):
        if m := IMPORT_PLAYBOOK.match(line.strip()):
            target = value_of(m["rest"])
            if not target:
                problems.append(f"{path.name}:{n}: write import_playbook's target on its line")
            elif target not in staged:
                problems.append(f"{path.name}:{n}: imports {target}, which decdn.{collection} does not ship")
    return problems


def stage(collection: str, stage_dir: Path) -> None:
    owners = role_owners()
    overlay = GALAXY_DIR / collection / "playbooks"
    names = listed(GALAXY_DIR / collection / "playbooks.txt")
    overlay_names = sorted(p.name for p in overlay.glob("*.yml")) if overlay.is_dir() else []
    if clash := sorted(set(names) & set(overlay_names)):
        raise StageError(f"{collection}: {', '.join(clash)} both listed in playbooks.txt and in the overlay playbooks/")
    if len(set(names)) != len(names):
        raise StageError(f"{collection}/playbooks.txt lists a playbook twice")
    if not (PLAYBOOKS_DIR / "group_vars").is_dir():
        raise StageError(f"{PLAYBOOKS_DIR / 'group_vars'} is missing")

    dest = stage_dir / "playbooks"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    shutil.copytree(PLAYBOOKS_DIR / "group_vars", dest / "group_vars")
    for name in names:
        src = PLAYBOOKS_DIR / name
        if not src.is_file():
            raise StageError(f"{collection}/playbooks.txt names {name}, which is not under ansible/playbooks/")
        shutil.copy2(src, dest / name)
    for name in overlay_names:
        shutil.copy2(overlay / name, dest / name)

    staged = set(names) | set(overlay_names)
    problems = []
    for name in sorted(staged):
        rewrite(dest / name, owners)
        problems += check(dest / name, collection, owners, staged)
    if problems:
        raise StageError("\n".join(problems))
    print(f"staged {len(staged)} playbooks (+ group_vars/) -> {dest}")


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in COLLECTIONS:
        print(f"usage: {argv[0]} node|publisher <stage-dir>", file=sys.stderr)
        return 2
    try:
        stage(argv[1], Path(argv[2]))
    except StageError as e:
        print(f"stage-playbooks.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
