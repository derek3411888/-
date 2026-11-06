# Company Pages bridge

Optional `COMPANY_BRIDGE_ENABLED=true` enables the existing Firestore Standard
`ahk_clients` transport for the two explicitly allowlisted devices. Keep
`SELFHOST_ONLY=true` and `FIRESTORE_IMPORT_ENABLED=false`; the old migration,
discovery and device-side Firestore paths remain retired. Codex is not exposed
by this bridge. It does not provide shell, filesystem or host access.

Every 60 seconds the API reads only `companyRequest`, then writes only
`companyBridge`, `companySnapshot` and (if applicable) `companyReceipt`, using
Firestore update-time compare-and-swap. A conflict waits for the next cycle.
Only a new version-1 request with the persisted activation epoch, UUID, server
timestamp within five minutes, and matching central counters can be allocated.
Postgres receipts and allocation commit atomically. Retrying an accepted UUID
returns its old receipt, not a new command. Legacy nonce/desired/settings fields
are neither imported nor overwritten. Existing general-API pending/STOP rules
still apply. Disabled, stale, offline or mismatched requests fail closed.

Company Pages must be refreshed after publishing. Request submission, bridge
acceptance and device ACK are distinct states. The latest device heartbeat,
step, server progress, bounded redacted logs, command history and settings are
mirrored. Old Firestore screenshots are deliberately not displayed as current;
live video/image transport is not part of this bridge. General-site media is
unchanged. The company UI waits if a previous bridge request lacks a receipt.
ACK fields come from one precise command receipt, never from a heartbeat cursor.
An edited settings form refuses a newer baseline instead of overwriting it.
Unknown SMTP capability permits preserving already enabled mail only; enabling
mail anew requires reported capability. Device-side settings validation remains.
Both new command and settings requests are rejected if offline at intake.

This uses the existing Firestore access rules, not a new authentication system.
Anyone allowed by those rules may submit the limited supported operations.
Do not change rules or add credentials automatically if the bridge gets 403.
Disabling the flag stops processing; stale company controls close after 150s.
Receipts/epochs must not be deleted to retry requests. Rollback the API image and
flag if needed; do not roll back central nonce, ACK or settings revisions.

Tests: `npm test` from this directory. The opt-in `test/company-bridge-db.mjs`
requires a separate disposable database named `company_bridge_isolated` and
`COMPANY_ISOLATED_TEST=yes`. Never run it against the service database. Deployment
acceptance can be passive (two mirrored heartbeats plus unchanged counters);
that does not establish real company-browser or device-control E2E acceptance.
