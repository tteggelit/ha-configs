#!/usr/bin/env python3
"""Fail if any `!secret <key>` used in tracked YAML is missing from
secrets.yaml.example.

Keeps the example file honest as a byproduct of normal editing -- add a
new `!secret some_key` reference anywhere and this fails until
secrets.yaml.example documents it. secrets.yaml.example is what both CI
and local `esphome config` runs use in place of the real (gitignored)
secrets.yaml, so a missing key there means those checks silently pass
with an undefined secret rather than catching a real config error.
"""

import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EXAMPLE_SECRETS = REPO_ROOT / "secrets.yaml.example"
SECRET_RE = re.compile(r"!secret\s+([A-Za-z0-9_]+)")


def main(argv: list[str]) -> int:
    if not EXAMPLE_SECRETS.exists():
        print(f"{EXAMPLE_SECRETS} does not exist -- cannot check secrets drift")
        return 1

    with open(EXAMPLE_SECRETS, "r", encoding="utf-8") as f:
        documented = set(yaml.safe_load(f) or {})

    used: dict[str, list[str]] = {}
    for path in argv:
        if Path(path).resolve() == EXAMPLE_SECRETS:
            continue
        with open(path, "r", encoding="utf-8") as f:
            for key in SECRET_RE.findall(f.read()):
                used.setdefault(key, []).append(path)

    missing = sorted(set(used) - documented)
    if not missing:
        return 0

    print("secrets.yaml.example is missing keys referenced via !secret:")
    for key in missing:
        files = ", ".join(used[key])
        print(f"  {key}  (used in: {files})")
    print(f"\nAdd these to {EXAMPLE_SECRETS} with a dummy value.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
