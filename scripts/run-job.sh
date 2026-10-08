#!/usr/bin/env bash
# run-job.sh <job_name> <command...>
set -uo pipefail
DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
JOB="${1:?job name required}"; shift
OUT="${DIR}/job_${JOB}.prom"
start=$(date +%s)
"$@"; ec=$? # run the real job; capture exit (no set -e here)
end=$(date +%s)
prev=0
[ -f "$OUT" ] && prev=$(awk '/^tasco_job_last_success_timestamp_seconds/{print $2}' "$OUT" 2>/dev/null || echo 0)
if [ "$ec" -eq 0 ]; then succ=$end; else succ=${prev:-0}; fi   # keep last success on failure
TMP="$(mktemp "${DIR}/.job_${JOB}.XXXXXX")"
cat > "$TMP" <<EOF
# TYPE tasco_job_last_run_timestamp_seconds gauge
tasco_job_last_run_timestamp_seconds{job="$JOB"} $end
# TYPE tasco_job_last_success_timestamp_seconds gauge
tasco_job_last_success_timestamp_seconds{job="$JOB"} $succ
# TYPE tasco_job_last_exit_code gauge
tasco_job_last_exit_code{job="$JOB"} $ec
# TYPE tasco_job_last_duration_seconds gauge
tasco_job_last_duration_seconds{job="$JOB"} $((end-start))
EOF
chmod 0644 "$TMP"
mv "$TMP" "$OUT"
exit $ec # preserve the job's real exit code to cron
