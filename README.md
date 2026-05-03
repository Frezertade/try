# Etsy AI Self-Hosted Dashboard

A 100% self-hosted automation stack for managing multiple Etsy shops (digital
printables + POD physical items). Runs entirely on your own GPU server — no
cloud APIs after setup.

> **Status: MVP (v1).** The AI Listing Generator workflow + ToolJet AI Tools
> tab are end-to-end functional. Etsy / Printify / Printful / image generation
> / promotion scheduler are scaffolded as stub workflows ready for extension.
> See [Roadmap](#roadmap) for what's wired vs. stubbed.

---

## Architecture

```
                    ┌──────────────────┐
   Browser ──────►  │ ToolJet (3000)   │  ── REST/Webhook ──┐
                    └──────────────────┘                    │
                                                            ▼
   Browser ──────►  ┌──────────────────┐    ┌────────────────────────┐
                    │ n8n (5678)       │ ── │ Postgres (5432)        │
                    └──┬───────┬────┬──┘    │  n8n / tooljet /        │
                       │       │    │       │  etsy_app DBs           │
                       ▼       ▼    ▼       └────────────────────────┘
                  ┌────────┐ ┌─────────┐ ┌─────────────────────┐
                  │ Ollama │ │ ComfyUI │ │ Etsy / Printify /    │
                  │ 11434  │ │ 8188    │ │ Printful (external) │
                  └────────┘ └─────────┘ └─────────────────────┘
                       ▲                            ▲
                       │                            │
                  ┌────┴────────────────────────────┘
                  │ Caddy 80/443  (optional reverse proxy)
                  └─────────────────────────────────────────
```

All inter-service traffic stays on the `etsy_net` Docker bridge. ComfyUI is
exposed only to `127.0.0.1` because its API has no auth.

> **Why not Ollama for image generation?** Ollama runs text/multimodal LLMs
> only — it cannot run Flux or Stable Diffusion 3. ComfyUI is the local
> image-gen backend; it exposes a `/prompt` HTTP API that n8n calls directly.

---

## Prerequisites

- Linux host with Docker Engine ≥ 24 and Compose v2.
- **NVIDIA GPU with ≥ 16 GB VRAM** (for Flux-dev and Mistral 7B).
  - Install the NVIDIA Container Toolkit:
    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/
  - Verify: `docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi`.
- ~80 GB free disk (Postgres + n8n + Ollama models + Flux checkpoints).
- Outbound internet access on first run (model downloads, Etsy/POD APIs).

---

## Quickstart

```bash
# 1. Configure secrets
cp .env.example .env
$EDITOR .env   # set POSTGRES_PASSWORD, N8N_ENCRYPTION_KEY,
               #     TOOLJET_SECRET_KEY_BASE, TOOLJET_LOCKBOX_KEY
               # generate secrets with: openssl rand -hex 32   (or 64 where noted)

# 2. Bring up Postgres first so the init schema runs
docker compose up -d postgres
docker compose logs -f postgres   # wait for "database system is ready"

# 3. Bring up Ollama and pull text models
docker compose up -d ollama
./scripts/pull-models.sh

# 4. Bring up the rest of the stack
docker compose up -d              # n8n, tooljet, comfyui
./scripts/import-workflows.sh     # bulk-imports all 8 workflow JSONs into n8n

# 5. Configure n8n credentials (one-time, in the n8n UI)
#    - Open http://localhost:5678  (basic auth from .env)
#    - Credentials → New → Postgres
#        Name: "Postgres etsy_app"
#        Host: postgres   Database: etsy_app
#        User: ${POSTGRES_USER}   Password: ${POSTGRES_PASSWORD}
#    - Open workflow "01 - AI Listing Generator" → Activate

# 6. Configure ToolJet (one-time, in the ToolJet UI)
#    - Open http://localhost:3000, create the first admin account
#    - Workspace constants → add N8N_URL = http://n8n:5678
#    - Apps → Import → tooljet-apps/etsy_dashboard.json
#      (this file is a build spec; if your CE version rejects the schema,
#       use it to recreate the pages manually — the queries and components
#       are fully specified)
#    - Set the etsy_app_db data source password to ${POSTGRES_PASSWORD}
```

### Smoke test

**Listing generator (workflow 01):**
```bash
curl -X POST http://localhost:5678/webhook/listing-generate \
  -H 'content-type: application/json' \
  -d '{"shop_id":1,"niche":"vintage botanical printables","kind":"printable","cost":0}'
```

Expected: JSON with `title`, 13 `tags`, `description`, `suggested_price`, plus
a row inserted into `etsy_app.listings` (visible in ToolJet's **Listings** tab).

**Visual studio (workflow 02 — requires a ComfyUI checkpoint installed; see
[ComfyUI models](#comfyui-models)):**
```bash
curl -X POST http://localhost:5678/webhook/visual-generate \
  -H 'content-type: application/json' \
  -d '{"listing_id":1}'
# Returns: { ok:true, mockup:{id, file_path, ...}, view_url:"/webhook/mockup-view?id=N" }

# Fetch the PNG bytes:
curl -o mockup.png "http://localhost:5678/webhook/mockup-view?id=1"
```

---

## AI Visual Studio (workflow 02)

Generates mockup images from a listing via ComfyUI. Two workflows cooperate:

- **`02 - AI Visual Studio`** — `POST /webhook/visual-generate`
  - Body: `{ listing_id, prompt?, negative?, width?, height?, steps?, cfg?, seed?, checkpoint? }`
  - Pulls the listing from Postgres, builds a SDXL/Flux ComfyUI graph, queues it
    on `comfyui:8188/prompt`, polls `/history/<id>`, then writes a row into
    `mockups` and responds with a `view_url`.
- **`02b - Mockup View`** — `GET /webhook/mockup-view?id=<mockup_id>`
  - Looks up the mockup, fetches the PNG from ComfyUI's `/view` endpoint, and
    streams it back. Lets the dashboard browser display images without
    exposing ComfyUI publicly.

The full SDXL graph is built dynamically in workflow 02; a static reference
copy lives at `comfyui/workflows/sdxl_basic_api.json` so you can POST it
directly to verify ComfyUI independently of n8n:

```bash
jq '{prompt: .}' comfyui/workflows/sdxl_basic_api.json \
  | curl -s http://localhost:8188/prompt -H 'content-type: application/json' -d @-
```

To switch from SDXL to **Flux**, drop `flux1-dev.safetensors` into
`comfyui/models/checkpoints/` and pass `"checkpoint":"flux1-dev.safetensors"`
in the webhook body (the ToolJet Visual Studio tab exposes this as a dropdown).

---

## AI Ads Studio (workflow 03)

`POST /webhook/ads-generate`

```json
{
  "listing_id": 1,
  "channels": ["pinterest", "x", "instagram"],
  "generate_visual": true,
  "schedule_at": "2026-05-04T15:00:00Z"
}
```

`channels` defaults to all three. `generate_visual=true` calls workflow 02
internally for a shared 1080² square; failures here are soft (the copy still
queues). `schedule_at` defaults to `now()+1h`.

One Ollama call returns a single JSON object covering every requested channel,
each validated against its character/hashtag limits before insertion. The
workflow fans out one row per channel into `scheduled_posts (status='queued')`
and responds with the inserted rows.

Workflow 08 (Promotion Scheduler — still stubbed) will be the eventual
dispatcher; until then, queued posts can be exported manually from the ToolJet
**AI Ads Studio** tab.

---

## Etsy connect + publish (workflows 04a, 04, 05)

Three workflows cooperate. PKCE OAuth — no client secret needed.

### 1. Configure the Etsy app
- Create an app at https://www.etsy.com/developers/your-apps. Set the
  **Callback URLs** entry to match `ETSY_REDIRECT_URI` from `.env`
  (default `http://localhost:5678/webhook/etsy-oauth-callback`).
- Copy the **Keystring** to `ETSY_CLIENT_ID`. `ETSY_CLIENT_SECRET` is unused
  by the PKCE flow but kept in `.env.example` for compatibility.
- Restart n8n: `docker compose restart n8n`.

### 2. Apply the OAuth migration (existing installs only)
Fresh installs pick this up automatically. For installs that already booted
on the v1 schema:
```bash
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d etsy_app \
  < db/migrations/2026-05-03_etsy_oauth.sql
```

### 3. Connect a shop
Open in a browser:
```
http://localhost:5678/webhook/etsy-connect?shop_name=My+Test+Shop
```
You'll see an "Authorise on Etsy" button. After approving, Etsy redirects
back to `/webhook/etsy-oauth-callback`, which exchanges the code, fetches
the shop, and upserts a row into `shops` with the access + refresh tokens.

### 4. Publish a draft listing
```bash
curl -X POST http://localhost:5678/webhook/etsy-listing-publish \
  -H 'content-type: application/json' \
  -d '{"listing_id":1}'
```
The workflow refreshes the token if it's within 60 s of expiry (writing the
new token back to `shops`), POSTs the createDraftListing payload to
`openapi.etsy.com/v3/application/shops/{shop_id}/listings`, and updates
`listings.etsy_listing_id` + `status='published'`.

Listings always land on Etsy in **draft** state for human review. Flip the
`state` field in the workflow 05 "Build Etsy Payload" node to `active` once
you trust the AI outputs.

> **Heads-up:** the default `taxonomy_id` is `6884` (catch-all art); pick a
> better one per niche from
> https://openapi.etsy.com/v3/application/seller-taxonomy/nodes for higher
> Etsy SEO ranking.

---

## Order sync + POD routing (workflows 06, 07)

### 1. Apply the migration (existing installs)
```bash
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d etsy_app \
  < db/migrations/2026-05-03_orders_pod.sql
```
Adds `shops.last_synced_at`, `shops.pod_provider`, `shops.pod_shop_id`,
`products.pod_metadata`, `orders.line_items`, `orders.error`.

### 2. Activate the workflows
- `06 - Etsy Order Sync` — cron, 15-min interval. For each connected shop:
  refreshes the token if it's near expiry, fetches paid receipts since
  `shops.last_synced_at`, inserts new rows into `orders` (ON CONFLICT DO
  NOTHING), then POSTs each new order to wf 07 via webhook. Idempotent.
- `07 - POD Route Order` — `POST /webhook/pod-route {order_id}`. Joins line
  items with `products.pod_metadata`, builds the Printify or Printful
  create-order payload, dispatches it, and records `pod_provider` +
  `pod_order_id` + `status='pod_routed'`. Soft-fails to `status='pod_pending'`
  with the reason in `orders.error` if:
  - the shop has no `pod_provider` / `pod_shop_id` set,
  - any POD line item's `products.pod_metadata` is missing,
  - the relevant `PRINTIFY_API_KEY` / `PRINTFUL_API_KEY` is unset.

### 3. Configure POD on each shop
Open the ToolJet **Shops** tab, select a shop, set the provider + provider
store id, save. Or directly:
```sql
UPDATE shops SET pod_provider = 'printify', pod_shop_id = '12345' WHERE id = 1;
```

### 4. Map products to provider catalogues
Each POD product needs `pod_metadata` populated with the provider's product
ids. For example, for Printify:
```sql
UPDATE products SET pod_metadata = jsonb_build_object(
  'product_id', 'pf_product_abc',
  'variant_id', 4011
) WHERE id = 5;
```
Until that's set, orders for the product land in `status='pod_pending'` —
useful as a worklist surfaced in the **Orders** tab.

### 5. Smoke test
```bash
# Force-trigger the cron
curl -X POST http://localhost:5678/rest/workflows/06/run \
  -u "$N8N_BASIC_AUTH_USER:$N8N_BASIC_AUTH_PASSWORD"
# Or just wait 15 minutes after a real Etsy purchase; orders rows appear.

# Manual POD reroute for a stuck order
curl -X POST http://localhost:5678/webhook/pod-route \
  -H 'content-type: application/json' \
  -d '{"order_id": 1}'
```

---

## Promotion scheduler (workflow 08)

`08 - Promotion Scheduler` runs every 5 minutes. It pulls
`scheduled_posts WHERE status='queued' AND scheduled_for<=now()` (limit 25)
and dispatches each post to the outgoing webhook URL for its channel.

### 1. Apply the migration (existing installs)
```bash
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d etsy_app \
  < db/migrations/2026-05-03_promotion_scheduler.sql
```
Relaxes `scheduled_posts.status` to allow the new `'ready_for_export'` value.

### 2. Configure per-channel webhook URLs
Set any combination in `.env`:
```
PINTEREST_WEBHOOK_URL=https://your-buffer-or-make-or-zapier-endpoint.example
X_WEBHOOK_URL=
INSTAGRAM_WEBHOOK_URL=
```
Each URL receives a JSON `POST` with:
```json
{ "post_id": 1, "listing_id": 42, "channel": "pinterest",
  "copy": "...", "image_path": "etsy/listing-42/00001.png",
  "scheduled_for": "2026-05-04T15:00:00Z" }
```
Restart n8n after changes (`docker compose restart n8n`) so the new env
vars are visible to Code nodes.

A 2xx response → `status='posted'`. Any non-2xx or network error →
`status='failed'`. **No URL configured for a channel → the post moves to
`status='ready_for_export'`** and shows up in the AI Ads Studio table for
manual handling. This sidesteps building three separate OAuth integrations
(Pinterest, X, Instagram) while still giving a real automation path: point
the URL at Buffer, Make.com, Zapier, or another n8n workflow that owns the
channel-specific OAuth.

### Smoke test
```bash
# Queue an immediate post
curl -X POST http://localhost:5678/webhook/ads-generate \
  -H 'content-type: application/json' \
  -d '{"listing_id":1,"channels":["pinterest"],"schedule_at":"2026-01-01T00:00:00Z"}'

# Manually trigger wf 08 from the n8n UI, or wait <5 min
docker compose exec postgres psql -U "$POSTGRES_USER" -d etsy_app \
  -c "SELECT id, channel, status FROM scheduled_posts ORDER BY id DESC LIMIT 5;"
```

---

## ComfyUI models

ComfyUI ships without checkpoints. Drop weights into `comfyui/models/checkpoints/`:

```bash
mkdir -p comfyui/models/checkpoints
# Flux-dev fp8 (~17 GB, gated on Hugging Face — accept the license first)
huggingface-cli download black-forest-labs/FLUX.1-dev \
  flux1-dev.safetensors --local-dir comfyui/models/checkpoints
# OR a smaller starter model:
huggingface-cli download stabilityai/stable-diffusion-xl-base-1.0 \
  sd_xl_base_1.0.safetensors --local-dir comfyui/models/checkpoints
docker compose restart comfyui
```

Sanity check: `curl http://localhost:8188/system_stats` returns GPU info.

---

## Getting API keys

### Etsy
1. Sign in at https://www.etsy.com/developers/your-apps and create an app.
2. Copy the **Keystring** (client id) and **Shared Secret**.
3. Add the redirect URI from `.env` (`ETSY_REDIRECT_URI`) to the app's
   "Callback URLs" list.
4. Paste both values into `.env` and restart n8n: `docker compose restart n8n`.

### Printify
- Profile → **Connections** → "Generate new token" →
  set `PRINTIFY_API_KEY` in `.env`.

### Printful
- https://developers.printful.com/ → **Tokens** → create a personal token →
  set `PRINTFUL_API_KEY` in `.env`.

---

## External access (optional)

### Caddy + Let's Encrypt
Set `PUBLIC_DOMAIN` and `LETSENCRYPT_EMAIL` in `.env`, point DNS at the host,
then:

```bash
docker compose --profile proxy up -d caddy
```

Reachable at `https://dashboard.<domain>` and `https://n8n.<domain>`.

### ngrok (dev only)
```bash
ngrok http 3000   # ToolJet
ngrok http 5678   # n8n webhooks (use this URL as ETSY_REDIRECT_URI)
```

---

## Security best practices

- Never commit `.env`. `.gitignore` excludes it.
- `N8N_ENCRYPTION_KEY` encrypts every credential stored in n8n. **Rotating it
  invalidates all stored credentials** — only rotate on a fresh install.
- Keep ComfyUI bound to `127.0.0.1` (default in `docker-compose.yml`). It has
  no auth; never expose `:8188` publicly.
- Put n8n + ToolJet behind Caddy basic-auth, or an OIDC sidecar
  (oauth2-proxy / Authelia), before exposing them to the internet.
- Use a dedicated Postgres role per app in production; the MVP uses a single
  superuser for simplicity.
- Rotate Etsy / Printify / Printful tokens periodically and revoke them in the
  provider UIs when removing a shop.

---

## Roadmap

| # | Workflow                  | v1 status | Notes |
|---|---------------------------|-----------|-------|
| 1 | AI Listing Generator       | ✅ wired  | Mistral via Ollama; inserts draft listing |
| 2 | AI Visual Studio           | ✅ wired  | SDXL/Flux via ComfyUI; mockups proxied through wf 02b |
| 3 | AI Ads Studio              | ✅ wired  | Pinterest/X/Instagram copy via Ollama + optional visual |
| 4 | Etsy Connect + OAuth (04a, 04) | ✅ wired | PKCE flow; shops auto-upserted on callback |
| 5 | Etsy Listing Publish       | ✅ wired  | Token refresh + createDraftListing in `state=draft` |
| 6 | Etsy Order Sync (cron)     | ✅ wired  | 15-min cron, watermarked, refreshes tokens, dispatches POD |
| 7 | POD Route Order            | ✅ wired  | Printify + Printful; soft-fails to `status=pod_pending` if metadata missing |
| 8 | Promotion Scheduler (cron) | ✅ wired  | 5-min cron, per-channel outgoing webhook handoff |

All eight workflows are now end-to-end. Dashboard KPIs read from `orders`
directly (no analytics_daily rollup needed for v1).

---

## File layout

```
.
├── docker-compose.yml            # 6 services: postgres, n8n, tooljet, ollama, comfyui, caddy
├── .env.example                  # all required env vars
├── db/init/01_schema.sql         # creates n8n + tooljet + etsy_app DBs and tables
├── workflows/                    # n8n workflow exports (1 fully wired, 7 stubs)
├── tooljet-apps/etsy_dashboard.json   # ToolJet app build spec
├── scripts/
│   ├── pull-models.sh            # ollama pull loop
│   └── import-workflows.sh       # n8n CLI bulk import
├── caddy/Caddyfile               # optional reverse proxy
└── README.md
```

---

## Troubleshooting

- **n8n workflow 01 fails at "Insert Product"** → the `Postgres etsy_app`
  credential isn't configured. Create it in n8n (see Quickstart step 5).
- **Ollama returns non-JSON** → the model may not honour `format=json`. Switch
  `OLLAMA_MODELS` to `qwen2.5:7b-instruct-q4_K_M` and re-pull.
- **ComfyUI container exits immediately** → host doesn't have GPU access. Run
  `nvidia-smi` inside `nvidia/cuda` first; fix the toolkit setup.
- **ToolJet rejects the app JSON on import** → ToolJet's export format is
  version-coupled. Use `tooljet-apps/etsy_dashboard.json` as the spec and
  recreate pages/queries manually in the UI.
