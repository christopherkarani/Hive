#!/usr/bin/env python3
"""
Lightweight public-API mapper for Hive source checkouts.

This is a heuristic scanner (regex-based), not a full Swift parser.

Usage:
  python3 scripts/hive_api_map.py --root /path/to/Hive
"""

from __future__ import annotations

import argparse
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


PUBLIC_DECL_RE = re.compile(
    r"^public\s+(?:final\s+)?(struct|enum|protocol|class|actor|typealias|func|var|let)\s+([A-Za-z_]\w*)"
)


@dataclass(frozen=True)
class Decl:
    kind: str
    name: str
    file: Path
    line: int


def iter_swift_files(sources_root: Path) -> Iterable[Path]:
    for path in sources_root.rglob("*.swift"):
        # Skip build artifacts or hidden directories defensively.
        parts = {p.lower() for p in path.parts}
        if ".build" in parts or ".swiftpm" in parts:
            continue
        yield path


def scan_file(path: Path) -> list[Decl]:
    decls: list[Decl] = []
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_text(encoding="utf-8", errors="replace")

    for idx, line in enumerate(text.splitlines(), start=1):
        m = PUBLIC_DECL_RE.match(line)
        if not m:
            continue
        kind, name = m.group(1), m.group(2)
        decls.append(Decl(kind=kind, name=name, file=path, line=idx))
    return decls


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(os.getcwd()),
        help="Repo root (or a directory containing libs/hive/Sources). Defaults to CWD.",
    )
    args = parser.parse_args()

    root: Path = args.root.resolve()
    sources_root = root / "libs" / "hive" / "Sources"
    if not sources_root.exists():
        raise SystemExit(f"Expected Swift sources at: {sources_root}")

    modules = sorted([p for p in sources_root.iterdir() if p.is_dir()], key=lambda p: p.name)
    print("# Hive Public API (Heuristic Map)")
    print()
    print(f"- Root: `{root}`")
    print(f"- Sources: `{sources_root}`")
    print("- Note: This is regex-based; it may miss symbols declared across multiple lines.")
    print()

    for module_dir in modules:
        decls: list[Decl] = []
        for swift_file in iter_swift_files(module_dir):
            decls.extend(scan_file(swift_file))

        # De-dupe by (kind, name) to keep the output readable.
        seen: set[tuple[str, str]] = set()
        unique: list[Decl] = []
        for d in decls:
            key = (d.kind, d.name)
            if key in seen:
                continue
            seen.add(key)
            unique.append(d)

        unique.sort(key=lambda d: (d.kind, d.name))

        print(f"## {module_dir.name}")
        print()
        print(f"- Files scanned: {len(list(iter_swift_files(module_dir)))}")
        print(f"- Public decls (unique): {len(unique)}")
        print()

        if not unique:
            continue

        for d in unique[:60]:
            rel = d.file.relative_to(root)
            print(f"- `{d.kind} {d.name}` ({rel}:{d.line})")

        if len(unique) > 60:
            print(f"- ... ({len(unique) - 60} more)")
        print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

