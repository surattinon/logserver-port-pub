#!/bin/bash
set -euo pipefail
BACKUP_DIR="/opt/tasco-logserver/backups/mongodb"
DATE=$(date +%Y%m%d_%H%M%S)
DUMP_NAME="dump_${DATE}"
ENV="${1:-dev}"

# Run mongodump inside the container, writing to the bind-mounted /backup path
docker exec "gl-mongodb-${ENV}" mongodump \
  --db graylog \
  --out "/backups/${DUMP_NAME}"

# Confirm the dump landed on the host side
if [ ! -d "${BACKUP_DIR}/${DUMP_NAME}" ]; then
  echo "ERROR: dump not found at ${BACKUP_DIR}/${DUMP_NAME}" >&2
  exit 1
fi

# Rotate — keep last 30 dumps
ls -dt "${BACKUP_DIR}"/dump_* | tail -n +31 | xargs -r rm -rf

echo "mongodump completed: ${BACKUP_DIR}/${DUMP_NAME}"
