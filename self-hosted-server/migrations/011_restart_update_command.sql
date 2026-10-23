-- Extend the existing allowlist for capability-gated managed application restart.
-- The migrator wraps this replacement in one transaction; old commands stay valid.
ALTER TABLE commands DROP CONSTRAINT IF EXISTS commands_command_check;
ALTER TABLE commands ADD CONSTRAINT commands_command_check
  CHECK (command IN ('RUN','PAUSE','STOP','SWITCH_SERVER','COMPLETE_SERVER','RESTART_UPDATE'));
