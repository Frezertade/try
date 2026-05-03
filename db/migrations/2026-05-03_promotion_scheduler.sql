-- Apply against an existing etsy_app database to enable workflow 08:
--   docker compose exec -T postgres psql -U $POSTGRES_USER -d etsy_app \
--     < db/migrations/2026-05-03_promotion_scheduler.sql
-- For fresh installs the same statements run via db/init/04_promotion_scheduler.sql.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'scheduled_posts_status_check') THEN
    ALTER TABLE scheduled_posts DROP CONSTRAINT scheduled_posts_status_check;
  END IF;
  ALTER TABLE scheduled_posts ADD CONSTRAINT scheduled_posts_status_check
    CHECK (status IN ('queued','posted','failed','ready_for_export'));
END $$;
