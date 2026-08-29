import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = (path) => readFile(new URL(path, import.meta.url), "utf8");

test("shadow settings keep a local pending mirror and do not serve rejected revisions", async () => {
  const [app, bridge] = await Promise.all([
    source("../src/app.js"),
    source("../src/firestore-bridge.js"),
  ]);
  assert.match(app, /saveFirestoreSettings\(uid, settings\)/);
  assert.match(app, /status:\s*"PENDING",\s*transport:\s*"firestore"/);
  assert.match(app, /status IN \('PENDING','APPLIED'\)/);
  assert.match(bridge, /INSERT INTO settings_revisions[\s\S]*'PENDING'/);
  assert.match(bridge, /settings_effective_revision/);
  assert.match(bridge, /desiredStatus = pending \? "PENDING" : importedSettings\.ackApplied \? "APPLIED" : "REJECTED"/);
});

test("cutover freezes writers, reconciles without republishing, and uses strict discovery", async () => {
  const [bridge, company] = await Promise.all([
    source("../src/firestore-bridge.js"),
    source("../../remote-control-web/app.js"),
  ]);
  assert.match(bridge, /mode:\s*"cutover"[\s\S]*writesFrozen:\s*true/);
  assert.match(bridge, /importFirestoreDevices\(\{ publish: false \}\)/);
  assert.match(bridge, /publishDiscovery\(\{[\s\S]*strict:\s*true[\s\S]*mode:\s*"primary"/);
  assert.match(bridge, /await publishPrimary\(\);[\s\S]*await commitPrimary\(\)/);
  assert.match(bridge, /SELECT value FROM system_settings WHERE key='migration' FOR UPDATE/);
  assert.match(bridge, /commitFrozenPrimaryValue\(primaryValue, epoch\)/);
  assert.match(company, /function assertFirestoreControlWritable/);
  assert.match(company, /selfHostedWritesFrozen/);
  assert.match(company, /desiredRevision > ackRevision/);
  assert.match(company, /assertFirestoreControlWritable\(current\)/);
  assert.match(company, /assertFirestoreControlWritable\(data\)/);
});

test("fallback and non-primary transitions reject pending settings", async () => {
  const bridge = await source("../src/firestore-bridge.js");
  assert.match(bridge, /syncFallbackCommandBaselines[\s\S]*settings_revisions WHERE status='PENDING'/);
  assert.match(bridge, /PENDING_SELFHOST_SETTINGS/);
  assert.match(bridge, /mode !== "primary"[\s\S]*PENDING_SELFHOST_SETTINGS/);
});

test("effective settings migration is present and backfills only acknowledged applied revisions", async () => {
  const migration = await source("../migrations/007_effective_settings_revision.sql");
  assert.match(migration, /ADD COLUMN IF NOT EXISTS settings_effective_revision bigint NOT NULL DEFAULT 0/);
  assert.match(migration, /settings_ack->>'applied'/);
  assert.match(migration, /settings_ack->>'revision'/);
});
