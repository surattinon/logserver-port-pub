#!/usr/bin/env bash
# =============================================================================
# deploy.sh — pull-based GitOps deploy for tasco-logserver.
#
# Runs AS svc-logserver (or a logserver-dev member) — NEVER root (git ownership rule).
# Trigger: `make deploy` (recommended, in a maintenance window), or a systemd timer
#          for unattended pull-deploy (set AUTO_APPLY_DISRUPTIVE=0).
#
# Model: origin/main is desired state. This forces prod to exactly match it, AFTER
# capturing any local drift to an immutable, timestamped backup tag (forensic —
# never lost, never non-ff). It then detects which paths changed and runs the
# MINIMAL apply action for each.
#
# ONE-TIME SETUP for logserver-dev humans (git dubious-ownership; UID != repo owner):
#   git config --global --add safe.directory /opt/tasco-logserver
#
# OPTIONAL failure alerting: export TEAMS_WEBHOOK_URL (e.g. sourced from .env.prod,
# which is NOT in git) and the ERR trap posts to the logserver-warning channel.
# If unset, the trap is inert.
# =============================================================================
set -euo pipefail

REPO_DIR="/opt/tasco-logserver"
REMOTE="origin"
BRANCH="main"
ENV="${ENV:-prod}"
LOCK_FILE="/tmp/tasco-logserver-deploy.lock"
# 1 = interactive `make deploy` (apply disruptive actions);
# 0 = unattended timer (defer disruptive actions, notify instead).
AUTO_APPLY_DISRUPTIVE="${AUTO_APPLY_DISRUPTIVE:-1}"

# ── Logging (Fix 9: timestamp evaluated per-line, not frozen at start) ────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; }
die()  { log "ERROR: $*"; exit 1; }
note() { log "ACTION REQUIRED: $*"; }

# ── Optional Teams failure notification (Fix 11) ──────────────────────────────
# Inert unless TEAMS_WEBHOOK_URL is present in the environment. Never hardcode it.
notify_failure() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ -n "${TEAMS_WEBHOOK_URL:-}" ]; then
    curl -s -m 10 -H 'Content-Type: application/json' \
      -d "{\"text\":\"tasco-logserver deploy FAILED (exit ${rc}) on $(hostname) at $(date '+%F %T %z')\"}" \
      "$TEAMS_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}
trap notify_failure ERR

# ── Concurrency lock (Fix 8): timer + manual run cannot both reset --hard ──────
exec 9>"$LOCK_FILE"
flock -n 9 || die "another deploy is already running (lock: $LOCK_FILE)"

# ── Guards ────────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] && die "do not run as root — run as svc-logserver / logserver-dev."
cd "$REPO_DIR" || die "cannot cd to $REPO_DIR"
CUR="$(git rev-parse --abbrev-ref HEAD)"
[ "$CUR" = "$BRANCH" ] || die "prod checkout on '$CUR', expected '$BRANCH' — refusing."

# ── Capture the TRUE pre-deploy HEAD before any drift commit (Fix 7) ──────────
ORIG_HEAD="$(git rev-parse HEAD)"

# ── OpenSearch readiness gate (Fix 4) ─────────────────────────────────────────
# Fast when already healthy; blocks after a restart until the cluster is usable.
wait_os_ready() {
  local timeout="${1:-120}" waited=0 status
  log "waiting for OpenSearch to be ready (timeout ${timeout}s)..."
  while [ "$waited" -lt "$timeout" ]; do
    status="$(curl -s -m 5 "http://127.0.0.1:9200/_cluster/health" 2>/dev/null \
              | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)"
    case "$status" in
      green|yellow) log "OpenSearch ready (status=${status})"; return 0 ;;
      red)          log "OpenSearch up but status=RED — continuing, validation will flag it"; return 0 ;;
    esac
    sleep 3; waited=$((waited + 3))
  done
  die "OpenSearch not ready after ${timeout}s — aborting before bootstrap/validate."
}

