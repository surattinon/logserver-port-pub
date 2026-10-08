#!/bin/bash
# Updates the SM policy to snapshot only the 7 most recently created indices.
# pan_os_logs_* and watchguard_logs_* indices.
# Run daily at 01:30 (before the 02:00 snapshot and before Commvault at 04:00)
#
# Run as: member of logserver-dev group

set -euo pipefail

OPENSEARCH_URL="http://localhost:9200"
POLICY_NAME="hourly-snapshot"
LOG="/var/log/tasco-logserver/update-snapshot-scope.log"
DAYS_TO_KEEP=7

echo "$(date '+%Y-%m-%d %T') Starting snapshot scope update" | tee -a "${LOG}"

# Get the N most recent indices per source
get_recent_indices() {
  local pattern=$1
  curl -s "${OPENSEARCH_URL}/_cat/indices/${pattern}?h=index,creation.date" \
    | sort -k2 -rn \
    | head -n "${DAYS_TO_KEEP}" \
    | awk '{print $1}' \
    | tr '\n' ',' \
    | sed 's/,$//'
}

PAN_INDICES=$(get_recent_indices "pan_os_logs_*")
WG_INDICES=$(get_recent_indices "watchguard_logs_*")

if [ -z "${PAN_INDICES}" ] && [ -z "${WG_INDICES}" ]; then
  echo "$(date '+%Y-%m-%d %T') ERROR: no indices found - aborting" | tee -a "${LOG}"
  exit 1
fi

# Combine - filter empty
if [ -z "${PAN_INDICES}" ]; then
  COMBINED="${WG_INDICES}"
elif [ -z "${WG_INDICES}" ]; then
  COMBINED="${PAN_INDICES}"
else
  COMBINED="${PAN_INDICES},${WG_INDICES}"
fi

echo "$(date '+%Y-%m-%d %T') Targeting indices: ${COMBINED}" | tee -a "${LOG}"

# ── Get current SM policy seq_no and primary_term (required for update) ───────
META=$(curl -s "${OPENSEARCH_URL}/_plugins/_sm/policies/${POLICY_NAME}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('_seq_no', ''), data.get('_primary_term', ''))
")

SEQ_NO=$(echo "${META}" | awk '{print $1}')
PRIMARY_TERM=$(echo "${META}" | awk '{print $2}')

if [ -z "${SEQ_NO}" ] || [ -z "${PRIMARY_TERM}" ]; then
  echo "$(date '+%Y-%m-%d %T') ERROR: could not read SM policy metadata" | tee -a "${LOG}"
  exit 1
fi

# ── Update SM policy with retry on 409 conflict ───────────────────────────────
MAX_RETRIES=5
ATTEMPT=0
HTTP_CODE="409"

while [ "${HTTP_CODE}" = "409" ] && [ "${ATTEMPT}" -lt "${MAX_RETRIES}" ]; do
  ATTEMPT=$((ATTEMPT + 1))

  # Re-read seq_no and primary_term fresh on every attempt
  META=$(curl -s "${OPENSEARCH_URL}/_plugins/_sm/policies/${POLICY_NAME}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('_seq_no', ''), data.get('_primary_term', ''))
")

  SEQ_NO=$(echo "${META}" | awk '{print $1}')
  PRIMARY_TERM=$(echo "${META}" | awk '{print $2}')

  if [ -z "${SEQ_NO}" ] || [ -z "${PRIMARY_TERM}" ]; then
    echo "$(date '+%Y-%m-%d %T') ERROR: could not read SM policy metadata on attempt ${ATTEMPT}" | tee -a "${LOG}"
    exit 1
  fi

  echo "$(date '+%Y-%m-%d %T') Attempt ${ATTEMPT}: seq_no=${SEQ_NO} primary_term=${PRIMARY_TERM}" | tee -a "${LOG}"

  HTTP_CODE=$(curl -s \
    -o /tmp/sm-update-response.json \
    -w "%{http_code}" \
    -X PUT "${OPENSEARCH_URL}/_plugins/_sm/policies/${POLICY_NAME}?if_seq_no=${SEQ_NO}&if_primary_term=${PRIMARY_TERM}" \
    -H 'Content-Type: application/json' -d"{
    \"description\": \"Hourly automated snapshot — last ${DAYS_TO_KEEP} days of indices\",
    \"creation\": {
      \"schedule\": {
        \"cron\": { \"expression\": \"0 * * * *\", \"timezone\": \"Asia/Bangkok\" }
      },
      \"time_limit\": \"45m\"
    },
    \"deletion\": {
      \"condition\": {
        \"max_age\": \"7d\",
        \"max_count\": 168,
        \"min_count\": 24
      }
    },
    \"snapshot_config\": {
      \"repository\": \"local-snapshots\",
      \"indices\": \"${COMBINED}\",
      \"ignore_unavailable\": \"true\",
      \"include_global_state\": \"false\"
    }
  }")

  if [ "${HTTP_CODE}" = "409" ]; then
    echo "$(date '+%Y-%m-%d %T') 409 conflict on attempt ${ATTEMPT} — SM engine updated doc, retrying in 2s" | tee -a "${LOG}"
    sleep 2
  fi
done

if [ "${HTTP_CODE}" != "200" ]; then
  echo "$(date '+%Y-%m-%d %T') ERROR: SM policy update failed after ${ATTEMPT} attempts, HTTP ${HTTP_CODE}" | tee -a "${LOG}"
  cat /tmp/sm-update-response.json | tee -a "${LOG}"
  exit 1
fi

echo "$(date '+%Y-%m-%d %T') SM policy updated successfully on attempt ${ATTEMPT}" | tee -a "${LOG}"

# ── Trigger manual snapshot repo cleanup ─────────────────────────────────────
# Force OpenSearch to prune segments no longer referenced by any retained snapshot
curl -s -X POST \
  "${OPENSEARCH_URL}/_snapshot/local-snapshots/_cleanup" \
  | python3 -m json.tool >> "${LOG}" 2>&1

echo "$(date '+%Y-%m-%d %T') Repo cleanup triggered" | tee -a "${LOG}"
echo "$(date '+%Y-%m-%d %T') Done" | tee -a "${LOG}"
