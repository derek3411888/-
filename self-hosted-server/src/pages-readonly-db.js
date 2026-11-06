import pg from 'pg';

// Isolate pilot traffic from the heartbeat/control pool. Server-side timeout
// cancels running SQL; client-side timeout also bounds network interruption.
export function createPagesDeviceReader(connectionString, Pool = pg.Pool) {
  const pool = new Pool({ connectionString, max: 1, idleTimeoutMillis: 10000,
    connectionTimeoutMillis: 2000, statement_timeout: 3000, query_timeout: 4000,
    application_name: 'wuthering-pages-readonly' });
  pool.on('error', () => {}); // No credentials or raw database errors in public output.
  return {
    async read(uids) {
      return (await pool.query(`SELECT d.uid,d.display_name,d.state,d.last_seen,d.status,
        (d.state NOT IN ('STOP','OFFLINE') AND d.last_seen > now()-interval '5 minutes'
          AND NOT EXISTS (SELECT 1 FROM commands s WHERE s.uid=d.uid AND s.command='STOP'
            AND s.status='ACKED' AND s.acked_at>=d.last_seen)) AS online
        FROM devices d WHERE d.uid=ANY($1::text[]) ORDER BY d.uid`, [uids])).rows;
    },
    close: () => pool.end(),
  };
}
