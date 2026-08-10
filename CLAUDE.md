# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the live `/config` directory for a self-hosted Home Assistant instance, checked into git.
There is no build step, package manager, or test suite — every YAML file here is read directly by
the running HA instance. "Deploying" a change means committing it and having HA pick it up (via
restart or a reload service), not running any tooling in this repo.

`secrets.yaml` is gitignored and does not exist in the repo; files reference secrets via `!secret
<key>`. `secrets.yaml.example` documents every key (no real values) and stands in for the real
file in CI and local ESPHome checks. Other gitignored paths (`.storage`, `.cloud`,
`custom_components`, `deps`, `image`, `tts`, `esphome/archive`) are runtime/local state, not
source. `.ssh/` is also gitignored — it holds the private deploy key
`scripts/commit_ha_version.sh` uses to auto-push `.HA_VERSION` bumps (see Validating changes
below); never let a key from there end up in a commit.

When writing or updating YAML in this repo, follow Home Assistant's own
[YAML Syntax](https://www.home-assistant.io/docs/configuration/yaml/) reference (indentation,
inline vs. multi-line strings, `!include`/`!secret` and other tags) and the
[YAML Style Guide](https://developers.home-assistant.io/docs/documenting/yaml-style-guide/) (key
ordering, quoting, and formatting conventions) rather than improvising formatting.

## Validating changes

Three independent tiers, each catching something the others can't:

