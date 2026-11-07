#!/usr/bin/env python3
"""Print SHA-256 fingerprints for the exact build inputs, excluding credentials."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
paths = [root / "Package.swift"]
for directory in ("App", "Sources", "Tests", "Config", "RheaRFSpanner.xcodeproj", "scripts", ".github/workflows"):
    paths += [p for p in (root / directory).rglob("*") if p.is_file()]
entries = {}
for path in sorted(paths):
    relative = path.relative_to(root).as_posix()
    if path.name == "Signing.local.xcconfig" or "__pycache__" in path.parts:
        continue
    entries[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
print(json.dumps(entries, indent=2, sort_keys=True))

