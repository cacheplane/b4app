#!/usr/bin/env python3
"""Split docs/decisions.md and docs/verification.md into one file per entry.

Run once from the repository root. It reads the two logs as they are on the
tree, writes `docs/decisions/D-NNN-<slug>.md` (one per decision bullet) and
`docs/verification/YYYY-MM-DD-<slug>.md` (one per dated gate record), and
then proves nothing was lost: every non-blank line of the originals must come
back, in order, from the files it wrote. The script is idempotent, so it can
be re-run on a tree where the logs gained entries since the last split.

Each decision file is the section's `## <date> (<topic>)` heading, a blank
line, and the decision's text exactly as it was: the `- **D-NNN ...**` bullet
with its nested lines. Prose a section had before its first decision goes into
that decision's file (before the bullet); prose or a non-decision bullet that
followed a decision stays with that decision (after it). Each verification
file is its `## YYYY-MM-DD: <title>` heading and the record under it.
"""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DECISIONS = ROOT / "docs" / "decisions.md"
VERIFICATION = ROOT / "docs" / "verification.md"
DECISIONS_DIR = ROOT / "docs" / "decisions"
VERIFICATION_DIR = ROOT / "docs" / "verification"

DECISION_HEADING = re.compile(r"^## (\d{4}-\d{2}-\d{2})(?: \((.*)\))?$")
VERIFICATION_HEADING = re.compile(r"^## (\d{4}-\d{2}-\d{2}): (.+)$")
DECISION_BULLET = re.compile(r"^- \*\*(D-\d{3})\b")
BOLD_TITLE = re.compile(r"^- \*\*(.+?)\*\*")
SLUG_WORDS = 7
SLUG_MAX = 56


def slugify(text: str, words: int = SLUG_WORDS, limit: int = SLUG_MAX) -> str:
    text = re.sub(r"^D-\d{3}[a-z]?\s*", "", text)
    text = re.sub(r"^\([^)]*\)\s*", "", text)  # a leading "(Resolved by ...)"
    text = re.sub(r"\([^)]*\)", " ", text)  # other parentheticals
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = text.replace("`", "").replace("'", "").replace("’", "")
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", text.lower()) if p]
    slug = ""
    for part in parts[:words]:
        candidate = f"{slug}-{part}" if slug else part
        if len(candidate) > limit and slug:
            break
        slug = candidate
    return slug or "entry"


def split_sections(lines: list[str], heading: re.Pattern) -> tuple[list[str], list[tuple[str, list[str]]]]:
    """Return (lines before the first heading, [(heading line, body lines)])."""
    preface: list[str] = []
    sections: list[tuple[str, list[str]]] = []
    current: list[str] | None = None
    for line in lines:
        if heading.match(line):
            current = []
            sections.append((line, current))
        elif current is None:
            preface.append(line)
        else:
            current.append(line)
    return preface, sections


def strip_blank_edges(block: list[str]) -> list[str]:
    start, end = 0, len(block)
    while start < end and block[start].strip() == "":
        start += 1
    while end > start and block[end - 1].strip() == "":
        end -= 1
    return block[start:end]


def split_decisions(text: str) -> tuple[list[str], list[dict]]:
    lines = text.split("\n")
    preface, sections = split_sections(lines, DECISION_HEADING)
    entries: list[dict] = []
    for heading, body in sections:
        date, topic = DECISION_HEADING.match(heading).groups()
        # Items: a top-level bullet starts one; indented and blank lines attach
        # to the current item; column-0 prose attaches to the current item too,
        # or to the preamble when no item has started yet.
        preamble: list[str] = []
        items: list[dict] = []
        for line in body:
            if line.startswith("- "):
                m = DECISION_BULLET.match(line)
                if m:
                    items.append({"number": m.group(1), "lines": [line]})
                elif items:
                    items[-1]["lines"].append(line)
                else:
                    preamble.append(line)
            elif items:
                items[-1]["lines"].append(line)
            else:
                preamble.append(line)
        if not items:
            sys.exit(f"decisions: section without a decision: {heading}")
        for index, item in enumerate(items):
            block = strip_blank_edges(item["lines"])
            if index == 0:
                lead = strip_blank_edges(preamble)
                if lead:
                    block = lead + [""] + block
            title = BOLD_TITLE.match(item["lines"][0]).group(1)
            entries.append(
                {
                    "number": item["number"],
                    "heading": heading,
                    "date": date,
                    "topic": topic,
                    "title": title,
                    "body": block,
                }
            )
    return preface, entries


