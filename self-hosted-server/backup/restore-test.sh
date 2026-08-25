#!/bin/sh
set -eu

archive="${1:-}"
if [ -z "$archive" ]; then
  archive="$(find /backups/preupdate /backups/daily /backups/weekly -maxdepth 1 -type f -name '*.dump' -print 2>/dev/null | sort -r | head -n 1)"
fi
if [ -z "$archive" ] || [ ! -f "$archive" ]; then
  echo "no backup archive available for restore test" >&2
  exit 2
fi

restore_db="wuthering_restore_test_$(date +%Y%m%d%H%M%S)_$$"
cleanup() {
  dropdb --if-exists "$restore_db" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

createdb "$restore_db"
pg_restore --exit-on-error --no-owner --no-privileges --dbname="$restore_db" "$archive"
table_count="$(psql --dbname="$restore_db" --tuples-only --no-align --command="SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
if [ "${table_count:-0}" -lt 10 ]; then
  echo "restore test produced too few tables: $table_count" >&2
  exit 3
fi
psql --dbname="$restore_db" --tuples-only --no-align --command="SELECT count(*) FROM schema_migrations" >/dev/null
echo "restore test complete: $archive ($table_count public tables)"
