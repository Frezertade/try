-- Apply against an existing etsy_app database to enable workflows 06 + 07:
--   docker compose exec -T postgres psql -U $POSTGRES_USER -d etsy_app \
--     < db/migrations/2026-05-03_orders_pod.sql
-- For fresh installs the same statements run via db/init/03_orders_pod.sql.

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