def split_verification(text: str) -> tuple[list[str], list[dict]]:
    lines = text.split("\n")
    preface, sections = split_sections(lines, VERIFICATION_HEADING)
    entries: list[dict] = []
    for heading, body in sections:
        date, title = VERIFICATION_HEADING.match(heading).groups()
        entries.append({"heading": heading, "date": date, "title": title, "body": strip_blank_edges(body)})
    return preface, entries


def write_entry(path: Path, heading: str, body: list[str]) -> None:
    path.write_text("\n".join([heading, ""] + body) + "\n", encoding="utf-8")


def unique_names(entries: list[dict], base_name) -> None:
    seen: dict[str, int] = {}
    for entry in entries:
        name = base_name(entry)
        count = seen.get(name, 0) + 1
        seen[name] = count
        entry["name"] = name if count == 1 else f"{name}-{count}"
    # A second pass: the first of a repeated name also needs no suffix only if
    # the suffixed names do not collide with a real one; the slugs are long
    # enough that this does not happen, but check.
    names = [e["name"] for e in entries]
    if len(set(names)) != len(names):
        sys.exit("file names collide after suffixing: " + ", ".join(sorted(n for n in names if names.count(n) > 1)))


def nonblank(lines: list[str]) -> list[str]:
    return [line for line in lines if line.strip() != ""]


def main() -> None:
    decisions_text = DECISIONS.read_text(encoding="utf-8")
    verification_text = VERIFICATION.read_text(encoding="utf-8")

    _, decisions = split_decisions(decisions_text)
    _, records = split_verification(verification_text)

    numbers = [d["number"] for d in decisions]
    duplicates = sorted({n for n in numbers if numbers.count(n) > 1})
    if duplicates:
        sys.exit("decisions.md holds the same number twice: " + ", ".join(duplicates))

    unique_names(decisions, lambda d: f"{d['number']}-{slugify(d['title'])}")
    unique_names(records, lambda r: f"{r['date']}-{slugify(r['title'])}")

    DECISIONS_DIR.mkdir(exist_ok=True)
    VERIFICATION_DIR.mkdir(exist_ok=True)
    for d in decisions:
        write_entry(DECISIONS_DIR / f"{d['name']}.md", d["heading"], d["body"])
    for r in records:
        write_entry(VERIFICATION_DIR / f"{r['name']}.md", r["heading"], r["body"])

    # Proof: the non-blank lines of every original section, in order, equal the
    # non-blank lines of the files written for it (headings included once).
    def check(original: str, heading: re.Pattern, entries: list[dict], directory: Path, label: str) -> None:
        _, sections = split_sections(original.split("\n"), heading)
        expected: list[str] = []
        for h, body in sections:
            expected.append(h)
            expected.extend(nonblank(body))
        rebuilt: list[str] = []
        last_heading = None
        for e in entries:
            file_lines = (directory / f"{e['name']}.md").read_text(encoding="utf-8").split("\n")
            if file_lines[0] != e["heading"]:
                sys.exit(f"{label}: {e['name']} does not start with its heading")
            if e["heading"] != last_heading:
                rebuilt.append(e["heading"])
                last_heading = e["heading"]
            rebuilt.extend(nonblank(file_lines[1:]))
        if rebuilt != expected:
            for i, (a, b) in enumerate(zip(rebuilt, expected)):
                if a != b:
                    sys.exit(f"{label}: first difference at non-blank line {i}:\n  files:    {a!r}\n  original: {b!r}")
            sys.exit(f"{label}: line counts differ: files {len(rebuilt)}, original {len(expected)}")
        print(f"{label}: {len(entries)} files reproduce every non-blank line of the original")

    check(decisions_text, DECISION_HEADING, decisions, DECISIONS_DIR, "decisions")
    check(verification_text, VERIFICATION_HEADING, records, VERIFICATION_DIR, "verification")

    # Headings are repeated in every file of a multi-decision section; say how
    # many words that adds so the before/after counts can be reconciled.
    repeated = sum(len(d["heading"].split()) for d in decisions) - sum(
        len(h.split()) for h in {d["heading"] for d in decisions}
    )
    print(f"decisions: {repeated} words of repeated section headings across the files")


if __name__ == "__main__":
    main()
