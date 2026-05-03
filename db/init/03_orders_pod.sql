-- =============================================================================
-- Orders + POD — schema additions for workflows 06 and 07.
-- Runs after 02_etsy_oauth.sql on a fresh Postgres data volume.
-- For existing installs, apply db/migrations/2026-05-03_orders_pod.sql.
-- =============================================================================

\connect etsy_app

ALTER TABLE shops
  ADD COLUMN IF NOT EXISTS last_synced_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS pod_provider   TEXT,
  ADD COLUMN IF NOT EXISTS pod_shop_id    TEXT;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'shops_pod_provider_check') THEN
    ALTER TABLE shops ADD CONSTRAINT shops_pod_provider_check
      CHECK (pod_provider IN ('printify','printful') OR pod_provider IS NULL);
  END IF;
END $$;

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS pod_metadata JSONB;

ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS line_items JSONB,
  ADD COLUMN IF NOT EXISTS error      TEXT;
