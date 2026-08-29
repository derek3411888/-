ALTER TABLE devices
  ADD COLUMN IF NOT EXISTS settings_effective_revision bigint NOT NULL DEFAULT 0;

UPDATE devices
SET settings_effective_revision = GREATEST(
  settings_effective_revision,
  CASE
    WHEN COALESCE((settings_ack->>'applied')::boolean, false)
      THEN COALESCE((settings_ack->>'revision')::bigint, 0)
    ELSE 0
  END
);
