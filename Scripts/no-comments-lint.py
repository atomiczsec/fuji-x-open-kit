#!/usr/bin/env python3
"""Ban every //, ///, /* */, and /** */ comment in Swift sources.

The only exception is the required SwiftPM directive on line 1 of Package.swift:
  // swift-tools-version:…
#warning / #error are compiler directives, not comments, and are ignored.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT_ROOTS = ("Sources", "Tests", "App")
EXTRA_FILES = ("Package.swift",)

TOOLS_VERSION = re.compile(r"^\s*swift-tools-version:\S+$")


def iter_swift_files() -> list[Path]:
    files: list[Path] = []
    for name in EXTRA_FILES:
        path = ROOT / name
        if path.is_file():
            files.append(path)
    for folder in SWIFT_ROOTS:
        base = ROOT / folder
        if base.is_dir():
            files.extend(sorted(base.rglob("*.swift")))
    return files


def strip_strings_and_find_comments(text: str) -> list[tuple[int, str, str]]:
    """Return (line_number, kind, body) for //, ///, and /* */ comments.

    kind is 'line', 'doc', or 'block'. Strings are skipped so URLs in string
    literals do not look like comments.
    """
    findings: list[tuple[int, str, str]] = []
    i = 0
    n = len(text)
    line = 1

    def peek(k: int = 0) -> str:
        j = i + k
        return text[j] if j < n else ""

    while i < n:
        c = text[i]
        nxt = peek(1)

        if c == "\n":
            line += 1
            i += 1
            continue

        if c in "\"'":
            quote = c
            i += 1
            while i < n:
                ch = text[i]
                if ch == "\\" and i + 1 < n:
                    i += 2
                    continue
                if ch == "\n":
                    line += 1
                    i += 1
                    continue
                if ch == quote:
                    i += 1
                    break
                i += 1
            continue

        if c == "#" and nxt == '"':
            hashes = 0
            while peek(hashes) == "#":
                hashes += 1
            if peek(hashes) != '"':
                i += 1
                continue
            i += hashes + 1
            closing = '"' + ("#" * hashes)
            while i < n:
                if text.startswith(closing, i):
                    i += len(closing)
                    break
                if text[i] == "\n":
                    line += 1
                i += 1
            continue

        if c == "/" and nxt == "/":
            start = i + 2
            doc = peek(2) == "/"
            if doc:
                start = i + 3
            end = start
            while end < n and text[end] != "\n":
                end += 1
            body = text[start:end]
            findings.append((line, "doc" if doc else "line", body))
            i = end
            continue

        if c == "/" and nxt == "*":
            block_start_line = line
            block_parts: list[str] = []
            i += 2
            while i < n:
                if text[i] == "*" and peek(1) == "/":
                    i += 2
                    findings.append((block_start_line, "block", "".join(block_parts)))
                    break
                if text[i] == "\n":
                    line += 1
                block_parts.append(text[i])
                i += 1
            continue

        i += 1

    return findings


def is_allowed(path: Path, line_no: int, kind: str, body: str) -> bool:
    if path.name == "Package.swift" and line_no == 1 and kind == "line":
        return bool(TOOLS_VERSION.match(body))
    return False


def main() -> int:
    violations: list[str] = []
    files = iter_swift_files()
    for path in files:
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(ROOT)
        for line_no, kind, body in strip_strings_and_find_comments(text):
            if is_allowed(path, line_no, kind, body):
                continue
            preview = body.strip()
            if len(preview) > 80:
                preview = preview[:77] + "..."
            label = {"line": "//", "block": "/* */", "doc": "///"}[kind]
            violations.append(f"{rel}:{line_no}: banned {label} comment: {preview}")

    if violations:
        print("no-comments lint failed:", file=sys.stderr)
        for v in violations:
            print(f"  {v}", file=sys.stderr)
        print(
            "\nAllowed: only // swift-tools-version:… on line 1 of Package.swift.",
            file=sys.stderr,
        )
        return 1

    print(f"no-comments lint passed ({len(files)} Swift files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