# ── 1. Capture local drift to an immutable timestamped tag (Fix 1) ────────────
# Tags never non-ff, so every capture is independent and greppable by date.
# Backup push HARD-ABORTS before any destructive step if it fails.
if [ -n "$(git status --porcelain)" ]; then
  TS="$(date '+%Y%m%d-%H%M%S')"
  BK_TAG="autobackup/${TS}"
  log "local drift detected — capturing to tag ${BK_TAG} before deploy"
  git add -A
  git commit -q -m "auto: pre-deploy drift capture ${TS}" || true
  git tag -f "$BK_TAG" HEAD
  git push -q "$REMOTE" "refs/tags/${BK_TAG}" \
    || die "could not push drift backup tag ${BK_TAG} — ABORTING before reset (drift preserved locally at tag ${BK_TAG})."
  log "drift safely captured and pushed as ${BK_TAG}"
fi

# ── 2. Fetch desired state ─────────────────────────────────────────────────────
git fetch -q "$REMOTE" "$BRANCH"
TARGET="$(git rev-parse "${REMOTE}/${BRANCH}")"

if [ "$ORIG_HEAD" = "$TARGET" ]; then
  log "already at ${REMOTE}/${BRANCH} ($(git rev-parse --short "$TARGET")) — nothing to deploy"
  exit 0
fi

# ── 3. Determine what changed between the TRUE prior HEAD and target (Fix 7) ───
CHANGED="$(git diff --name-only "$ORIG_HEAD" "$TARGET")"
log "incoming changes ${ORIG_HEAD:0:7} -> ${TARGET:0:7}:"
echo "$CHANGED" | sed 's/^/    /'

# ── 4. Force prod to desired state (drift already safe on backup tag) ─────────
git reset --hard "$TARGET"
log "prod now at $(git rev-parse --short HEAD)"

