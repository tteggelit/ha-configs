---
name: migrate-to-package
description: Move an automation, script, scene, or template sensor out of a flat top-level file (or out of one package into a better-fitting one) into its subsystem-scoped package, following this repo's established packages/ architecture. Use whenever new automations have landed in automations.yaml via the UI, or something's been outgrown by the package it started in.
---

# Migrate a definition into its package

This repo keeps almost everything in `packages/`, one file per subsystem (see `CLAUDE.md`'s
Architecture section for the current layout). Home Assistant's UI still writes new automations
into `automations.yaml` by default, so this situation recurs: something needs to move from a flat
file, or from a package it's outgrown, into the package it actually belongs in. This was the
exact procedure used to migrate everything out of `scripts.yaml`/`scenes.yaml`/`templates.yaml`
in an earlier pass — those files no longer exist, but the workflow that emptied them applies to
whatever lands in `automations.yaml` next.

## Steps

1. **Read the exact source content first.** Use the Read tool on the specific line range, not a
   paraphrase or a recollection from an earlier read in the same session — files shift line
   numbers as you edit them. Note the automation `id:` / script key / scene `id:`, since it must
   travel unchanged (HA UI history, traces, and any `script.<name>` / `automation.<id>` reference
   elsewhere in the repo depend on it staying the same).

2. **Decide the target package.**
   - If an existing package clearly owns this subsystem (e.g. an irrigation automation goes in
     `packages/irrigation.yaml`), use it.
   - If nothing fits, propose a new package name and ask before creating it — this repo's package
     boundaries have been shaped by explicit back-and-forth before (e.g. keeping non-lighting
     basement automations in a separate `basement.yaml` rather than folding into
     `basement_lighting.yaml`; keeping generic remote-agnostic light-control scripts in
     `lighting_control.yaml` rather than coupling them to whichever remote's package triggers
     them first). Don't assume a boundary the way that first pass didn't — ask.
   - If the thing being migrated is action logic identical or near-identical to something already
     duplicated elsewhere, this is also the moment to dedup into one shared, parametrized script
     rather than relocating N copies — don't migrate duplication into a package just because
     that's where the original flat-file copies happened to be.

3. **Write it into the target package, preserving content exactly.** If the package already has
   the relevant top-level key (`automation:`, `script:`, `scene:`, `template:`), append into that
   existing block — creating a second one is a duplicate-YAML-key error that only shows up as a
   confusing yamllint/parse failure, not a clear message about what went wrong. Keep the same
   indentation and quoting style already used in that file rather than reformatting incidentally.

4. **Remove the migrated content from the source file** via an exact-match edit — don't leave a
   stale copy behind.

5. **If the source file is now fully empty of real content** (this happened for
   `scripts.yaml`/`scenes.yaml`/`templates.yaml`), delete it and remove its
   `!include` line from `configuration.yaml`. Don't leave a zero-content file included just to
   avoid touching `configuration.yaml`.

6. **Validate.** Run the `validate-repo` skill (`scripts/validate.sh`) — this is exactly the case
   its duplicate-id check exists for, along with catching any syntax slip from the move itself.

7. **Grep the whole repo for stray references** to the old location or to the entity id/name,
   in case a dashboard, script, or another automation pointed at it directly.

8. **Report what moved and where**, and confirm the restart/reload implication per `CLAUDE.md`'s
   "Applying changes on the live instance" section (a new package file needs a full restart; an
   edit to an existing package's automation/script usually only needs a reload — but adding a new
   package for the first time always needs one).

## What not to do

- Don't commit or push without being asked — this repo's working pattern is propose-then-confirm
  at each step, not batch-and-ship.
- Don't rename the migrated entity's `id:` / script key / scene `id:` "while you're in there,"
  even if it looks inconsistent with the target package's naming — that's a separate, deliberate
  decision, not a side effect of a move. Legacy (no `unique_id:`) scripts in particular use their
  YAML key as their actual entity identity; renaming the key silently changes what entity the
  script is going forward, decoupling it from whatever the UI currently displays if it was ever
  renamed there.
