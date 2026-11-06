-- Independent company bridge. Does not import or reset any legacy state.
CREATE TABLE company_bridge_state (
  uid text PRIMARY KEY REFERENCES devices(uid) ON DELETE CASCADE,
  epoch uuid NOT NULL,
  activated_at timestamptz NOT NULL
);
CREATE TABLE company_bridge_receipts (
  uid text NOT NULL REFERENCES company_bridge_state(uid) ON DELETE CASCADE,
  request_id uuid NOT NULL,
  digest text NOT NULL,
  receipt jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(uid,request_id)
);
