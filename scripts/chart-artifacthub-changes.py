#!/usr/bin/env python3
"""Print a chart CHANGELOG section as Artifact Hub's `artifacthub.io/changes` list.

    scripts/chart-artifacthub-changes.py <CHANGELOG.md> <X.Y.Z>

Artifact Hub does not read CHANGELOG.md; it shows the changes annotation in the chart's
Chart.yaml. Rather than keep a second copy by hand, release.yml runs this on the
`## [X.Y.Z]` section of charts/decdn-node/CHANGELOG.md and sets the annotation on the
packaged chart only (yq), so the changelog stays the one source.

The section runs to the next `## [` heading, as in scripts/check-release-version.sh,
which builds the GitHub Release notes from the same text. Each `### <Kind>` subsection
(Keep a Changelog: Added, Changed, Deprecated, Removed, Fixed, Security) maps to
Artifact Hub's `kind`, and each `- ` bullet in it becomes one entry, its wrapped lines
joined with single spaces. Prose before the first `###` (the section's intro) is
skipped. Anything else stops the script rather than drop or mislabel a change: a
missing, duplicated or empty section; any other heading, including an indented one; a
bullet before the first `###`; a non-bullet line under a heading; an empty entry; a
nested list or code block inside an entry. Artifact Hub shows each description as
plain text, so Markdown in it (backticks, links) appears verbatim. Whether the section
is still "unreleased" is check-release-version.sh's gate.

Prints a YAML list with JSON-quoted descriptions (JSON strings are YAML). Exit status:
0 printed, 1 the changelog is unreadable or its section unusable, 2 usage.
"""

import json
import re
import sys

KINDS = {"added", "changed", "deprecated", "removed", "fixed", "security"}
HEADING = re.compile(r" {0,3}#{1,6}(\s|$)")      # CommonMark ATX heading
BULLET = re.compile(r"\s*([-*+]|\d+[.)])(\s|$)")  # any list item
FENCE = re.compile(r"\s*(```|~~~)")


def fail(msg):
    print(f"{sys.argv[0]}: {msg}", file=sys.stderr)
    sys.exit(1)


def section(lines, version):
    """(file line number of the first body line, body lines) of `## [version]`."""
    head = f"## [{version}]"
    starts = [i for i, line in enumerate(lines) if line.startswith(head)]
    if not starts:
        fail(f"no '{head}' section")
    if len(starts) > 1:
        fail(f"'{head}' appears {len(starts)} times (lines {', '.join(str(i + 1) for i in starts)})")
    i = starts[0]
    end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("## [")), len(lines))
    return i + 2, lines[i + 1:end]


def changes(first, body):
    out, kind, entry = [], None, None

    def flush():
        if entry is not None:
            description = " ".join(part for part in entry if part)
            if not description:
                fail(f"an empty '-' entry under '### {kind.capitalize()}'")
            out.append({"kind": kind, "description": description})

    for n, line in enumerate(body, first):
        if HEADING.match(line):
            flush()
            entry = None
            kind = line[4:].strip().lower() if line.startswith("### ") else None
            if kind not in KINDS:
                fail(f"line {n}: heading {line.rstrip()!r} is not '### <Kind>' "
                     f"(one of {', '.join(sorted(KINDS))}, unindented)")
        elif not line.strip():
            continue
        elif kind is None:
            if BULLET.match(line):
                fail(f"line {n}: {line.strip()!r} comes before the first '### <Kind>' heading")
            continue  # the section's intro
        elif line.rstrip() == "-" or line.startswith("- "):
            flush()
            entry = [line[1:].strip()]
        elif re.match(r"\s", line) and entry is not None:
            if BULLET.match(line) or FENCE.match(line):
                fail(f"line {n}: a nested list or code block in an entry ({line.strip()!r}); "
                     "Artifact Hub shows each entry as one line of text")
            entry.append(line.strip())
        else:
            fail(f"line {n} is neither a '- ' entry nor its continuation: {line.strip()!r}")
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
    entries = changes(*section(lines, version))
    if not entries:
        fail(f"the '## [{version}]' section has no entries")
    for e in entries:
        print(f"- kind: {e['kind']}")
        print(f"  description: {json.dumps(e['description'], ensure_ascii=False)}")


if __name__ == "__main__":
    main()
