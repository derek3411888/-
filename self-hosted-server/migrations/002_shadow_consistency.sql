ALTER TABLE devices
  ADD COLUMN IF NOT EXISTS firestore_observed_nonce bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS firestore_observed_ack_nonce bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS firestore_observed_settings_revision bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS firestore_observed_settings_ack_revision bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS firestore_observed_at timestamptz;
