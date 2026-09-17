# Hermes-lite
<b>Hermes agent on railway.</b>
Optimized for free tier Railway limitations.

Deploy the official [Hermes Agent](https://github.com/NousResearch/hermes-agent) container on Railway.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/template/TEMPLATE_ID?referralCode=REFERRAL_CODE)

## What this template provides

This repository is a thin Railway deployment layer around the official Hermes Agent container. Hermes remains responsible for the agent runtime, gateway, dashboard, authentication, and process supervision.

The template adds:

- a pinned Hermes release for reproducible builds;
- Railway `PORT` handling;
- the built-in Hermes dashboard on the Railway public port;
- persistent Hermes state at `/data/.hermes` (Railway volume mounted at `/data`);
- browser automation is disabled by default;
- image pruning for build-time files and unused development content;
- build-time SQLite compatibility and runtime dashboard smoke checks;
- Railway health checks at `/api/health`.

The container continues to use Hermes' own s6-overlay supervision and entrypoint dispatcher. No custom gateway supervisor, runtime Git update, or separate dashboard proxy is introduced.

## Deploy

### 1. Create the Railway service

Deploy this repository as a Dockerfile-based Railway service and generate a public domain for the service.

### 2. Configure environment variables

The dashboard is exposed on Railway's public network, so configure Hermes' built-in Basic Auth provider. All other variables are optional and can be set directly in Railway → Variables as needed.

#### Dashboard & Security

| Variable | Required | Description |
|---|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | Yes | Dashboard login username. |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | Yes | Strong dashboard password (set as Railway secret). |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | Recommended | Stable signing key so login sessions survive container restarts. If omitted, Hermes generates a per-process key and logs you out on restart. |
| `HERMES_DASHBOARD_PUBLIC_URL` | No | Public URL override for OAuth callbacks (auto-detected from Railway domain if empty). |
| `HERMES_DASHBOARD_PORTAL_URL` | No | Nous Portal URL override (default production portal). |
| `HERMES_DASHBOARD_OAUTH_CLIENT_ID` | No | OAuth client ID when using Nous/OIDC instead of Basic Auth. |

#### Telegram
Can be set in Hermes's dashboard after deploy.

| Variable | Required | Description |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | No | Bot token from @BotFather — required only if you use Telegram. |
| `TELEGRAM_ALLOWED_USERS` | No | Comma-separated Telegram user IDs allowed to talk to the bot. |
| `TELEGRAM_ALLOW_ALL_USERS` | No | Set `true` to allow any Telegram user (dev only, not recommended). |
| `TELEGRAM_HOME_CHANNEL` | No | Default chat ID for cron / notification delivery. |
| `TELEGRAM_HOME_CHANNEL_NAME` | No | Display name for the home channel. |

#### Model Providers (set the one you use)
Can be set in Hermes's dashboard after deploy.

| Variable | Required | Description |
|---|---|---|
| `OPENAI_API_KEY` | No | OpenAI API key. |
| `OPENAI_BASE_URL` | No | Custom OpenAI-compatible base URL (for local models, vLLM, etc.). |
| `ANTHROPIC_API_KEY` | No | Anthropic API key. |
| `OPENROUTER_API_KEY` | No | OpenRouter API key (for vision, web scraping helpers, MoA). |
| `GOOGLE_API_KEY` / `GEMINI_API_KEY` | No | Google AI Studio API key (aliases). |
| `XAI_API_KEY` | No | xAI API key (Grok). |
| `MISTRAL_API_KEY` | No | Mistral API key. |
| `GROQ_API_KEY` | No | Groq API key. |
| `DEEPSEEK_API_KEY` | No | DeepSeek API key. |
| `HERMES_INFERENCE_MODEL` | No | Override default model (e.g. `gpt-4o`, `claude-sonnet-4`). |
| `HERMES_INFERENCE_PROVIDER` | No | Override provider (e.g. `openai`, `anthropic`, `openrouter`). |

#### Railway & Runtime

| Variable | Required | Description |
|---|---|---|
| `PORT` | No | Injected by Railway automatically — do not set manually. Validated and mapped to `HERMES_DASHBOARD_PORT`. |
| `HERMES_HOME` | No | Persistent data dir. This template sets it to `/data/.hermes`, inside the volume mounted at `/data`. |
| `HERMES_DASHBOARD` | No | Set `1` to enable dashboard (already set in Dockerfile). |
| `KEEP_BROWSER` | Optional | Build-time arg only (`0` = minimal ~1.1GB, `1` = with Chromium). Not a runtime variable. |

> Hermes also supports OAuth/OIDC. Current upstream documentation recommends OAuth/OIDC for direct public-internet exposure, while Basic Auth is the simple built-in login mechanism used by this template.

### 3. Add persistent storage (Recommended)
On the free tier, attaching a Railway Volume at `/data` gives you 1 GB of storage instead of the default 0.5 GB. <b>Without a volume your Hermes data is not persistent</b> — it is lost on every redeploy — so you would need to back your files up manually or with a cron job.

Attach a Railway Volume at:

```text
/data
```

This template moves Hermes' persistent `HERMES_HOME` to `/data/.hermes`, inside that volume. Configuration, credentials, sessions, memories, skills, logs, cron state, profiles, and other persistent runtime data all live there. Unlike the official container (where `HERMES_HOME` is `/opt/data`), the volume mount point and the Hermes home are different paths: the boot-time setup hook creates and chowns `HERMES_HOME` as root before any supervised process starts, so a fresh empty volume is bootstrapped on first boot. The template also patches the upstream dashboard service and main-program wrapper to reset `HOME` to `$HERMES_HOME` (upstream hard-codes `/opt/data`), so HOME-anchored state lands on the volume too.

Note: lazy dependency installs are disabled (`HERMES_DISABLE_LAZY_INSTALLS=1`) and their target is `/data/lazy-packages`. If you re-enable them via Hermes config, that directory must be writable by the `hermes` user.

### 4. Configure Hermes

Open the Railway public URL, sign in, and finish the Hermes setup. Configure your model provider and messaging integrations from the dashboard or through Railway environment variables as appropriate.

## Browser automation

Browser automation is **disabled by default** in this optimized template for Railway's free tier (saves storage and it won't work correctly with 0.5GB of RAM). This is the cleanest setup.

