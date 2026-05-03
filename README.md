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

```bash
curl -X POST http://localhost:5678/webhook/listing-generate \
  -H 'content-type: application/json' \
  -d '{"shop_id":1,"niche":"vintage botanical printables","kind":"printable","cost":0}'
```

Expected: JSON with `title`, 13 `tags`, `description`, `suggested_price`, plus
a row inserted into `etsy_app.listings` (visible in ToolJet's **Listings** tab).

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
| 2 | AI Visual Studio           | 🟡 stub   | Implement `POST /prompt` to ComfyUI + poll history |
| 3 | AI Ads Studio              | 🟡 stub   | Combines wf 1 + wf 2 outputs into `scheduled_posts` |
| 4 | Etsy OAuth Callback        | 🟡 stub   | PKCE token exchange → upsert `shops` |
| 5 | Etsy Listing Publish       | 🟡 stub   | Create listing via Etsy v3 API |
| 6 | Etsy Order Sync (cron)     | 🟡 stub   | Pull receipts every 15 min, route POD orders to wf 7 |
| 7 | POD Route Order            | 🟡 stub   | Branch on `pod_provider`, call Printify or Printful |
| 8 | Promotion Scheduler (cron) | 🟡 stub   | Dispatch due `scheduled_posts` |

ToolJet tabs **Dashboard / Orders / Analytics** depend on workflow 6 emitting
data into `orders` + `analytics_daily`; once that's live, swap the placeholder
text for the relevant Postgres queries.

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
