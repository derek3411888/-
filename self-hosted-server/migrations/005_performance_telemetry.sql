CREATE TABLE IF NOT EXISTS performance_minutes (
  uid text NOT NULL REFERENCES devices(uid) ON DELETE CASCADE,
  bucket_start timestamptz NOT NULL,
  sample_count integer NOT NULL DEFAULT 0 CHECK (sample_count >= 0 AND sample_count <= 3600),
  metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  context jsonb NOT NULL DEFAULT '{}'::jsonb,
  collector jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(uid, bucket_start)
);

CREATE INDEX IF NOT EXISTS performance_minutes_uid_time_idx
  ON performance_minutes(uid, bucket_start DESC);
