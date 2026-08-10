#!/usr/bin/env python3
"""Fail if two files define the same automation id, script key, or scene id.

Home Assistant merges `automation:`, `script:`, and `scene:` blocks across
every package plus the top-level includes into single shared namespaces.
Two files defining the same automation `id:` or `script:` key don't error
at merge time -- HA (or a stray `yaml.load`) just lets the later one win
silently, so the collision has to be caught by walking the raw YAML
ourselves rather than relying on a config check to surface it.

Uses `yaml.compose_all` (structure-aware, no constructors needed) to walk
the node tree, matching the approach in check_secrets_drift.py -- HA's
custom tags (`!secret`, `!include`, ...) don't need to resolve for this,
only the plain mapping/sequence structure around `id:`/`script:` keys
does.
"""

import sys
from collections import defaultdict

import yaml


def _scalar(node):
    return node.value if isinstance(node, yaml.ScalarNode) else None


def _mapping_items(node):
    if isinstance(node, yaml.MappingNode):
        return node.value
    return []


def find_automation_ids(doc) -> list[tuple[str, int]]:
    """`doc` is either a bare sequence (automations.yaml) or a mapping with
    an `automation:` key (a package) whose value is a sequence of mappings.
    """
    found = []

    if isinstance(doc, yaml.SequenceNode):
        items = doc.value
    elif isinstance(doc, yaml.MappingNode):
        items = []
        for key_node, value_node in doc.value:
            if _scalar(key_node) == "automation" and isinstance(
                value_node, yaml.SequenceNode
            ):
                items = value_node.value
                break
    else:
        items = []

    for item in items:
        for key_node, value_node in _mapping_items(item):
            if _scalar(key_node) == "id":
                found.append((_scalar(value_node), value_node.start_mark.line + 1))
    return found


def find_script_keys(doc) -> list[tuple[str, int]]:
    if not isinstance(doc, yaml.MappingNode):
        return []
    found = []
    for key_node, value_node in doc.value:
        if _scalar(key_node) == "script" and isinstance(value_node, yaml.MappingNode):
            for script_key_node, _ in value_node.value:
                name = _scalar(script_key_node)
                if name is not None:
                    found.append((name, script_key_node.start_mark.line + 1))
    return found


def find_scene_ids(doc) -> list[tuple[str, int]]:
    if not isinstance(doc, yaml.MappingNode):
        return []
    found = []
    for key_node, value_node in doc.value:
        if _scalar(key_node) == "scene" and isinstance(value_node, yaml.SequenceNode):
            for item in value_node.value:
                for scene_key_node, scene_value_node in _mapping_items(item):
                    if _scalar(scene_key_node) == "id":
                        found.append(
                            (_scalar(scene_value_node), scene_value_node.start_mark.line + 1)
                        )
    return found


def collect(argv: list[str]):
    automation_ids = defaultdict(list)
    script_keys = defaultdict(list)
    scene_ids = defaultdict(list)

    for path in argv:
        with open(path, "r", encoding="utf-8") as f:
            try:
                docs = list(yaml.compose_all(f, Loader=yaml.SafeLoader))
            except yaml.YAMLError:
                # Malformed YAML is check_yaml_syntax.py's job to report.
                continue

        for doc in docs:
            if doc is None:
                continue
            for value, line in find_automation_ids(doc):
                if value is not None:
                    automation_ids[value].append(f"{path}:{line}")
            for value, line in find_script_keys(doc):
                script_keys[value].append(f"{path}:{line}")
            for value, line in find_scene_ids(doc):
                if value is not None:
                    scene_ids[value].append(f"{path}:{line}")

    return automation_ids, script_keys, scene_ids


def main(argv: list[str]) -> int:
    automation_ids, script_keys, scene_ids = collect(argv)

    problems = []
    for label, table in (
        ("automation id", automation_ids),
        ("script key", script_keys),
        ("scene id", scene_ids),
    ):
        for value, locations in sorted(table.items()):
            if len(locations) > 1:
                problems.append(f"duplicate {label} '{value}':\n    " + "\n    ".join(locations))

    if not problems:
        return 0

    print("Duplicate ids/keys found across merged files:\n")
    print("\n\n".join(problems))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
