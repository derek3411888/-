-- Bridge 3.1 could leave a direct request in IN_PROGRESS forever after it
-- associated a later Codex turn with an older website message. Mark only
-- records that have no final response and have not been checked for ten
-- minutes as a visible, retryable failure; completed responses are untouched.
UPDATE codex_support_requests
SET response_state = 'FAILED',
    codex_turn_id = '',
    codex_turn_status = 'legacyCorrelationRejected',
    codex_response_at = now(),
    codex_reply_error = '舊版橋接無法證明這筆回覆與請求相符；請按重送建立新請求',
    codex_reply_checked_at = now(),
    updated_at = now()
WHERE state = 'QUEUED'
  AND response_state = 'IN_PROGRESS'
  AND codex_response = ''
  AND codex_response_at IS NULL
  AND COALESCE(codex_reply_checked_at, queued_at, created_at) < now() - interval '10 minutes';
