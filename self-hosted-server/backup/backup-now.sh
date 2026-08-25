#!/bin/sh
set -eu

kind="${1:-daily}"
case "$kind" in
  daily|weekly|preupdate) ;;
  *) echo "invalid backup kind: $kind" >&2; exit 2 ;;
esac

mkdir -p "/backups/$kind"
stamp="$(date +%Y%m%d_%H%M%S)"
target="/backups/$kind/wuthering_control_${stamp}.dump"
partial="${target}.partial"

rm -f "$partial"
pg_dump --format=custom --compress=6 --file="$partial"
pg_restore --list "$partial" >/dev/null
mv "$partial" "$target"

keep=14
[ "$kind" = "weekly" ] && keep=8
[ "$kind" = "preupdate" ] && keep=5

ls -1t "/backups/$kind"/*.dump 2>/dev/null | awk "NR>$keep" | while IFS= read -r old; do
  rm -f -- "$old"
done

echo "backup complete: $target"
