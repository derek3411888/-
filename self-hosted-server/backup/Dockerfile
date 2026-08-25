FROM postgres:17-alpine

RUN apk add --no-cache tzdata
COPY backup-now.sh /usr/local/bin/backup-now.sh
COPY restore-test.sh /usr/local/bin/restore-test.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/backup-now.sh /usr/local/bin/restore-test.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
