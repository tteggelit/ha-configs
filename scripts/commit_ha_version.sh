#!/usr/bin/env bash
# Commits and pushes .HA_VERSION when it changes, so CI's config-check
# (.github/workflows/validate.yml) validates against the version actually
# running on this host instead of a hand-maintained, easily-stale pin.
#
# Invoked by packages/config_repo_sync.yaml via shell_command.commit_ha_version
# on every Home Assistant start. HA rewrites .HA_VERSION on every start, but
# this only produces a commit when the content actually changed (i.e. a real
# Core upgrade) -- the git diff guard below makes most starts a no-op.
#
# Runs inside the HA Core container (confirmed to have git 2.54.0 and
# OpenSSH 10.3p1 present). Uses a dedicated, repo-scoped GitHub Deploy Key
# rather than the personal SSH-agent-forwarded credentials used for manual
# pushes -- GIT_SSH_COMMAND below is set only for this script's own git
# push, so it never affects interactive sessions on this host.
#
# Setup this script depends on (one-time, done manually -- not automated
# here on purpose, since it grants a new persistent write credential):
#   1. ssh-keygen -t ed25519 -f /config/.ssh/ha_version_bump_deploy_key -N ""
#      (run ON the host, so the private key never crosses the network)
#   2. Add the .pub file's contents as a Deploy Key on the GitHub repo,
#      with "Allow write access" checked.
#   3. Confirm /config/.ssh/ is gitignored (it is, see .gitignore) before
#      doing step 1 -- never let this key end up in a commit.
#   4. Seed a known_hosts file for GitHub's SSH host key -- required
#      because the HA Core container's default known_hosts is ephemeral
#      (wiped on every Core update, i.e. exactly when this script most
#      needs to work) so it has to live under /config instead:
#        ssh-keyscan -t ed25519,rsa github.com >> /config/.ssh/known_hosts
#      Verify the fingerprints this prints match GitHub's published
#      values before trusting them:
#      https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

DEPLOY_KEY="$REPO_DIR/.ssh/ha_version_bump_deploy_key"
KNOWN_HOSTS="$REPO_DIR/.ssh/known_hosts"

if [ ! -f .HA_VERSION ]; then
  echo ".HA_VERSION does not exist -- nothing to commit." >&2
  exit 0
fi

if [ ! -f "$DEPLOY_KEY" ]; then
  echo "Deploy key not found at $DEPLOY_KEY -- see the setup steps in this script's header comment." >&2
  exit 1
fi

if [ ! -f "$KNOWN_HOSTS" ]; then
  echo "known_hosts not found at $KNOWN_HOSTS -- see setup step 4 in this script's header comment." >&2
  exit 1
fi

# Scoped to *only* this path: even if other files are already staged from
# in-progress work on this host, this can never sweep them in.
git add .HA_VERSION

if git diff --cached --quiet -- .HA_VERSION; then
  # No actual change (e.g. a restart on the same version) -- nothing to do.
  exit 0
fi

OLD_VERSION="$(git show HEAD:.HA_VERSION 2>/dev/null || echo unknown)"
NEW_VERSION="$(cat .HA_VERSION)"

if ! git commit -m "Bump .HA_VERSION: ${OLD_VERSION} -> ${NEW_VERSION}" -- .HA_VERSION; then
  echo "git commit failed." >&2
  exit 1
fi

export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=yes"

PUSH_OUTPUT="$(git push 2>&1)"
PUSH_STATUS=$?

if [ "$PUSH_STATUS" -ne 0 ]; then
  echo "$PUSH_OUTPUT" >&2
  if echo "$PUSH_OUTPUT" | grep -qi "host key verification failed"; then
    echo "known_hosts at $KNOWN_HOSTS doesn't have a trusted entry for this host -- see setup step 4 in this script's header comment." >&2
  fi
  echo ".HA_VERSION committed locally (${OLD_VERSION} -> ${NEW_VERSION}) but push failed -- reconcile manually next time you're on the host (git pull, then git push)." >&2
  exit 1
fi

echo ".HA_VERSION bumped and pushed: ${OLD_VERSION} -> ${NEW_VERSION}"
