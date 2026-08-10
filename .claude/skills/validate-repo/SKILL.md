---
name: validate-repo
description: Run the fast, laptop-side config checks (yamllint, HA-tag-aware syntax, secrets drift, duplicate automation/script/scene ids) across the whole repo, not just staged files. Use before or after any broad multi-file change -- a refactor, a review pass, a batch migration -- where pre-commit's staged-files-only scope wouldn't catch everything touched.
---

# Validate repo

Runs the checks documented in `CLAUDE.md`'s "Validating changes" section, but across every
tracked YAML file in the repo rather than only what's staged -- pre-commit only ever sees staged
files, which misses anything edited but not yet `git add`ed, or edited in a prior commit you're
now reviewing.

## Steps

1. Run `scripts/validate.sh` from the repo root. It bootstraps its own venv at `.venv-lint/`
   (gitignored) on first run — pyyaml and yamllint aren't installed system-wide, and a plain
   `pip install` fails under PEP 668 in most sandboxed environments, so let the script handle it
   rather than reaching for `pip install --break-system-packages` or similar.
2. It runs, in order: `yamllint -c .yamllint.yaml`, `scripts/hooks/check_yaml_syntax.py`
   (HA-tag-aware — parses `!secret`/`!include`/etc. instead of choking on them),
   `scripts/hooks/check_secrets_drift.py` (every `!secret <key>` used anywhere must be documented
   in `secrets.yaml.example`), and `scripts/hooks/check_duplicate_ids.py` (catches two packages
   defining the same automation `id:`, the same `script:` key, or the same scene `id:` — these
   merge into shared namespaces across `packages/*.yaml` + `automations.yaml`, and a collision
   doesn't error at merge time, it just silently lets one definition win).
3. Fix findings file by file and re-run until it exits 0. Real errors (non-zero exit) block;
   yamllint's own warnings (as opposed to `[error]` lines) don't fail the run but are worth a
   glance — the repo runs with all of yamllint's default rules enabled (trailing whitespace,
   blank lines, comment spacing, etc. included), so new warnings usually mean new style drift,
   not a pre-existing one.

## What this does not cover

This is the fast tier only. It does not run:
- The ESPHome config check (`esphome config <file>`) — needs the `esphome` package installed,
  which is a heavy dependency not worth carrying for a routine check. Covered by
  `.pre-commit-config.yaml`'s `esphome-config` hook and by CI.
- The actual Home Assistant `check_config` — needs a real HA core install or the
  `frenck/action-home-assistant` container CI uses. This is what catches package-merge schema
  errors (e.g. two packages defining conflicting values for the same non-list key) that pure YAML
  validation can't see, since nothing short of HA's own config loader actually assembles every
  package together. Runs in `.github/workflows/validate.yml` on every push, and via
  `scripts/deploy.sh`'s `ha core check` step on the host.
- Anything that needs the live entity registry (wrong entity IDs, logic that only breaks against
  real state). Only `scripts/deploy.sh`, run on the actual HAOS host, can catch that.

So a clean `scripts/validate.sh` run means "safe to push," not "safe to restart the live
instance on" — CI and the host check are still the tiers that catch what this one structurally
can't.
