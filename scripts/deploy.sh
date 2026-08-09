#!/usr/bin/env bash
# Run this on the live HAOS host in place of a raw `git pull`.
#
# Semi-automated: takes a full backup before pulling and validates the
# config after pulling, but never restarts Home Assistant itself -- you
# review the result and run `ha core restart` yourself.
#
# IMPORTANT -- two things in here are marked NEEDS VERIFICATION below.
# They're written from documented Supervisor CLI/API behavior but
# haven't been exercised against this host's actual Supervisor version.
# Dry-run this script (see the plan's Verification section) before
# relying on it for a real deploy.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

log() { printf '\n=== %s ===\n' "$1"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd ha
require_cmd git
require_cmd python3

# ---------------------------------------------------------------------------
# 1. Backup
# ---------------------------------------------------------------------------
BACKUP_NAME="pre-deploy-$(date +%Y%m%d-%H%M%S)"
log "Creating backup: $BACKUP_NAME"

BACKUP_JSON="$(ha backups new --name "$BACKUP_NAME" --raw-json)"
BACKUP_RESULT=$?

if [ "$BACKUP_RESULT" -ne 0 ]; then
  echo "Backup command failed -- aborting before pulling any changes." >&2
  echo "$BACKUP_JSON" >&2
  exit 1
fi

# NEEDS VERIFICATION: this assumes `ha backups new --raw-json` blocks
# until the backup job finishes and returns the created backup's slug at
# data.slug. If your Supervisor version returns immediately (job queued,
# not complete) instead, this needs a poll loop against `ha jobs list` or
# `ha backups info <slug>` before proceeding to the pull below -- do not
# trust this section until you've confirmed which behavior your host has.
BACKUP_SLUG="$(echo "$BACKUP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("data", {}).get("slug", "unknown"))' 2>/dev/null || echo "unknown")"

if [ "$BACKUP_SLUG" = "unknown" ]; then
  echo "Could not parse a backup slug from the response below -- confirm the backup actually completed before continuing." >&2
  echo "$BACKUP_JSON" >&2
  exit 1
fi

log "Backup complete (slug: $BACKUP_SLUG)"

# ---------------------------------------------------------------------------
# 2. Pull
# ---------------------------------------------------------------------------
log "Pulling latest changes"
BEFORE_REV="$(git rev-parse HEAD)"

if ! git pull; then
  echo "git pull failed -- working tree left as-is, nothing changed." >&2
  exit 1
fi

AFTER_REV="$(git rev-parse HEAD)"

if [ "$BEFORE_REV" = "$AFTER_REV" ]; then
  log "Already up to date (nothing to validate)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Validate
# ---------------------------------------------------------------------------
log "Running config check"
CHECK_OUTPUT="$(ha core check 2>&1)"
CHECK_STATUS=$?

# NEEDS VERIFICATION: there's an open upstream issue where `ha core check`
# looks for configuration.yaml under /root/.homeassistant instead of
# /config on some HAOS releases (home-assistant/core#156294). If that's
# the case on this host, fall back to checking the Core container
# directly. This requires `docker exec` to work from wherever this script
# runs, which needs the Advanced SSH & Web Terminal add-on's Protection
# Mode turned OFF (it's ON by default, and intentionally so -- disabling
# it grants that add-on Docker socket access to the whole host). Leave
# Protection Mode on by default and only disable it on demand if this
# fallback actually gets hit.
if echo "$CHECK_OUTPUT" | grep -qi "configuration.yaml not found"; then
  echo "ha core check appears to have hit the known /root/.homeassistant path bug -- falling back to a direct check inside the Core container." >&2
  CHECK_OUTPUT="$(docker exec homeassistant python3 -m homeassistant --script check_config -c /config 2>&1)"
  CHECK_STATUS=$?
fi

echo "$CHECK_OUTPUT"

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------
log "Result"
echo "Pulled ${BEFORE_REV:0:7} -> ${AFTER_REV:0:7}"

if [ "$CHECK_STATUS" -eq 0 ]; then
  echo "Config check passed."
  echo "Restart when ready: ha core restart"
  exit 0
else
  echo "Config check FAILED (see output above)."
  echo "Home Assistant has NOT been restarted -- it is still running on the previous config."
  echo "Pre-pull backup slug: $BACKUP_SLUG"
  echo "To undo just the file changes:   git reset --hard $BEFORE_REV"
  echo "To restore the full backup:      ha backups restore $BACKUP_SLUG"
  exit 1
fi
