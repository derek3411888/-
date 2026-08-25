#!/bin/sh
set -eu

mkdir -p /backups/daily /backups/weekly /backups/preupdate /var/log
cat >/etc/crontabs/root <<'EOF'
30 2 * * * /usr/local/bin/backup-now.sh daily >>/proc/1/fd/1 2>>/proc/1/fd/2
45 2 * * 0 /usr/local/bin/backup-now.sh weekly >>/proc/1/fd/1 2>>/proc/1/fd/2
EOF

exec crond -f -l 2
