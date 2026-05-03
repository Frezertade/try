-- =============================================================================
-- Promotion scheduler — relaxes scheduled_posts.status to allow
-- 'ready_for_export' (set by wf 08 when a channel has no outgoing webhook
-- configured, so the operator can post manually).
-- Runs after 03_orders_pod.sql on a fresh Postgres data volume.
-- For existing installs, apply db/migrations/2026-05-03_promotion_scheduler.sql.
-- =============================================================================

\connect etsy_app

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'scheduled_posts_status_check') THEN
    ALTER TABLE scheduled_posts DROP CONSTRAINT scheduled_posts_status_check;
  END IF;
  ALTER TABLE scheduled_posts ADD CONSTRAINT scheduled_posts_status_check
    CHECK (status IN ('queued','posted','failed','ready_for_export'));
END $$;
