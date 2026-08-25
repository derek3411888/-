import { createActivationLink } from "./auth.js";
import { closeDatabase, migrate, query } from "./db.js";
import {
  forceMigrationMode,
  importFirestoreDevices,
  migrationReadiness,
  publishDiscovery,
} from "./firestore-bridge.js";

async function main() {
  await migrate();
  const [command = "help", argument = ""] = process.argv.slice(2);
  switch (command) {
    case "activation-link":
      process.stdout.write(`${await createActivationLink(Number(argument) || 24)}\n`);
      break;
    case "status": {
      const [readiness, devices, sessions, alerts] = await Promise.all([
        migrationReadiness(),
        query("SELECT uid,display_name,state,last_seen,credential_issued_at FROM devices ORDER BY uid"),
        query("SELECT count(*)::int AS count FROM recording_sessions WHERE state='COMPLETE'"),
        query("SELECT count(*)::int AS count FROM server_alerts WHERE cleared_at IS NULL"),
      ]);
      process.stdout.write(`${JSON.stringify({ readiness, devices: devices.rows, completedRecordings: sessions.rows[0].count, alerts: alerts.rows[0].count }, null, 2)}\n`);
      break;
    }
    case "import-firestore":
      process.stdout.write(`${JSON.stringify(await importFirestoreDevices(), null, 2)}\n`);
      break;
    case "publish-discovery":
      process.stdout.write(`${JSON.stringify(await publishDiscovery(), null, 2)}\n`);
      break;
    case "force-mode":
      process.stdout.write(`${JSON.stringify(await forceMigrationMode(argument), null, 2)}\n`);
      break;
    case "revoke-browser":
      await query("UPDATE browser_sessions SET revoked_at=now() WHERE id=$1", [argument]);
      process.stdout.write("ok\n");
      break;
    default:
      process.stdout.write("Commands: activation-link [hours], status, import-firestore, publish-discovery, force-mode <shadow|primary|fallback|disabled>, revoke-browser <uuid>\n");
  }
}

main().then(closeDatabase).catch(async (error) => {
  console.error(error);
  try { await closeDatabase(); } catch {}
  process.exit(1);
});
