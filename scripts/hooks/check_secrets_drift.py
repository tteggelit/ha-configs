#!/usr/bin/env python3
"""Fail if any `!secret <key>` used in tracked YAML is missing from
secrets.yaml.example.

Keeps the example file honest as a byproduct of normal editing -- add a
new `!secret some_key` reference anywhere and this fails until
secrets.yaml.example documents it. secrets.yaml.example is what both CI
and local `esphome config` runs use in place of the real (gitignored)
secrets.yaml, so a missing key there means those checks silently pass
with an undefined secret rather than catching a real config error.

Finds `!secret` usages by walking the composed YAML node tree rather than
regexing raw text -- a text regex can't tell a real `!secret foo` tag
apart from the same characters appearing in a comment or description
string (e.g. this file's own docstring), which produces false positives
on any YAML file that talks about secrets without actually using one.
`yaml.compose_all` only builds the node graph (it doesn't construct
Python objects), so it doesn't need constructors registered for HA's
custom tags to walk the tree.
"""

import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EXAMPLE_SECRETS = REPO_ROOT / "secrets.yaml.example"


def find_secret_keys(path: str) -> list[str]:
    keys = []

    def walk(node):
        if node.tag == "!secret" and isinstance(node, yaml.ScalarNode):
            keys.append(node.value)
        elif isinstance(node, yaml.MappingNode):
            for key_node, value_node in node.value:
                walk(key_node)
                walk(value_node)
        elif isinstance(node, yaml.SequenceNode):
            for item_node in node.value:
                walk(item_node)

    with open(path, "r", encoding="utf-8") as f:
        try:
            for doc in yaml.compose_all(f, Loader=yaml.SafeLoader):
                if doc is not None:
                    walk(doc)
        except yaml.YAMLError:
            # Malformed YAML is check_yaml_syntax.py's job to report.
            return []

    return keys


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
        for key in find_secret_keys(path):
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
