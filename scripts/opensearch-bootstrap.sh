#!/usr/bin/env bash
# =============================================================================
# Applies all OpenSearch config-as-code after a fresh container start or rebuild.
# Idempotent — safe to run multiple times.
#
# Run as:  svc-logserver (or any logserver-dev member) — NOT root
# Usage:   /opt/tasco-logserver/scripts/opensearch-bootstrap.sh
# Log:     /var/log/tasco-logserver/opensearch-bootstrap.log
#
# Applies, in order:
#   1. Snapshot repository       (local-snapshots -> path.repo)   [verify = HARD FAIL]
#   2. Legacy zstd templates     (settings-only, merge with Graylog mappings)
#   3. SM policy                 (hourly-snapshot; create if absent, else skip)
#
# NOTE: opensearch.yml (node/cluster settings + watermarks) is applied by the
#       container mount, NOT by this script. This script only applies the
#       cluster-state objects that live in the OpenSearch API, not on disk.
# NOTE: index.codec/zstd is index-level and applied via the legacy templates
#       below — never as composable _index_template (that breaks Graylog mappings).
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
OS_URL="${OPENSEARCH_URL:-http://localhost:9200}"
CONFIGS_DIR="${CONFIGS_DIR:-/opt/tasco-logserver/configs/opensearch}"
LOG="${LOG:-/var/log/tasco-logserver/opensearch-bootstrap.log}"
REPO_NAME="local-snapshots"
SM_POLICY_NAME="hourly-snapshot"
READY_RETRIES=30
READY_WAIT=10

# ── Per-run temp file for API responses (Issue 4: no shared /tmp collision) ──
RESP="$(mktemp)"
trap 'rm -f "${RESP}"' EXIT

# ── Guard: do not run as root ────────────────────────────────────────────────
if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: do not run this script as root. Run as svc-logserver or a logserver-dev member." >&2
  exit 1
fi

# ── Logging must never abort the run (Issue 2) ───────────────────────────────
# If the log dir isn't writable and can't be created (non-root can't fix a
# root-owned parent), degrade to stdout-only instead of dying on the first log line.
LOG_DIR="$(dirname "${LOG}")"
if [ -d "${LOG_DIR}" ] && [ -w "${LOG_DIR}" ]; then
  :
elif mkdir -p "${LOG_DIR}" 2>/dev/null; then
  :
else
  echo "WARN: ${LOG_DIR} not writable — logging to stdout only" >&2
  LOG=/dev/null
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "$(date '+%Y-%m-%d %T') $*" | tee -a "${LOG}"; }
die() { log "ERROR: $*"; exit 1; }

require_file() {
  [ -f "$1" ] || die "required config file not found: $1"
}

# ── Wait for OpenSearch to be ready ──────────────────────────────────────────
log "Waiting for OpenSearch at ${OS_URL}..."
for i in $(seq 1 "${READY_RETRIES}"); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "${OS_URL}/_cluster/health" || echo "000")
  if [ "${code}" = "200" ]; then
    log "OpenSearch is ready (attempt ${i})"
    break
  fi
  if [ "${i}" -eq "${READY_RETRIES}" ]; then
    die "OpenSearch did not become ready after ${READY_RETRIES} attempts"
  fi
  log "Not ready (HTTP ${code}) — attempt ${i}/${READY_RETRIES}, waiting ${READY_WAIT}s"
  sleep "${READY_WAIT}"
done

# ── PUT helper: apply a JSON file to an endpoint, fail on non-2xx ─────────────
apply_json() {
  local method=$1 endpoint=$2 file=$3 name=$4
  require_file "${file}"
  local code
  code=$(curl -s -o "${RESP}" -w "%{http_code}" \
    -X "${method}" "${OS_URL}/${endpoint}" \
    -H 'Content-Type: application/json' \
    --data-binary @"${file}")
  if [ "${code}" = "200" ] || [ "${code}" = "201" ]; then
    log "OK   ${name} (HTTP ${code})"
  else
    log "FAIL ${name} (HTTP ${code})"
    cat "${RESP}" | tee -a "${LOG}"
    die "failed applying ${name}"
  fi
}

# ── 1. Snapshot repository ───────────────────────────────────────────────────
# Registers the fs repository pointing at path.repo. Idempotent — PUT is upsert.
log "Applying snapshot repository '${REPO_NAME}'..."
apply_json PUT "_snapshot/${REPO_NAME}" \
  "${CONFIGS_DIR}/snapshot-repository.json" \
  "snapshot repository (${REPO_NAME})"

# Verify the repo is reachable and writable — HARD FAIL (Issue 3).
# A broken/mis-spelled path.repo location must NOT let the deploy report success:
# this is the compliance-relevant backup path.
verify_code=$(curl -s -o "${RESP}" -w "%{http_code}" \
  -X POST "${OS_URL}/_snapshot/${REPO_NAME}/_verify" || echo "000")
if [ "${verify_code}" = "200" ]; then
  log "OK   snapshot repository verified"
else
  log "FAIL snapshot repository verify returned HTTP ${verify_code}"
  cat "${RESP}" | tee -a "${LOG}"
  die "snapshot repo '${REPO_NAME}' not verified — check path.repo mount and the 'location' in snapshot-repository.json against the /data/opensearch-snapshot(s) spelling"
fi

# ── 2. Legacy zstd templates (settings-only, merge with Graylog mappings) ────
log "Applying legacy zstd templates..."
apply_json PUT "_template/pan_os_logs-zstd-codec" \
  "${CONFIGS_DIR}/legacy-template-pan_os_logs-zstd-codec.json" \
  "legacy template pan_os_logs-zstd-codec"

apply_json PUT "_template/watchguard_logs-zstd-codec" \
  "${CONFIGS_DIR}/legacy-template-watchguard_logs-zstd-codec.json" \
  "legacy template watchguard_logs-zstd-codec"

# ── 3. SM policy (create only if absent; do not clobber running policy) ──────
# The SM policy index scope is managed live by update-snapshot-scope.sh, so we
# must NOT overwrite an existing policy here — only create it if missing.
log "Checking SM policy '${SM_POLICY_NAME}'..."
sm_code=$(curl -s -o /dev/null -w "%{http_code}" \
  "${OS_URL}/_plugins/_sm/policies/${SM_POLICY_NAME}" || echo "000")

if [ "${sm_code}" = "200" ]; then
  log "OK   SM policy already exists — leaving intact (scope managed by update-snapshot-scope.sh)"
elif [ "${sm_code}" = "404" ]; then
  log "SM policy absent — creating from seed"
  apply_json POST "_plugins/_sm/policies/${SM_POLICY_NAME}" \
    "${CONFIGS_DIR}/sm-policy-hourly-snapshot.json" \
    "SM policy (${SM_POLICY_NAME})"
  log "NOTE run update-snapshot-scope.sh next to scope the policy to the last 7 days of indices"
else
  die "unexpected HTTP ${sm_code} checking SM policy"
fi

log "Bootstrap complete."
