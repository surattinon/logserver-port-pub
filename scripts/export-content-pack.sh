#!/bin/bash

# Exports the latest Graylog content pack revision via REST API and commits to git.
#
# Run as: svc-logserver
# Usage:  /opt/tasco-logserver/scripts/export-content-pack.sh
#
# Requires: /opt/tasco-logserver/.graylog-api-token (chmod 400, owned by svc-logserver)

set -euo pipefail

# Config
GRAYLOG_URL="http://localhost:9000"
TOKEN_FILE="/opt/tasco-logserver/.graylog-api-token.secret"
CONTENT_PACK_ID="307cb4eb-93f5-4e77-9b2c-4d549052e48d"
PROJECT_DIR="/opt/tasco-logserver"
PACK_DIR="${PROJECT_DIR}/content-packs"
LOG="/var/log/tasco-logserver/content-pack-export.log"

# Read API token
GRAYLOG_TOKEN=$(cat "${TOKEN_FILE}" 2>/dev/null) || {
  echo "$(date '+%Y-%m-%d %T') ERROR: cannot read ${TOKEN_FILE}" | tee -a "${LOG}"
  exit 1
}

# Check token is not close to expiry
EXPIRY_RESPONSE=$(curl -s \
  -u "${GRAYLOG_TOKEN}:token" \
  -H "Accept: application/json" \
  "${GRAYLOG_URL}/api/users/local:admin/tokens" 2>/dev/null)

DAYS_LEFT=$(echo "${EXPIRY_RESPONSE}" | python3 -c "
import sys, json
from datetime import datetime, timezone
data = json.load(sys.stdin)
tokens = data.get('tokens', [])
for t in tokens:
    if t.get('name') == 'svc-logserver-export':
        expires = t.get('expires_at')
        if not expires:
            print('no-expiry')
            sys.exit(0)
        exp_dt = datetime.fromisoformat(expires.replace('Z', '+00:00'))
        now = datetime.now(timezone.utc)
        print((exp_dt - now).days)
        sys.exit(0)
print('not-found')
" 2>/dev/null || echo "unknown")

if [ "${DAYS_LEFT}" = "not-found" ]; then
  echo "$(date '+%Y-%m-%d %T') WARNING: token 'svc-logserver-export' not found in token list" | tee -a "${LOG}"
elif [ "${DAYS_LEFT}" = "no-expiry" ]; then
  echo "$(date '+%Y-%m-%d %T') INFO: token has no expiry set — consider adding a TTL" | tee -a "${LOG}"
elif [ "${DAYS_LEFT}" != "unknown" ] && [ "${DAYS_LEFT}" -lt 30 ]; then
  echo "$(date '+%Y-%m-%d %T') WARNING: API token expires in ${DAYS_LEFT} days — rotate now" | tee -a "${LOG}"
else
  echo "$(date '+%Y-%m-%d %T') INFO: token valid, ${DAYS_LEFT} days remaining" | tee -a "${LOG}"
fi

# Detect latest revision from list endpoint
echo "$(date '+%Y-%m-%d %T') Fetching latest revision..." | tee -a "${LOG}"

REVISION=$(curl -s \
  -u "${GRAYLOG_TOKEN}:token" \
  -H "Accept: application/json" \
  "${GRAYLOG_URL}/api/system/content_packs" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
packs = data.get('content_packs', [])
matches = [p for p in packs if p.get('id') == '${CONTENT_PACK_ID}']
if not matches:
    raise SystemExit('ERROR: content pack ID not found in list')
latest = max(p['rev'] for p in matches)
print(latest)
") || {
  echo "$(date '+%Y-%m-%d %T') ERROR: failed to detect revision" | tee -a "${LOG}"
  exit 1
}

echo "$(date '+%Y-%m-%d %T') Latest revision: ${REVISION}" | tee -a "${LOG}"

# Download
OUTFILE="${PACK_DIR}/content-pack-${CONTENT_PACK_ID}-${REVISION}.json"

HTTP_CODE=$(curl -s \
  -o "${OUTFILE}" \
  -w "%{http_code}" \
  -u "${GRAYLOG_TOKEN}:token" \
  -H "Accept: application/json" \
  -H "X-Requested-By: export-script" \
  "${GRAYLOG_URL}/api/system/content_packs/${CONTENT_PACK_ID}/${REVISION}/download")

if [ "${HTTP_CODE}" != "200" ]; then
  echo "$(date '+%Y-%m-%d %T') ERROR: API returned HTTP ${HTTP_CODE}" | tee -a "${LOG}"
  rm -f "${OUTFILE}"
  exit 1
fi

# Validate response is real JSON
python3 -m json.tool "${OUTFILE}" > /dev/null 2>&1 || {
  echo "$(date '+%Y-%m-%d %T') ERROR: response is not valid JSON" | tee -a "${LOG}"
  rm -f "${OUTFILE}"
  exit 1
}

echo "$(date '+%Y-%m-%d %T') Downloaded to: ${OUTFILE}" | tee -a "${LOG}"

# Git commit
cd "${PROJECT_DIR}"

# Check if file is new or changed vs last commit
if git ls-files --error-unmatch "${OUTFILE}" > /dev/null 2>&1 && \
   git diff --quiet HEAD -- "${OUTFILE}"; then
  echo "$(date '+%Y-%m-%d %T') No changes since last export — skip commit" | tee -a "${LOG}"
  exit 0
fi

git add "${OUTFILE}"
git commit -m "backup: export content pack rev ${REVISION} $(date +%Y-%m-%d)"
echo "$(date '+%Y-%m-%d %T') Committed to git" | tee -a "${LOG}"

# Push if remote configured
REMOTE=$(git remote | head -1)
if [ -n "${REMOTE}" ]; then
  if git push "${REMOTE}" HEAD >> "${LOG}" 2>&1; then
    echo "$(date '+%Y-%m-%d %T') Pushed to ${REMOTE}" | tee -a "${LOG}"
  else
    echo "$(date '+%Y-%m-%d %T') ERROR: git push failed" | tee -a "${LOG}"
    exit 1
  fi
else
  echo "$(date '+%Y-%m-%d %T') WARNING: no git remote - commit is local only" | tee -a "${LOG}"
fi

echo "$(date '+%Y-%m-%d %T') Done." | tee -a "${LOG}"
