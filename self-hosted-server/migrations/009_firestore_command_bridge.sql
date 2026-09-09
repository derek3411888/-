ALTER TABLE devices
  ADD COLUMN IF NOT EXISTS firestore_command jsonb NOT NULL DEFAULT '{}'::jsonb;
