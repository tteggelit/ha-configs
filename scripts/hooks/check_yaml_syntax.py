#!/usr/bin/env python3
"""Parse-check YAML files using Home Assistant's custom tag set.

Plain `yaml.safe_load` raises on HA's custom tags (!secret, !include, ...),
so a generic YAML syntax check would fail on every HA config file. This
registers no-op constructors for those tags -- just enough to let PyYAML
parse the document structure and catch real syntax errors (bad indentation,
unclosed quotes, duplicate keys, etc.) without attempting to resolve what
the tags actually mean.
"""

import sys

import yaml

HA_TAGS = [
    "!include",
    "!include_dir_list",
    "!include_dir_named",
    "!include_dir_merge_list",
    "!include_dir_merge_named",
    "!secret",
    "!env_var",
    "!input",
]


class HAConfigLoader(yaml.SafeLoader):
    pass


def _passthrough_constructor(loader, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


for tag in HA_TAGS:
    HAConfigLoader.add_constructor(tag, _passthrough_constructor)


def check_file(path: str) -> list[str]:
    errors = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            list(yaml.load_all(f, Loader=HAConfigLoader))
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        if mark is not None:
            errors.append(f"{path}:{mark.line + 1}:{mark.column + 1}: {exc}")
        else:
            errors.append(f"{path}: {exc}")
    except UnicodeDecodeError as exc:
        errors.append(f"{path}: {exc}")
    return errors


def main(argv: list[str]) -> int:
    all_errors = []
    for path in argv:
        all_errors.extend(check_file(path))

    for error in all_errors:
        print(error)

    return 1 if all_errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
