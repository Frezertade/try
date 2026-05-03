-- =============================================================================
-- Etsy OAuth — PKCE state store
-- Runs after 01_schema.sql on a fresh Postgres data volume.
-- For existing installs, apply the identical file in db/migrations/.
-- =============================================================================

\connect etsy_app

CREATE TABLE IF NOT EXISTS oauth_states (
  state         TEXT PRIMARY KEY,
  shop_name     TEXT NOT NULL,
  code_verifier TEXT NOT NULL,
  redirect_uri  TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '10 minutes')
);

CREATE INDEX IF NOT EXISTS oauth_states_expires_idx ON oauth_states(expires_at);
