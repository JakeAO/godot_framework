#!/usr/bin/env bash
# Nightly Postgres backup (BACKEND.md §5). Run from /opt/backend via cron, e.g.:
#   15 3 * * * cd /opt/backend && ./backup.sh >> /var/log/nakama-backup.log 2>&1
# Prototype-grade: local archive + optional offsite copy when rclone is configured.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] || { echo "no .env in $(pwd)"; exit 1; }
set -a; . ./.env; set +a

STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_DIR="${BACKUP_DIR:-./backups}"
mkdir -p "$ARCHIVE_DIR"
FILE="${ARCHIVE_DIR}/nakama-${STAMP}.sql.gz"

docker compose -f docker-compose.prod.yml exec -T postgres \
	pg_dump -U postgres -d nakama | gzip > "$FILE"
echo "[backup] wrote ${FILE} ($(du -h "$FILE" | cut -f1))"

# Keep the 7 most recent local archives.
ls -1t "${ARCHIVE_DIR}"/nakama-*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm --

# Offsite copy (optional): set BACKUP_RCLONE_DEST, e.g. "remote:nakama-backups".
if [ -n "${BACKUP_RCLONE_DEST:-}" ]; then
	rclone copyto "$FILE" "${BACKUP_RCLONE_DEST%/}/$(basename "$FILE")" \
		&& echo "[backup] offsite copy done -> ${BACKUP_RCLONE_DEST}" \
		|| echo "[backup] WARN: offsite copy failed (local archive kept)"
fi

# Restore (manual): gunzip the archive, then
#   docker compose -f docker-compose.prod.yml exec -T postgres psql -U postgres -d nakama < dump.sql
# (drop/recreate schema first if the server version changed).
