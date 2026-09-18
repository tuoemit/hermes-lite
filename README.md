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
- Hermes state at `/data/.hermes` — ephemeral by design, optional Railway volume at `/data` for persistence;
- HOME aligned to the template's data layout (static s6 scripts patched at build time + a `/opt/data` → `/data/.hermes` compatibility symlink that also covers s6 scripts generated at runtime);
- browser automation is disabled by default;
- aggressive image pruning (build toolchain, GUI/X11 stack, dev trees) sized for the free tier;
- build-time SQLite compatibility, a shared-library integrity sweep, and a gated dashboard + TUI bundle smoke check;
- a fail-fast dashboard auth preflight in the entrypoint;
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

### 3. Storage (ephemeral by default)
This template is designed to run on the free tier <b>without a volume</b>. All Hermes state — configuration, credentials, sessions, memories, skills, logs, cron state — lives in `HERMES_HOME=/data/.hermes`, which is recreated from scratch on every deploy or container recreate. The boot-time setup hook (`stage2-hook`) runs `mkdir -p` + chown as root before any supervised process starts, so a fresh boot is always self-contained.

What that means in practice:

- bot token, model provider keys, and dashboard credentials should come from **Railway environment variables** (they survive redeploy);
- anything configured inside the dashboard (sessions, memories, skills, cron jobs, profile data) **resets on every deploy** — that is the intended free-tier trade-off, and the dashboard can re-configure everything quickly.

If you ever want persistence, attach a Railway Volume at `/data` — the data root is already inside it, nothing else changes (on the free tier this also raises storage from 0.5 GB to 1 GB).

Note: lazy dependency installs are disabled (`HERMES_DISABLE_LAZY_INSTALLS=1`) and their target is `/data/lazy-packages`. If you re-enable them via Hermes config, that directory must be writable by the `hermes` user.

### 4. Configure Hermes

Open the Railway public URL, sign in, and finish the Hermes setup. Configure your model provider and messaging integrations from the dashboard or through Railway environment variables as appropriate.

## Browser automation

Browser automation is **disabled by default** (`KEEP_BROWSER=0`) because it does not work reliably on Railway's free tier. The math:

- **RAM (0.5 GB cap):** the gateway (typically 200–400 MB under active Telegram load) + the dashboard (100–200 MB) already fill the budget. Chromium's headless shell adds ~150–300 MB per active page session. Once the cgroup OOM-kills, the victim is usually the *gateway* — i.e. your bot goes offline while the container restart-loops.
- **Disk (0.5 GB without a volume):** the browser stack (Chromium headless shell + fonts + GUI libraries) adds roughly 450–600 MB on top of an image that already sits near the free-tier quota.

The "can it technically boot?" answer is yes; "can it browse while the bot is serving?" on 0.5 GB is effectively no. Enabling it by default would put the primary workload (the Telegram bot) at risk, so the default stays `0`.

To enable it, move the service to a plan with at least ~2 GB RAM and build with:

```text
KEEP_BROWSER=1
```

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
3. loads the prebuilt TUI bundle (the dashboard Chat tab's runtime) and verifies it is intact;
4. starts the dashboard bound to `0.0.0.0` — the same non-loopback bind production uses, so the production auth gate (provider required, fail-closed) is exercised — and verifies `/api/health` returns HTTP 200;
5. aligns `HOME` in the upstream dashboard service and main-program wrapper with `HERMES_HOME`, and links `/opt/data` → `/data/.hermes` (failing the build if the upstream lines drift);
6. runs a shared-library integrity sweep (`ldd` over the interpreters, the Node toolchain, and every venv native extension) so an over-aggressive prune fails the build instead of breaking at runtime;
7. confirms that the build-time verification did not leave state in `/data`.

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

### Runtime topology (what actually runs where)

It is worth knowing, because it shapes how the logs look:

- The container's main program is `hermes gateway run`, but under s6 supervision Hermes **redirects it**: the gateway is started as the s6 service slot `gateway-default` (registered at boot by the image's profile reconciliation), and the main program process becomes a tiny `sleep infinity` heartbeat that keeps the container alive.
- The **dashboard** runs as its own s6 service on `PORT`; the **gateway** (Telegram, cron, everything messaging) runs under `s6-supervise gateway-default`.
- s6 auto-restarts a crashed gateway without restarting the container, so gateway flaps do not show up as Railway restarts.
- On container stop (redeploy, `railway stop`, health-check-triggered restart), s6's stage-3 shutdown sends SIGTERM to every service. The gateway then logs `Shutdown context: signal=SIGTERM ... parent_cmdline='s6-supervise gateway-default'` (WARNING level) and sometimes a `--- Logging error ---` line from the Python logging teardown. **Both are normal shutdown noise, not errors** — see Troubleshooting.

## Troubleshooting

**`Shutdown context: signal=SIGTERM ... s6-supervise gateway-default` + `--- Logging error ---`**
Normal, expected output on container stop/restart (see Runtime topology). The gateway's shutdown forensics WARNING plus a Python logging-teardown artifact. Not an error by itself — look at *why* the container stopped (redeploy, health check, or OOM). The same line embeds `loadavg_1m=...`: if that number is large (tens, on a free-tier service), the container was overloaded at the moment of the kill — that is a capacity problem, not a template problem.

