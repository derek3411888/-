ALTER TABLE recording_sessions
  ADD COLUMN IF NOT EXISTS expected_bytes bigint,
  ADD COLUMN IF NOT EXISTS progress_stage text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS progress_percent integer,
  ADD COLUMN IF NOT EXISTS progress_current bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS progress_total bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS progress_updated_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'recording_sessions_progress_percent_check'
  ) THEN
    ALTER TABLE recording_sessions
      ADD CONSTRAINT recording_sessions_progress_percent_check
      CHECK (progress_percent IS NULL OR progress_percent BETWEEN 0 AND 100);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'recording_sessions_expected_bytes_check'
  ) THEN
    ALTER TABLE recording_sessions
      ADD CONSTRAINT recording_sessions_expected_bytes_check
      CHECK (expected_bytes IS NULL OR expected_bytes > 0);
  END IF;
END $$;
