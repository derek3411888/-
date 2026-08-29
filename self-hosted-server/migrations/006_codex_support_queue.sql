CREATE TABLE IF NOT EXISTS codex_support_requests (
  id bigserial PRIMARY KEY,
  mode text NOT NULL,
  label text NOT NULL,
  message text NOT NULL,
  message_length integer NOT NULL,
  device_uid text REFERENCES devices(uid) ON DELETE SET NULL,
  context text NOT NULL DEFAULT '',
  context_length integer NOT NULL DEFAULT 0,
  context_included boolean NOT NULL DEFAULT false,
  log_available boolean NOT NULL DEFAULT false,
  log_file_name text NOT NULL DEFAULT '',
  state text NOT NULL DEFAULT 'PENDING',
  detail text NOT NULL DEFAULT '',
  received_at timestamptz,
  validated_at timestamptz,
  attempt_count integer NOT NULL DEFAULT 0,
  last_attempt_at timestamptz,
  next_retry_at timestamptz,
  queued_at timestamptz,
  message_sha256 text NOT NULL DEFAULT '',
  error_code text NOT NULL DEFAULT '',
  error_detail text NOT NULL DEFAULT '',
  bridge_host text NOT NULL DEFAULT '',
  bridge_version text NOT NULL DEFAULT '',
  bridge_heartbeat_at timestamptz,
  claim_generation integer NOT NULL DEFAULT 0,
  claimed_by text NOT NULL DEFAULT '',
  claimed_at timestamptz,
  claim_expires_at timestamptz,
  cancelled_at timestamptz,
  retry_of_id bigint REFERENCES codex_support_requests(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (state IN ('PENDING','RECEIVED','VALIDATING','QUEUEING','RETRYING','QUEUED','REJECTED','RATE_LIMITED','FAILED','CANCELLED')),
  CHECK (message_length >= 1 AND message_length <= 1000),
  CHECK (context_length >= 0 AND context_length <= 14000),
  CHECK (claim_generation >= 0),
  CHECK (claimed_by = '' OR (
    char_length(claimed_by) BETWEEN 8 AND 160
    AND claimed_by ~ '^[A-Za-z0-9._:@-]+$'
  ))
);

CREATE INDEX IF NOT EXISTS codex_support_requests_pending_idx
  ON codex_support_requests(state, next_retry_at, claim_expires_at, id)
  WHERE state IN ('PENDING','RETRYING');

CREATE INDEX IF NOT EXISTS codex_support_requests_created_idx
  ON codex_support_requests(created_at DESC);
