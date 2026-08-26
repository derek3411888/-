ALTER TABLE recording_segments
  ADD COLUMN IF NOT EXISTS auto_retry_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_auto_repair_at timestamptz;

ALTER TABLE recording_sessions
  ADD COLUMN IF NOT EXISTS auto_retry_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_auto_repair_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'recording_segments_auto_retry_count_check'
  ) THEN
    ALTER TABLE recording_segments
      ADD CONSTRAINT recording_segments_auto_retry_count_check
      CHECK (auto_retry_count BETWEEN 0 AND 100);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'recording_sessions_auto_retry_count_check'
  ) THEN
    ALTER TABLE recording_sessions
      ADD CONSTRAINT recording_sessions_auto_retry_count_check
      CHECK (auto_retry_count BETWEEN 0 AND 100);
  END IF;
END $$;
