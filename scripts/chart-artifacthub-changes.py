#!/usr/bin/env python3
"""Print a chart CHANGELOG section as Artifact Hub's `artifacthub.io/changes` list.

    scripts/chart-artifacthub-changes.py <CHANGELOG.md> <X.Y.Z>

Artifact Hub does not read CHANGELOG.md; it shows the changes annotation in the chart's
Chart.yaml. Rather than keep a second copy by hand, release.yml runs this on the
`## [X.Y.Z]` section of charts/decdn-node/CHANGELOG.md and sets the annotation on the
packaged copy only (yq), so the changelog stays the one source.

Each `### <Kind>` subsection (Keep a Changelog: Added, Changed, Deprecated, Removed,
Fixed, Security) maps to Artifact Hub's `kind`, and each `- ` bullet in it becomes one
entry, its wrapped lines joined with single spaces. Text before the first `###` (the
section's intro) is skipped. Anything else stops the script rather than drop a change:
an unknown heading, a non-bullet line under a heading, an empty entry, a missing or
empty section. Whether the section is still "unreleased" is scripts/check-release-version.sh's gate.

Prints a YAML list with JSON-quoted descriptions (JSON strings are YAML). Exit status:
0 printed, 1 the changelog does not give a usable section, 2 usage.
"""

import json
import re
import sys

KINDS = {"added", "changed", "deprecated", "removed", "fixed", "security"}


def fail(msg):
    print(f"{sys.argv[0]}: {msg}", file=sys.stderr)
    sys.exit(1)


def section(lines, version):
    """The lines of `## [version]`, up to the next `## ` heading."""
    head = f"## [{version}]"
    for i, line in enumerate(lines):
        if line.startswith(head):
            end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("## ")), len(lines))
            return lines[i + 1:end]
    fail(f"no '{head}' section")


def changes(body):
    out, kind, entry = [], None, None

    def flush():
        if entry is not None:
            description = " ".join(part for part in entry if part)
            if not description:
                fail(f"an empty '-' entry under '### {kind.capitalize()}'")
            out.append({"kind": kind, "description": description})

    for n, line in enumerate(body, 1):
        if line.startswith("### "):
            flush()
            entry = None
            kind = line[4:].strip().lower()
            if kind not in KINDS:
                fail(f"unknown heading '{line.strip()}' (want one of {', '.join(sorted(KINDS))})")
        elif kind is None or not line.strip():
            continue  # the section's intro, or a blank line
        elif line.rstrip() == "-" or line.startswith("- "):
            flush()
            entry = [line[1:].strip()]
        elif re.match(r"\s", line) and entry is not None:
            entry.append(line.strip())
        else:
            fail(f"line {n} of the section is neither a '- ' entry nor its continuation: {line.strip()!r}")
    flush()
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__.splitlines()[2].strip(), file=sys.stderr)
        sys.exit(2)
    path, version = sys.argv[1:]
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        fail(str(e))
    entries = changes(section(lines, version))
    if not entries:
        fail(f"the '## [{version}]' section has no entries")
    for e in entries:
        print(f"- kind: {e['kind']}")
        print(f"  description: {json.dumps(e['description'], ensure_ascii=False)}")


if __name__ == "__main__":
    main()
