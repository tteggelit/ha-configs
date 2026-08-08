# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is the live `/config` directory for a self-hosted Home Assistant instance, checked into git.
There is no build step, package manager, or test suite — every YAML file here is read directly by
the running HA instance. "Deploying" a change means committing it and having HA pick it up (via
restart or a reload service), not running any tooling in this repo.

`secrets.yaml` is gitignored and does not exist in the repo; files reference secrets via `!secret
<key>`. Other gitignored paths (`.storage`, `.cloud`, `custom_components`, `deps`, `image`, `tts`,
`esphome/archive`) are runtime/local state, not source.

When writing or updating YAML in this repo, follow Home Assistant's own
[YAML Syntax](https://www.home-assistant.io/docs/configuration/yaml/) reference (indentation,
inline vs. multi-line strings, `!include`/`!secret` and other tags) and the
[YAML Style Guide](https://developers.home-assistant.io/docs/documenting/yaml-style-guide/) (key
ordering, quoting, and formatting conventions) rather than improvising formatting.

## Validating changes

There is no local linter or test runner. To check a change before it's live:
- YAML syntax only: `python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" <file>`
- Full HA config validation requires the running instance: Developer Tools → YAML → "Check
  Configuration" in the UI, or `ha core check` on the HA host itself. This repo has no way to run
  that check standalone since it depends on integrations/entities only the live instance knows about.

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
  named package.
- `automation: !include automations.yaml`, `script: !include scripts.yaml`,
  `scene: !include scenes.yaml` — top-level, not-package-specific definitions (many carry numeric
  `id:` values because they were originally created in the UI).
- `template: !include templates.yaml` — a handful of legacy-style template sensors, distinct from
  the newer trigger-based template sensors defined inline inside individual packages.
- `homekit: !include homekit.yaml` — two HomeKit bridges (Main, Amy), each with its own
  domain/entity include-exclude filter, exposing a curated entity set to Apple Home.
- `frontend.themes: !include_dir_merge_named themes` and HACS `lovelace-card-mod` for dashboard
  styling.

**`packages/`** is where most non-trivial logic lives. Each file is a self-contained feature bundle
named for the subsystem it implements (e.g. `irrigation.yaml`, `solar_array.yaml`,
`basement_lighting.yaml`, `thermostat_humidity.yaml`, `lightning_detection.yaml`,
`severe_weather.yaml`) and typically defines, together in one file: its own `input_*` helpers,
template sensors, scripts, and automations. When editing one subsystem, everything relevant is
usually in that single package file — you rarely need to hunt across other files.

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
- Entity IDs are HA-auto-generated from friendly names and can diverge from what you'd expect (e.g.
  a sensor named `"Met.no Forecast Cache"` becomes `sensor.irrigation_met_no_forecast_cache`, not
  `..._met_forecast_cache`) — check the actual entity_id rather than assuming it matches the
  `unique_id` or name.

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
