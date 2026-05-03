-- =============================================================================
-- Etsy AI Self-Hosted Dashboard — Postgres bootstrap
-- Runs once on first container start (docker-entrypoint-initdb.d).
-- Creates the n8n + tooljet logical DBs alongside the application DB,
-- then creates application tables in etsy_app.
-- =============================================================================

CREATE DATABASE n8n;
CREATE DATABASE tooljet;
CREATE DATABASE etsy_app;

\connect etsy_app

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE shops (
  id            SERIAL PRIMARY KEY,
  name          TEXT NOT NULL,
  etsy_shop_id  TEXT UNIQUE,
  oauth_token   TEXT,
  refresh_token TEXT,
  token_expires TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE products (
  id          SERIAL PRIMARY KEY,
  shop_id     INT REFERENCES shops(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL CHECK (kind IN ('printable','pod')),
  niche       TEXT,
  cost        NUMERIC(10,2) NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX products_shop_idx ON products(shop_id);

CREATE TABLE listings (
  id              SERIAL PRIMARY KEY,
  product_id      INT REFERENCES products(id) ON DELETE CASCADE,
  etsy_listing_id TEXT,
  title           TEXT,
  description     TEXT,
  tags            TEXT[],
  price           NUMERIC(10,2),
  status          TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft','published','error')),
  ai_raw          JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX listings_product_idx ON listings(product_id);
CREATE INDEX listings_status_idx ON listings(status);

CREATE TABLE mockups (
  id          SERIAL PRIMARY KEY,
  listing_id  INT REFERENCES listings(id) ON DELETE CASCADE,
  prompt      TEXT,
  file_path   TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE orders (
  id              SERIAL PRIMARY KEY,
  shop_id         INT REFERENCES shops(id),
  etsy_order_id   TEXT UNIQUE,
  pod_provider    TEXT CHECK (pod_provider IN ('printify','printful') OR pod_provider IS NULL),
  pod_order_id   TEXT,
  status          TEXT,
  total           NUMERIC(10,2),
  profit          NUMERIC(10,2),
  raw             JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX orders_shop_idx ON orders(shop_id);

CREATE TABLE analytics_daily (
  day         DATE NOT NULL,
  shop_id     INT NOT NULL REFERENCES shops(id),
  revenue     NUMERIC(10,2) NOT NULL DEFAULT 0,
  orders      INT NOT NULL DEFAULT 0,
  profit      NUMERIC(10,2) NOT NULL DEFAULT 0,
  PRIMARY KEY (day, shop_id)
);

CREATE TABLE scheduled_posts (
  id            SERIAL PRIMARY KEY,
  listing_id    INT REFERENCES listings(id) ON DELETE CASCADE,
  channel       TEXT NOT NULL CHECK (channel IN ('pinterest','x','instagram','manual')),
  copy          TEXT,
  image_path    TEXT,
  scheduled_for TIMESTAMPTZ,
  status        TEXT NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued','posted','failed')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX scheduled_posts_due_idx ON scheduled_posts(status, scheduled_for);

CREATE TABLE workflow_errors (
  id           SERIAL PRIMARY KEY,
  workflow     TEXT NOT NULL,
  payload      JSONB,
  error        TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed a default shop so the AI Tools form has something to point at on first
-- run. Replace etsy_shop_id once a real shop is connected via OAuth.
INSERT INTO shops (name, etsy_shop_id) VALUES ('Default Shop', NULL);
