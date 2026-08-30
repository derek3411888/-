ALTER TABLE codex_support_requests
  ADD COLUMN IF NOT EXISTS response_state text NOT NULL DEFAULT 'WAITING',
  ADD COLUMN IF NOT EXISTS codex_turn_id text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS codex_turn_status text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS codex_response text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS codex_response_sha256 text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS codex_response_at timestamptz,
  ADD COLUMN IF NOT EXISTS codex_reply_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS codex_reply_error text NOT NULL DEFAULT '';

ALTER TABLE codex_support_requests
  DROP CONSTRAINT IF EXISTS codex_support_requests_response_state_check;

ALTER TABLE codex_support_requests
  ADD CONSTRAINT codex_support_requests_response_state_check
  CHECK (response_state IN ('WAITING','IN_PROGRESS','COMPLETED','FAILED','INTERRUPTED'));

CREATE INDEX IF NOT EXISTS codex_support_requests_response_pending_idx
  ON codex_support_requests(response_state, id)
  WHERE state='QUEUED' AND response_state IN ('WAITING','IN_PROGRESS');
