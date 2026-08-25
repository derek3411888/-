CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS system_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO system_settings(key, value)
VALUES
  ('migration', jsonb_build_object(
    'mode', COALESCE(NULLIF(current_setting('app.migration_mode', true), ''), 'shadow'),
    'shadowStartedAt', to_jsonb(now()),
    'consistencyErrors', 0
  )),
  ('enrollment', '{"openUntil":null}'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS devices (
  uid text PRIMARY KEY CHECK (uid ~ '^[A-Za-z0-9._@-]{3,160}$'),
  display_name text NOT NULL DEFAULT '',
  device_alias text NOT NULL DEFAULT '',
  state text NOT NULL DEFAULT 'OFFLINE',
  status jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_seen timestamptz,
  last_nonce bigint NOT NULL DEFAULT 0,
  command_nonce bigint NOT NULL DEFAULT 0,
  settings_revision bigint NOT NULL DEFAULT 0,
  settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  settings_ack jsonb NOT NULL DEFAULT '{}'::jsonb,
  imported_from_firestore boolean NOT NULL DEFAULT false,
  credential_issued_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS enrollment_allowlist (
  uid text PRIMARY KEY REFERENCES devices(uid) ON DELETE CASCADE,
  source text NOT NULL DEFAULT 'firestore',
  expires_at timestamptz,
  claimed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS device_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  uid text NOT NULL REFERENCES devices(uid) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  label text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS device_credentials_uid_idx ON device_credentials(uid) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS commands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  uid text NOT NULL REFERENCES devices(uid) ON DELETE CASCADE,
  nonce bigint NOT NULL,
  command text NOT NULL CHECK (command IN ('RUN','PAUSE','STOP','SWITCH_SERVER','COMPLETE_SERVER')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key text,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','ACKED','CANCELLED','SUPERSEDED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  acked_at timestamptz,
  ack_result text,
  ack_detail text,
  ack_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  UNIQUE(uid, nonce),
  UNIQUE(uid, idempotency_key)
);
CREATE UNIQUE INDEX IF NOT EXISTS commands_one_pending_idx ON commands(uid) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS commands_history_idx ON commands(uid, created_at DESC);

CREATE TABLE IF NOT EXISTS settings_revisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  uid text NOT NULL REFERENCES devices(uid) ON DELETE CASCADE,
  revision bigint NOT NULL,
  settings jsonb NOT NULL,
  status text NOT NULL DEFAULT 'PENDING',
  created_at timestamptz NOT NULL DEFAULT now(),
  acked_at timestamptz,
  ack_result text,
  ack_detail text,
  UNIQUE(uid, revision)
);

CREATE TABLE IF NOT EXISTS runtime_events (
  id bigserial PRIMARY KEY,
  uid text NOT NULL REFERENCES devices(uid) ON DELETE CASCADE,
  event_key text NOT NULL,
  event_at timestamptz NOT NULL,
  level text NOT NULL DEFAULT 'INFO',
  name text NOT NULL,
  detail text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(uid, event_key)
);
CREATE INDEX IF NOT EXISTS runtime_events_recent_idx ON runtime_events(uid, event_at DESC);

CREATE TABLE IF NOT EXISTS snapshots (
  uid text PRIMARY KEY REFERENCES devices(uid) ON DELETE CASCADE,
  relative_path text NOT NULL,
  captured_at timestamptz NOT NULL,
  width integer NOT NULL DEFAULT 0,
  height integer NOT NULL DEFAULT 0,
  reason text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS diagnostic_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  uid text NOT NULL REFERENCES devices(uid) ON DELETE CASCADE,
  relative_path text NOT NULL,
  captured_at timestamptz NOT NULL,
  level text NOT NULL,
  reason text NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS diagnostic_snapshots_recent_idx ON diagnostic_snapshots(uid, captured_at DESC);

CREATE TABLE IF NOT EXISTS recording_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  uid text NOT NULL REFERENCES devices(uid) ON DELETE CASCADE,
  client_session_id text NOT NULL,
  base_name text NOT NULL,
  state text NOT NULL DEFAULT 'UPLOADING',
  detail text NOT NULL DEFAULT '',
  expected_segments integer,
  started_at timestamptz,
  completed_at timestamptz,
  final_relative_path text,
  final_size bigint,
  duration_seconds double precision,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(uid, client_session_id)
);
CREATE INDEX IF NOT EXISTS recording_sessions_recent_idx ON recording_sessions(uid, created_at DESC);

CREATE TABLE IF NOT EXISTS recording_segments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE,
  segment_index integer NOT NULL CHECK (segment_index >= 0),
  original_name text NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes > 0),
  sha256 text NOT NULL CHECK (sha256 ~ '^[a-f0-9]{64}$'),
  received_bytes bigint NOT NULL DEFAULT 0,
  upload_relative_path text,
  mp4_relative_path text,
  state text NOT NULL DEFAULT 'UPLOADING',
  duration_seconds double precision,
  error_detail text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(session_id, segment_index)
);

CREATE TABLE IF NOT EXISTS browser_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash text NOT NULL UNIQUE,
  label text NOT NULL DEFAULT '',
  user_agent text NOT NULL DEFAULT '',
  ip_address text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS activation_tokens (
  token_hash text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at timestamptz
);

CREATE TABLE IF NOT EXISTS live_leases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  uid text NOT NULL REFERENCES devices(uid) ON DELETE CASCADE,
  browser_session_id uuid NOT NULL REFERENCES browser_sessions(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(uid, browser_session_id)
);
CREATE INDEX IF NOT EXISTS live_leases_active_idx ON live_leases(uid, expires_at);

CREATE TABLE IF NOT EXISTS server_alerts (
  id bigserial PRIMARY KEY,
  level text NOT NULL DEFAULT 'WARN',
  code text NOT NULL,
  message text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  cleared_at timestamptz
);