- **Pre-commit** (laptop, one-time setup `pip install pre-commit && pre-commit install`,
  config in `.pre-commit-config.yaml`): `yamllint` (`.yamllint.yaml` — extends `default` with
  HA-specific tweaks; all the normal checks are enabled, including trailing whitespace, blank
  lines, and missing final newline, so don't reintroduce those), a tag-aware YAML syntax check
  (`scripts/hooks/check_yaml_syntax.py` — parses with constructors registered for HA's custom
  tags like `!secret`/`!include` instead of choking on them the way plain `yaml.safe_load`
  would), a secrets-drift check (`scripts/hooks/check_secrets_drift.py` — fails if a file
  references `!secret <key>` that isn't documented in `secrets.yaml.example`), a duplicate
  automation-id/script-key/scene-id check (`scripts/hooks/check_duplicate_ids.py` — see below),
  and ESPHome config validation on changed `esphome/*.yaml` files. Every hook here except the
  duplicate-id one only looks at staged files, since that's all pre-commit passes them.
- **CI** (`.github/workflows/validate.yml`, runs on every push/PR to `main`): the same
  yamllint/syntax/secrets-drift/duplicate-id checks, plus the actual `check_config` Home
  Assistant itself runs, via `frenck/action-home-assistant`, against `secrets.yaml.example` in
  place of the real (gitignored) `secrets.yaml`. This is the only tier that actually assembles
  every package together through HA's own loader, so it's what catches package-merge conflicts
  that aren't just an id/key collision (e.g. two packages setting conflicting values for the same
  scalar key) and schema errors invisible to a single-file check.
- **Host deploy** (`scripts/deploy.sh`, run on the HAOS host in place of a raw `git pull`):
  backs up, pulls, and runs `ha core check` before you decide whether to restart. This is the
  only tier with access to the live entity registry, so it's the last line of defense for wrong
  entity IDs or logic that only breaks against real state — nothing earlier in the chain can see
  that.

The duplicate-id check (`scripts/hooks/check_duplicate_ids.py`) is the one exception to
"pre-commit only sees staged files": since two files can collide even when only one of them is
being edited, its pre-commit hook ignores the staged-file list and always checks every
`packages/*.yaml` + `automations.yaml` together — automation `id:`, `script:` key, and scene
`id:` all merge into shared namespaces across those files at HA's package-merge time, and a
collision doesn't error there, it just lets one definition silently win.

For a broader pass beyond what pre-commit's per-file scoping covers — a refactor, a review of
changes across many files — run `scripts/validate.sh` from the repo root: the same
yamllint/syntax/secrets-drift/duplicate-id checks across every tracked YAML file, not just
staged ones. It bootstraps its own venv at `.venv-lint/` (gitignored) on first run. See the
`validate-repo` skill for more detail, and `migrate-to-package` for the procedure this repo uses
to move something out of a flat top-level file (or between packages) — both live under
`.claude/skills/`.

`.HA_VERSION` (the version CI's Home Assistant config-check pins against) is kept current
automatically rather than hand-maintained: `packages/config_repo_sync.yaml` runs
`scripts/commit_ha_version.sh` on every HA start, which commits and pushes `.HA_VERSION` only
when it actually changed (a real Core upgrade, not just a same-version restart), using a
dedicated, repo-scoped GitHub Deploy Key — not the personal credentials used for manual pushes
from that host. See that script's header comment for the one-time key setup, which is
deliberately manual, not automated, since it grants a new persistent write credential.

## Applying changes on the live instance

- New/removed **packages**, or new helper entities (`input_boolean`, `input_number`,
  `input_datetime`, `input_select`, `input_button`) anywhere: require a **full HA restart**, not
  just a reload.
- Editing an existing **automation**: `automation.reload` (or Settings → Automations → reload).
- Editing an existing **script**: `script.reload`.
- Editing an existing **scene**: `scene.reload`.
- Editing **template** sensors defined under a `template:` key: usually needs a restart if the
  trigger/sensor structure changed, not just a value tweak.

## Architecture

`configuration.yaml` is the entry point. It wires together:
- `homeassistant.packages: !include_dir_named packages` — every file in `packages/` is loaded as a
  named package. This is now where essentially everything lives: automations, scripts, scenes,
  and template sensors alike, each defined under its subsystem's package file.
- `automation: !include automations.yaml` — holds exactly one automation now (Leak Detection &
  Notifier, a single blueprint stanza with no natural subsystem package to live in). There is no
  more `script:`/`scene:`/`template:` top-level include: `scripts.yaml`, `scenes.yaml`, and
  `templates.yaml` were fully migrated into packages and deleted, along with their includes here.
  If you're looking for a script, scene, or template sensor, it's in a package, not a flat
  top-level file — `grep -rl <name> packages/` beats guessing which file.
- `homekit: !include homekit.yaml` — two HomeKit bridges (Main, Amy), each with its own
  domain/entity include-exclude filter, exposing a curated entity set to Apple Home.
- `frontend.themes: !include_dir_merge_named themes` and HACS `lovelace-card-mod` for dashboard
  styling.

**`packages/`** is where all non-trivial logic lives, one file per subsystem (e.g.
`irrigation.yaml`, `solar_array.yaml`, `basement_lighting.yaml`, `basement.yaml` — non-lighting
basement automations, kept separate from `basement_lighting.yaml` on purpose — `thermostat_humidity.yaml`,
`lightning_detection.yaml`, `severe_weather.yaml`, `security.yaml`, `presence.yaml`,
`maintenance.yaml`, and the per-area lighting packages: `kitchen_lighting.yaml`,
`exterior_lighting.yaml`, `master_closet_lighting.yaml`, `living_room_lighting.yaml`,
`grow_tent.yaml`). Each package typically defines, together in one file: its own `input_*`
helpers, template sensors, scripts, and automations for that subsystem. When editing one
subsystem, everything relevant is usually in that single package file — you rarely need to hunt
across other files.

One deliberate exception: **`lighting_control.yaml`** holds generic, parametrized light-control
scripts (color-cycle, brightness step, etc.) that take the target light(s) and a reference light
as input — it is not scoped to any one room or remote type. If you're adding light-control logic
that's reusable across multiple physical remotes or rooms, it belongs here, not duplicated into
or coupled to whichever package happens to trigger it first.

Recurring patterns worth knowing before editing packages:
- **Forecast fetching**: several packages (`irrigation.yaml`, `owm_hourly_forecast.yaml`) use
  trigger-based template sensors that call the `weather.get_forecasts` service and cache a few
  derived numbers as attributes, because the old `forecast` attribute on weather entities was
  removed in HA 2024.3. Don't reintroduce `state_attr(weather_entity, 'forecast')`.
- **Debug logging toggle**: packages like `irrigation.yaml` gate verbose `logbook.log` calls behind
  an `input_boolean.*_debug` helper so gate/condition evaluation can be inspected without spamming
  the log by default.
- **Notify fan-out**: an `input_select` of human-readable device names is resolved by a template
  sensor into a list of `notify.*` entity IDs (a `device_map`), then iterated with
  `repeat.for_each` — used so dashboards can offer a device picker without hardcoding notify targets
  in every automation.
- **Toggle scripts for dashboards**: some packages expose a `script.*_toggle_*` wrapper that starts
  or cancels a long-running script based on its current state, because Mushroom template cards
  can't evaluate Jinja2 in `tap_action`.
- **Shared scripts over duplicated automations**: where the same action sequence used to be
  copy-pasted across two or three trigger paths (e.g. `security.yaml`'s `secure_front_door`,
  `secure_garage`, `house_lights_off`, each called from more than one alarm-state automation),
  it's now one script called from each caller. Prefer this over re-copying a sequence when adding
  a new trigger path that needs the same actions.
- Entity IDs are HA-auto-generated from friendly names and can diverge from what you'd expect (e.g.
  a sensor named `"Met.no Forecast Cache"` becomes `sensor.irrigation_met_no_forecast_cache`, not
  `..._met_forecast_cache`) — check the actual entity_id rather than assuming it matches the
  `unique_id` or name. This matters even more for scripts with no `unique_id:`: their YAML key
  *is* their entity identity, and renaming them in the UI changes the displayed name but not that
  key — a source of confusion worth double-checking against, not assuming away.

**Other directories:**
- `blueprints/automation|script|template/` — a mix of official Home Assistant blueprints
  (`homeassistant/`) and custom ones by other authors, organized in per-author subfolders.
- `esphome/` — ESPHome device firmware YAML (air quality sensor, Bluetooth proxies). These compile
  and flash to physical ESP32 devices separately from HA itself; `esphome/archive` is gitignored.
- `zigbee2mqtt/` — Zigbee2MQTT bridge configuration and versioned config backups; some Zigbee
  devices go through Z2M/MQTT rather than ZHA.
- `zhacustomquirks/` — custom ZHA quirks (e.g. `inovelli/VZM32SN.py`) for devices needing behavior
  beyond zigpy's built-in quirks.
- `dashboards/` — standalone Lovelace dashboard YAML.
- `www/community/` — HACS-installed frontend resources (card-mod, button-card, mushroom,
  auto-entities, ha-map-card, stack-in-card, apexcharts-card, blitzortung-lightning-card).
