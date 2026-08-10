#!/usr/bin/env bash
# Run the fast, laptop-side config checks across the whole repo, not just
# staged files -- pre-commit only ever sees what's staged, so this is what
# to run before a broad pass (a refactor, a review of someone else's
# branch) where the interesting files were never `git add`ed one at a time.
#
# Bootstraps its own venv under .venv-lint/ (gitignored) since this
# environment doesn't have yamllint/pyyaml installed system-wide and a
# plain `pip install` fails under PEP 668. Reuses that venv on later runs
# instead of reinstalling every time.
#
# Does NOT run the ESPHome config check or the real Home Assistant
# check_config -- both need heavier dependencies (the `esphome` package;
# a container with HA core) that aren't worth carrying for a routine
# local check. Those run in CI (.github/workflows/validate.yml) and, for
# check_config, on the host via deploy.sh -- this script is a fast
# approximation of the "would this even parse and merge" question, not a
# replacement for either.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

VENV_DIR="$REPO_DIR/.venv-lint"
YAMLLINT_VERSION="1.38.0"  # keep in sync with .pre-commit-config.yaml and validate.yml

if [ ! -x "$VENV_DIR/bin/yamllint" ]; then
  echo "=== Setting up $VENV_DIR (first run only) ==="
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --quiet "yamllint==${YAMLLINT_VERSION}" pyyaml
fi

PY="$VENV_DIR/bin/python"
YAMLLINT="$VENV_DIR/bin/yamllint"

mapfile -t FILES < <(git ls-files '*.yaml' '*.yml' | grep -v '^www/')

STATUS=0

echo "=== yamllint (${#FILES[@]} files) ==="
if ! "$YAMLLINT" -c .yamllint.yaml "${FILES[@]}"; then
  STATUS=1
fi

echo
echo "=== HA-tag-aware YAML syntax check ==="
if ! "$PY" scripts/hooks/check_yaml_syntax.py "${FILES[@]}"; then
  STATUS=1
fi

echo
echo "=== secrets.yaml.example drift check ==="
if ! "$PY" scripts/hooks/check_secrets_drift.py "${FILES[@]}"; then
  STATUS=1
fi

echo
echo "=== duplicate automation id / script key / scene id check ==="
mapfile -t MERGE_FILES < <(git ls-files 'packages/*.yaml' 'automations.yaml')
if ! "$PY" scripts/hooks/check_duplicate_ids.py "${MERGE_FILES[@]}"; then
  STATUS=1
fi

echo
if [ "$STATUS" -eq 0 ]; then
  echo "All checks passed."
else
  echo "One or more checks failed -- see output above."
fi

exit "$STATUS"