- Default: `KEEP_BROWSER=0` — no Playwright/Chromium, minimal disk/RAM, fastest cold start.
- All 20 platforms (including Telegram) and dashboard remain fully functional.

To enable browser automation, build with:

```text
KEEP_BROWSER=1
```

Browser workloads need more memory than a messaging-only deployment. Size the Railway service accordingly if you enable it.

## Dashboard and Chat

The built-in Hermes web dashboard runs as a supervised service alongside the gateway. Its Chat tab can launch Hermes' bundled in-browser TUI runtime. This template keeps the required Node runtime and TUI bundle so that dashboard chat remains available.

The dashboard is bound to `0.0.0.0` and receives the same port Railway assigns through `PORT`.

## Ports and health checks

Railway injects a `PORT` environment variable. The template's entrypoint validates that value and makes it authoritative by exporting the same value as `HERMES_DASHBOARD_PORT`.

Railway probes:

```text
GET /api/health
```

The health endpoint is a read-only dashboard health endpoint intended for service readiness checks.

## Persistence and security

The dashboard filesystem scope is restricted to:

```text
/
```

The agent's general write safety root is:

```text
/data
```

The write safety root keeps the agent's `write_file`/`patch` tools confined to the mounted data volume. Note that `HERMES_DASHBOARD_FILES_ROOT=/` is an intentional choice in this template: the dashboard file browser can reach the entire container filesystem (including the read-only `/opt/hermes` install tree). If you want the dashboard to see only persistent state, set it to `/data/.hermes` in the Dockerfile.

Keep dashboard credentials in Railway's secret environment variables. For Basic Auth, also set `HERMES_DASHBOARD_BASIC_AUTH_SECRET` so sessions remain valid across restarts. Hermes documents that omitting this secret generates a new per-process signing key and logs users out after a restart.

## Hermes versioning

The template pins the upstream image to a released Hermes version:

```dockerfile
ARG HERMES_IMAGE=nousresearch/hermes-agent:v2026.9.14
```

This is deliberate. The pruning rules and build-time verification depend on the filesystem and runtime contract of the pinned Hermes release. Upgrade Hermes by changing the pinned release intentionally, then rebuild and test the template before deploying it.

The pinned release is published for both Linux amd64 and arm64.

## Build validation

The Docker build performs several checks before producing the final image:

1. verifies the SQLite version is at least `3.51.3`;
2. validates retained Hermes Python modules and runtime assets;
3. starts the dashboard locally and verifies `/api/health` returns HTTP 200;
4. aligns `HOME` in the upstream dashboard service and main-program wrapper with `HERMES_HOME` (failing the build if the upstream lines drift);
5. confirms that the build-time verification did not leave state in `/data`.

