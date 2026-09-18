# hermes-lite

**Hermes Agent on Railway** — a thin, production-safe deployment layer around the official
[Hermes Agent](https://github.com/NousResearch/hermes-agent) container, tuned for low-resource
(Railway free-tier-class) hosts.

- Telegram bot (the gateway) + the built-in web dashboard, supervised by Hermes' own s6-overlay.
- WhatsApp, WhatsApp Cloud, and iMessage/Photon are **removed** by design (Telegram-only scope).
- Browser automation is **disabled** by default (does not fit the free-tier RAM budget).
- Traced pruning + build-time verification: a broken prune fails the build, not the runtime.

---

## What it runs

One container, two supervised processes:

| Process | Role |
|---|---|
| **Dashboard** | Web UI on the Railway `PORT`; login via Basic Auth (or OAuth/OIDC). |
| **Gateway** (`gateway-default`, s6 slot) | Telegram bot, cron, all messaging work. Auto-restarted by s6. |

All state lives under `HERMES_HOME=/data/.hermes` (ephemeral by default; see **Storage**).

---

## Deploy

1. **Create a Railway service** from this repository (Dockerfile builder) and generate a public domain.
2. **Set variables** (Railway → Variables) — see below.
3. **Open the public URL**, sign in, and finish Hermes setup (model provider, Telegram token, etc.).

---

## Variables to set in Railway

### Required

| Variable | Notes |
|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | Dashboard login username. |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | Strong dashboard password (Railway **secret**). |

### Strongly recommended

| Variable | Notes |
|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | Stable signing key so dashboard sessions survive restarts. Without it you are logged out on every redeploy. Generate with `openssl rand -hex 32`. |

> **Auth preflight (fail-fast).** The entrypoint exits with an actionable error at boot if the dashboard
> is public but no Basic Auth credentials or `HERMES_DASHBOARD_OAUTH_CLIENT_ID` are set — instead of
> silently crash-looping against the health check.

### Telegram

| Variable | Notes |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather (Railway **secret**). |
| `TELEGRAM_ALLOWED_USERS` | Comma-separated user IDs allowed to talk to the bot. |
| `TELEGRAM_ALLOW_ALL_USERS` | `true` allows anyone (dev only; not recommended). |
| `TELEGRAM_HOME_CHANNEL` | Default chat ID for cron / notification delivery. |
| `TELEGRAM_HOME_CHANNEL_NAME` | Display name for the home channel. |

### Model provider (set the one you use)

| Variable | Notes |
|---|---|
| `OPENAI_API_KEY` / `OPENAI_BASE_URL` | OpenAI, or any OpenAI-compatible endpoint (vLLM, local models…). |
| `ANTHROPIC_API_KEY` | Anthropic. |
| `OPENROUTER_API_KEY` | OpenRouter (vision, web-scrape helpers, MoA). |
| `GOOGLE_API_KEY` / `GEMINI_API_KEY` | Google AI Studio (aliases). |
| `XAI_API_KEY` | xAI (Grok). |
| `MISTRAL_API_KEY` | Mistral. |
| `GROQ_API_KEY` | Groq. |
| `DEEPSEEK_API_KEY` | DeepSeek. |
| `HERMES_INFERENCE_MODEL` | Override the default model (e.g. `gpt-4o`). |
| `HERMES_INFERENCE_PROVIDER` | Override the provider (e.g. `openai`). |

> Telegram and provider keys can also be configured from the dashboard after deploy instead of via env.

### Do not set

`PORT` is injected by Railway and mapped to `HERMES_DASHBOARD_PORT` automatically — do not set it.

---

## Storage: ephemeral by default, volume optional

Free-tier mode runs **without a volume**. Everything under `/data/.hermes` — config, credentials,
sessions, memories, skills, logs, cron state — is recreated on every deploy or container recreate.

In practice:

- **Secrets belong in Railway variables** (they survive redeploys).
- **Dashboard-configured state resets on every deploy** (sessions, memories, skills, cron jobs) —
  the intended free-tier trade-off; the dashboard re-configures quickly.

To opt into persistence, attach a Railway **Volume at `/data`** — nothing else changes. Note that with
a volume attached, config-schema migrations (from `/opt/hermes/scripts/docker_config_migrate.py`) run at
boot as upstream intends.

---

## Browser automation — off by default

`KEEP_BROWSER=0` (default) removes Playwright/Chromium and the GUI/X11 stack. Rationale: on 0.5 GB the
gateway (≈200–400 MB under load) + dashboard (≈100–200 MB) already fill the budget; Chromium headless
adds ≈150–300 MB per page and the free-tier disk quota cannot hold the browser stack. Enable only on a
≥2 GB plan by building with `KEEP_BROWSER=1`.

---

## Ports & health checks

Railway pushes `PORT`; the entrypoint validates it and exports it as `HERMES_DASHBOARD_PORT`. Health check:

```
GET /api/health
```

> This is a dashboard-process liveness endpoint. The messaging gateway is supervised independently by
> s6 and can be down while the container reports healthy — if the dashboard is up but the bot is silent,
> run `hermes gateway start` from a shell (see Troubleshooting).

---

## Security notes

- The dashboard file browser is confined to `/data/.hermes` (`HERMES_DASHBOARD_FILES_ROOT`) — the
  agent's write tools are confined to `/data` (`HERMES_WRITE_SAFE_ROOT`).
- Keep all credentials in Railway **secret** variables. The boot hook seeds `$HERMES_HOME/.env` with
  mode `0600`.
- The image base is pinned by digest (tag + `@sha256:…`) for reproducible builds.

---

## Architecture

```
Railway public HTTP
        │
        ▼
Railway PORT
        │
        ▼
/railway-entrypoint.sh        (PORT validation + auth preflight)
        │
        ▼
Hermes entrypoint-dispatch.sh
        │
        ▼
s6-overlay supervision
   ┌────┴────────────┐
   │                 │
Dashboard          Gateway          (Telegram, cron)
   │                 │
   └──────┬──────────┘
          ▼
     /data/.hermes          (HERMES_HOME; volume at /data optional)
```

The container's CMD is `gateway run`; under s6 the gateway runs as the `gateway-default` service slot and
the main program becomes a `sleep infinity` heartbeat. Gateway crashes are restarted by s6 without
restarting the container.

**Shutdown noise is normal:** on stop/redeploy the gateway logs
`Shutdown context: signal=SIGTERM … s6-supervise gateway-default` (WARNING) and sometimes a
`--- Logging error ---` line — both are expected teardown output, not errors.

---

## Troubleshooting

**Container restart-looping**
Check logs for the `[railway-entrypoint] PORT=… auth_provider=…` banner. Dying before it → image/cold-start
issue. Seeing the auth error → set the Basic Auth variables. Otherwise check memory usage against the
0.5 GB cap — repeated OOM kills are the classic free-tier loop.

**Dashboard up, but the bot is dark**
The `gateway-default` s6 slot can enter permanent-failure. From a shell run `hermes gateway start`
(no `-p` targets the root profile slot).

**Free-tier reality check**
Budget honestly: 0.5 GB RAM is shared by gateway + dashboard + the bot's work. Reduce concurrent load
(fewer platforms/cron jobs/heavy skills) first; move to a paid plan for real headroom. Nothing in the
template can buy RAM back.

**Idle CPU**
The deployed service performs no template-owned background work. Upstream, the gateway runs a 60 s cron
tick + 60 s housekeeping tick (mostly config-gated chores) and 30 s heartbeats; Telegram uses long-poll
(event-driven between polls). To reduce the minute-level memory-trim (`gc.collect`) churn on very tight
budgets, set `context.memory_trim.enabled: false` under `config.yaml` — this is an upstream
default-preserving option, not a template change.

---

## Updating Hermes

1. Change the `HERMES_IMAGE` build-arg (tag + digest) to the new released version;
2. re-verify every prune rule and the anchored patches in `prune.sh` against the new image
   (the script exits non-zero if an anchored upstream line drifted);
3. rebuild and test before deploying.

---

## Project files

| File | Purpose |
|---|---|
| `Dockerfile` | Pins Hermes by digest; two-stage prune/flatten build; Railway runtime env. |
| `prune.sh` | Removes build-only + out-of-scope content, aligns `HOME` with `HERMES_HOME`, verifies the pruned runtime (imports, TUI bundle, dashboard smoke test, `ldd` sweep, clean `/data`). |
| `railway-entrypoint.sh` | Validates `PORT`, preflights dashboard auth (fail-fast), logs a boot banner, delegates to Hermes' dispatcher. |
| `railway.json` | Railway health check (`/api/health`) + restart policy (`ON_FAILURE`, ≤5 retries). |
| `README.md` | This guide. |

---

## References

- [Hermes Agent](https://github.com/NousResearch/hermes-agent)
- [Hermes Agent Docker docs](https://hermes-agent.nousresearch.com/docs/user-guide/docker/)
- [Hermes dashboard environment variables](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md)
- [Railway Dockerfiles](https://docs.railway.com/builds/dockerfiles)
- [Railway health checks](https://docs.railway.com/deployments/healthchecks)
