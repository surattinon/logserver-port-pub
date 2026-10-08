#!/usr/bin/env bash
set -uo pipefail
DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
ENV="${ENV:-prod}"
OUT="${DIR}/docker_status.prom"
TMP="$(mktemp "${DIR}/.docker_status.XXXXXX")"
health_num() { case "$1" in healthy) echo 1;; unhealthy) echo 0;; starting) echo 2;; *) echo 3;; esac; }

records=()
for cid in $(docker ps -aq --filter "name=-${ENV}"); do
  records+=("$(docker inspect -f '{{.Name}}|{{if .State.Running}}1{{else}}0{{end}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}' "$cid")")
done

{
  echo "# TYPE tasco_container_up gauge"
  for r in "${records[@]}"; do IFS='|' read -r n up hs rc st <<<"$r"; printf 'tasco_container_up{name="%s"} %s\n' "${n#/}" "$up"; done
  echo "# TYPE tasco_container_health gauge"
  for r in "${records[@]}"; do IFS='|' read -r n up hs rc st <<<"$r"; printf 'tasco_container_health{name="%s"} %s\n' "${n#/}" "$(health_num "$hs")"; done
  echo "# TYPE tasco_container_restarts gauge"
  for r in "${records[@]}"; do IFS='|' read -r n up hs rc st <<<"$r"; printf 'tasco_container_restarts{name="%s"} %s\n' "${n#/}" "$rc"; done
  echo "# TYPE tasco_container_start_time_seconds gauge"
  for r in "${records[@]}"; do IFS='|' read -r n up hs rc st <<<"$r"; e=$(date -d "$st" +%s 2>/dev/null || echo 0); printf 'tasco_container_start_time_seconds{name="%s"} %s\n' "${n#/}" "$e"; done
} > "$TMP"
chmod 0644 "$TMP"
mv "$TMP" "$OUT"