These checks are intentionally performed before the pruned image is flattened so a broken pruning change fails the build instead of reaching Railway.

## Architecture

```text
Railway public HTTP
        │
        ▼
Railway PORT
        │
        ▼
/railway-entrypoint.sh
        │
        ▼
Hermes entrypoint-dispatch.sh
        │
        ▼
s6-overlay supervision
   ┌────┴────────────┐
   │                 │
Dashboard          Gateway
   │                 │
   └──────┬──────────┘
          ▼
     /data/.hermes
     HERMES_HOME (volume: /data)
```

The entrypoint dispatcher is kept intact because Hermes uses it to preserve normal s6-overlay PID-1 startup while also supporting runtimes where the image entrypoint is not PID 1.

## Updating the template

When upgrading Hermes:

1. change `HERMES_IMAGE` to the new released Hermes tag;
2. review the upstream Docker/runtime changes;
3. validate every pruning rule and the HOME-alignment patch in `prune.sh` against the new image (it fails the build if the patched lines drift);
4. rebuild the image;
5. run the dashboard and browser-enabled smoke tests;
6. deploy the updated image to Railway.

Do not switch back to `latest` unless you are intentionally accepting unreviewed upstream filesystem and runtime changes.

## Changelog

### Data root moved to `/data` (layout change)

- `HERMES_HOME` moved from `/opt/data` to `/data/.hermes`; the Railway Volume mount point is now `/data`.
- `HERMES_WRITE_SAFE_ROOT` is now `/data`; `HERMES_DASHBOARD_FILES_ROOT` is now `/` (the dashboard file browser can reach the whole container filesystem); `HERMES_LAZY_INSTALL_TARGET` moved to `/data/lazy-packages`; the user-local `PATH` entry moved to `/data/.local/bin`.
- `prune.sh` now patches the upstream `s6-rc.d/dashboard/run` service and `docker/main-wrapper.sh` to set `HOME` to `$HERMES_HOME` (upstream v2026.9.14 hard-codes `/opt/data`), so HOME-anchored state persists on the volume. The patch fails the build if the upstream lines change.
- The build-time clean-data guard now checks the `/data` volume mountpoint instead of `/opt/data`.

### v2026.9.14 (Hermes v0.21.3)

- Re-pinned the upstream image from `v2026.8.31` to `v2026.9.14`.
- Verified against the new tag: the upstream Dockerfile diff is only the baked-in `google-chat` Python extra, so the base image (Debian 13.4, Python 3.13, Node 26, s6-overlay 3.2.3.0), the `/opt/hermes` layout, the `docker/entrypoint-dispatch.sh` + `main-wrapper.sh` + `s6-rc.d` supervision contract, and the dashboard runtime (including `HERMES_DASHBOARD_PORT` and the `HERMES_DASHBOARD_BASIC_AUTH_*` provider) are unchanged. All `prune.sh` rules, module-import checks, and `must`-list assets were re-verified against the new tag; no prune rule needed changes (`/opt/hermes/mcp-research-data` no longer exists upstream, so that rule is now a defensive no-op).
- Fixed the free-tier storage wording in the persistence section.

Persistent data under `/data` remains separate from the immutable application image, so replacing the image does not replace the attached Railway Volume.

## Project files

| File | Purpose |
|---|---|
| `Dockerfile` | Pins Hermes, performs the two-stage prune/flatten build, and defines the Railway runtime. |
| `prune.sh` | Removes build-only content, aligns `HOME` with `HERMES_HOME`, and verifies the pruned Hermes runtime. |
| `railway-entrypoint.sh` | Validates Railway `PORT`, maps it to Hermes, and delegates to Hermes' dispatcher. |
| `railway.json` | Defines Railway health-check and restart behavior. |
| `README.md` | Canonical deployment, configuration, architecture, and maintenance guide. |

## References

- [Hermes Agent](https://github.com/NousResearch/hermes-agent)
- [Hermes Agent Docker documentation](https://hermes-agent.nousresearch.com/docs/user-guide/docker/)
- [Hermes dashboard environment variables](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md)
- [Railway Dockerfiles](https://docs.railway.com/builds/dockerfiles)
- [Railway health checks](https://docs.railway.com/deployments/healthchecks)
