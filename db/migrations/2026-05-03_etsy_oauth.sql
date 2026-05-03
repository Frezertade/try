-- Apply against an existing etsy_app database to enable the Etsy OAuth workflows:
--   docker compose exec -T postgres psql -U $POSTGRES_USER -d etsy_app \
--     < db/migrations/2026-05-03_etsy_oauth.sql
-- For fresh installs the same statements run via db/init/02_etsy_oauth.sql.

CREATE TABLE IF NOT EXISTS oauth_states (
  state         TEXT PRIMARY KEY,
  shop_name     TEXT NOT NULL,
  code_verifier TEXT NOT NULL,
  redirect_uri  TEXT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '10 minutes')
);

CREATE INDEX IF NOT EXISTS oauth_states_expires_idx ON oauth_states(expires_at);