# ── 5. Map changed paths → minimal apply action ───────────────────────────────
# Fix 2: grafana restart is INDEPENDENT of compose (bind-mounted provisioning is
#        not reloaded by `compose up`; it needs an explicit restart).
# Fix 3: opensearch.yml (node/cluster config, read only at boot) → RESTART;
#        configs/opensearch/*.json (repo/templates/SM, API-applied) → BOOTSTRAP.
need_compose=0; need_grafana_restart=0; need_cron=0
need_os_restart=0; need_os_bootstrap=0; env_example_changed=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    docker-compose.yml|services/*.yml)                    need_compose=1 ;;
    .env.example)                                         env_example_changed=1 ;;
    configs/grafana/provisioning/datasources/*|configs/grafana/provisioning/alerting/*)
                                                          need_grafana_restart=1 ;;
    configs/cron/*)                                       need_cron=1 ;;
    configs/opensearch/opensearch.yml)                    need_os_restart=1 ;;
    configs/opensearch/*)                                 need_os_bootstrap=1 ;;
    # dashboards → Git Sync self-pulls; scripts/docs/.github → no runtime action
  esac
done <<< "$CHANGED"

# ── 6. Pre-apply env sanity check (Fix 13: BEFORE any container restart) ──────
if [ "$env_example_changed" -eq 1 ]; then
  ENV_FILE=".env.${ENV}"
  if [ -f "$ENV_FILE" ]; then
    MISSING=""
    while IFS= read -r key; do
      grep -q "^${key}=" "$ENV_FILE" || MISSING="${MISSING} ${key}"
    done < <(grep -oE '^[A-Z_][A-Z0-9_]*=' .env.example | sed 's/=$//')
    if [ -n "$MISSING" ]; then
      note ".env.example added keys missing from ${ENV_FILE}:${MISSING} — add them (secret, not in git) BEFORE containers restart."
    else
      log ".env.example keys all present in ${ENV_FILE}"
    fi
  else
    note "${ENV_FILE} not found — cannot verify new .env.example keys."
  fi
fi

# ── 7. Apply — disruptive actions respect AUTO_APPLY_DISRUPTIVE (Fix 10) ──────
os_touched=0

if [ "$need_compose" -eq 1 ]; then
  if [ "$AUTO_APPLY_DISRUPTIVE" -eq 1 ]; then
    log "compose/services changed → ENV=${ENV} make up (recreates changed containers)"
    ENV="$ENV" make up
    os_touched=1   # compose may have recreated opensearch; gate readiness wait below
  else
    note "compose/services changed — container recreate DEFERRED (unattended). Run 'ENV=${ENV} make up' in a maintenance window."
  fi
fi

if [ "$need_os_restart" -eq 1 ]; then
  if [ "$AUTO_APPLY_DISRUPTIVE" -eq 1 ]; then
    log "opensearch.yml changed → force-recreating opensearch (node config reloads only on restart)"
    ENV="$ENV" docker compose up -d --force-recreate opensearch
    os_touched=1
  else
    note "opensearch.yml changed — OpenSearch restart DEFERRED (unattended). Node config will NOT take effect until 'docker compose up -d --force-recreate opensearch' in a maintenance window."
  fi
fi

if [ "$need_grafana_restart" -eq 1 ]; then
  # Independent of compose. If compose already recreated grafana, this is a
  # harmless redundant restart; provisioning-only changes never trigger compose.
  if [ "$AUTO_APPLY_DISRUPTIVE" -eq 1 ]; then
    log "grafana datasource/alerting provisioning changed → restarting grafana to reload provisioning"
    ENV="$ENV" make restart-grafana
  else
    note "grafana provisioning changed — grafana restart DEFERRED (unattended). Run 'ENV=${ENV} make restart-grafana' to load it."
  fi
fi

# OpenSearch bootstrap (API, idempotent) — safe to run even unattended, but only
# once the cluster is reachable. wait_os_ready is cheap when already healthy.
if [ "$need_os_bootstrap" -eq 1 ]; then
  # bootstrap owns its own readiness wait (up to ~300s) — do NOT pre-gate here,
  # or a slow OS restart aborts the deploy before bootstrap can wait it out.
  log "opensearch cluster-state config changed → running idempotent bootstrap"
  ./scripts/opensearch-bootstrap.sh
elif [ "$os_touched" -eq 1 ]; then
  # No bootstrap, but we restarted OS — confirm it came back before validating.
  wait_os_ready 300
fi

if [ "$need_cron" -eq 1 ]; then
  # /etc/cron.d needs root; svc-logserver cannot write it. Notify, never auto-apply.
  note "cron changed — run: sudo make install-cron"
fi

# ── 8. Validate (Fix 5: real health, not just container 'Up') ─────────────────
log "post-deploy container status:"
ENV="$ENV" make ps || true

VALIDATION_FAILED=0

# OpenSearch cluster health must not be RED.
OS_STATUS="$(curl -s -m 5 'http://127.0.0.1:9200/_cluster/health' 2>/dev/null \
             | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)"
case "$OS_STATUS" in
  green|yellow) log "validation: OpenSearch health=${OS_STATUS} OK" ;;
  red)          log "validation: OpenSearch health=RED"; VALIDATION_FAILED=1 ;;
  *)            log "validation: OpenSearch health UNREACHABLE"; VALIDATION_FAILED=1 ;;
esac

# Graylog liveness (unauthenticated lbstatus endpoint — no token needed here).
GL_CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' 'http://127.0.0.1:9000/api/system/lbstatus' 2>/dev/null || echo 000)"
if [ "$GL_CODE" = "200" ]; then
  log "validation: Graylog lbstatus 200 ALIVE OK"
else
  log "validation: Graylog lbstatus HTTP ${GL_CODE} (not ALIVE)"; VALIDATION_FAILED=1
fi

if [ "$VALIDATION_FAILED" -ne 0 ]; then
  die "post-deploy validation FAILED — code is at $(git rev-parse --short HEAD); investigate. Rollback: git reset --hard ${ORIG_HEAD:0:7} && ENV=${ENV} make up"
fi

log "deploy complete: ${ORIG_HEAD:0:7} -> $(git rev-parse --short HEAD)"
