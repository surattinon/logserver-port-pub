#!/usr/bin/env bash

# =============================================================================
# git-autocommit.sh
# Runs as: svc-logserver (cron @ 02:30)
# Purpose: Stage all changes, commit, push to prod-autobackup branch.
# Log:     /var/log/tasco-logserver/git-autocommit.log
# Crontab: 30 2 * * * /opt/tasco-logserver/scripts/git-autocommit.sh >> /var/log/tasco-logserver/git-autocommit.log 2>&1
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
REPO_DIR="/opt/tasco-logserver"
LOCAL_BRANCH="main"
REMOTE_BACKUP_BRANCH="prod-autobackup"
REMOTE="origin"
LOCK_FILE="/tmp/git-autocommit.lock"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S %z')]"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "${LOG_PREFIX} $*"; }
die()  { log "ERROR: $*"; exit 1; }

# ── Lock: one instance at a time ─────────────────────────────────────────────
exec 9>"${LOCK_FILE}" || die "cannot open lock file"
flock -n 9 || { log "already running — skipping"; exit 0; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
[ -d "${REPO_DIR}/.git" ] || die "${REPO_DIR} is not a git repository"
cd "${REPO_DIR}"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "${CURRENT_BRANCH}" = "${LOCAL_BRANCH}" ] \
  || die "on branch '${CURRENT_BRANCH}', expected '${LOCAL_BRANCH}' — refusing to push"

# ── Stage ─────────────────────────────────────────────────────────────────────
git add -A

# Nothing staged? Done.
if git diff --cached --quiet; then
  log "no changes — nothing to commit"
  exit 0
fi

# ── Commit ────────────────────────────────────────────────────────────────────
CHANGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
git commit -q -m "auto: config snapshot $(date '+%Y-%m-%d') (${CHANGED} file(s))"
log "committed ${CHANGED} file(s) — $(git rev-parse --short HEAD)"

# ── Push ──────────────────────────────────────────────────────────────────────
if git push -q "${REMOTE}" "${LOCAL_BRANCH}:${REMOTE_BACKUP_BRANCH}"; then
  log "pushed to ${REMOTE}/${REMOTE_BACKUP_BRANCH}"
else
  die "push rejected — commit is safe locally, investigate remote divergence"
fi

log "done"