**Container restart-looping**
1. Check the Railway logs for the entrypoint banner (`[railway-entrypoint] PORT=... auth_provider=...`) — if the container dies before it, the cause is image/cold-start; if you see `ERROR: the dashboard is public but no auth provider is configured`, set the Basic Auth variables (the entrypoint now fails fast with an actionable message instead of a silent loop).
2. Check Railway's memory usage against the 0.5 GB cap — repeated OOM kills are the classic free-tier loop. The gateway also writes a heavyweight diagnostic (`ps` tree, dmesg) to `$HERMES_HOME/logs/gateway-shutdown-diag.log` on each unexpected signal — on an ephemeral deploy read it *before* the next restart wipes it (dashboard file browser, or `railway logs` timing).

**Dashboard up, but the bot/messaging is dark**
The `gateway-default` s6 slot can end in a *permanent-failure* state (upstream exit-code 125 mapping: s6 stops restarting). The container and dashboard keep running; messaging does not. Check the reconcile log under `/data/.hermes/`, then start it from a shell: `hermes gateway start` (no `-p` targets the root profile slot). This is also the state you can land in after a redeploy with `gateway_state.json` in a transitional value — a fresh start usually self-heals because the boot reconciliation treats legacy `gateway run` containers as "running".

**Free-tier reality check (capacity)**
Budget honestly: 0.5 GB RAM shared by gateway + dashboard + whatever the bot is doing (model calls, cron, image processing). Sustained `loadavg_1m` in the double digits means the service is already thrashing; expect slow health probes, dropped Telegram updates, and OOM kills. Fixes, in order of preference: reduce concurrent work (platforms, cron frequency, heavy skills), then move the service to a paid Railway plan (≥ 2 GB RAM if browser automation is ever wanted). Nothing in the template can buy RAM back.

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

### Audit round 2 (hardening + free-tier optimization)

- **Fixed the real HOME split:** the live gateway is the s6 slot `gateway-default`, whose run script is *generated at runtime* with hard-coded `HOME=/opt/data` — unreachable by any static patch. The template now replaces the `/opt/data` home skeleton with a symlink to `/data/.hermes`, so every current and future `/opt/data` reference (static scripts, generated scripts, HOME fallbacks) lands in the template's data root.
- **Fail-fast dashboard auth preflight** in `railway-entrypoint.sh`: a public dashboard without Basic Auth or OAuth now exits with an actionable error at boot instead of silently crash-looping against the health check.
- **Build validation hardened:** the dashboard smoke test now binds `0.0.0.0` (exercising the production auth gate, fail-closed); a TUI bundle load probe covers the Chat-tab runtime; a shared-library integrity sweep (`ldd` over interpreters, Node, and all venv native extensions) makes aggressive pruning provably safe.
- **Prune deepened:** C frontends/binutils/`make`/the entire `/usr/include` tree and pkgconfig are now removed (compiler backends were already gone, so these were dead weight); the Playwright GUI/X11 client libraries (NSS, ATK, Pango, Cairo, Cups, X11, GBM/DRM, ALSA data, GL/EGL/GLX) are removed with `KEEP_BROWSER=0`; dev-only trees (`apps/`, `scripts/`, installer shims, lint configs) are removed; version-pinned paths converted to globs.
- **Ops:** `VOLUME ["/data"]` declared; entrypoint startup banner; restart policy `ON_FAILURE` → `ALWAYS` (a public service should come back after repeated OOMs instead of going dark after 5 retries); new Runtime-topology, Troubleshooting, and free-tier capacity sections.
- Storage section reframed: the template's primary mode is **ephemeral, no-volume** (data resets per deploy; secrets belong in Railway env vars); a volume at `/data` remains the opt-in persistence path.
- Browser default stays `0`: free-tier RAM/disk math documented (gateway + dashboard + Chromium cannot coexist under 0.5 GB; OOM would take the bot down).

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
| `prune.sh` | Removes build-only content (toolchain, GUI/X11 stack, dev trees), aligns `HOME` with `HERMES_HOME`, and verifies the pruned runtime (imports, TUI bundle, gated dashboard smoke test, shared-library sweep, clean `/data`). |
| `railway-entrypoint.sh` | Validates Railway `PORT`, preflights the dashboard auth contract (fail-fast), logs a startup banner, and delegates to Hermes' dispatcher. |
| `railway.json` | Defines Railway health-check (`/api/health`) and restart behavior (`ALWAYS`). |
| `README.md` | Canonical deployment, configuration, architecture, and maintenance guide. |

## References

- [Hermes Agent](https://github.com/NousResearch/hermes-agent)
- [Hermes Agent Docker documentation](https://hermes-agent.nousresearch.com/docs/user-guide/docker/)
- [Hermes dashboard environment variables](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md)
- [Railway Dockerfiles](https://docs.railway.com/builds/dockerfiles)
- [Railway health checks](https://docs.railway.com/deployments/healthchecks)
