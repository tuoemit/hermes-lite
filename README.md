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

The only things you must configure are the **dashboard login** (username + password) and **Telegram**
(plus `PORT`, which Railway injects automatically). The dashboard's **password hash and session secret
are generated automatically** — see below.

### Required

| Variable | Notes |
|---|---|
| `PORT` | Injected automatically by Railway (a system variable — you don't type it). Mapped to the dashboard HTTP port (`HERMES_DASHBOARD_PORT`) and used by the health check. |
| `ADMIN_USERNAME` | Dashboard login username (alias of `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`). |
| `ADMIN_PASSWORD` | Dashboard password, Railway **secret** (alias of `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` — only its hash is used at runtime; see *Credential hygiene*). |

> Use the short `ADMIN_USERNAME` / `ADMIN_PASSWORD` names, or the canonical
> `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` / `_PASSWORD` — both work, and the canonical one wins if both
> are set.

That's all. The template fills in the rest automatically:

- **Password hash** — Hermes hashes your password in-memory at boot, so you never set a
  `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`. (If you prefer, you *may* set the pre-computed hash
  instead of the plaintext — see *Credential hygiene*.)
- **Session secret** — generated + persisted at `$HERMES_HOME/.dash/signing-secret` on first boot, so
  sessions survive restarts without you setting a `HERMES_DASHBOARD_BASIC_AUTH_SECRET`. On the
  volume-backed plan the same secret is reused across redeploys; on the ephemeral free tier it is
  regenerated each deploy (and everyone is logged out once — harmless). You *may* set your own
  `HERMES_DASHBOARD_BASIC_AUTH_SECRET` to keep reins instead.

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

> **Auth preflight (fail-fast).** If the dashboard is public but you set neither the Basic-Auth pair nor
> OAuth, the entrypoint exits at boot with the exact variables to set, instead of silently crash-looping
> against the health check.

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

## In-browser Chat tab — off by default

The dashboard's embedded Chat tab (`/chat`, `/api/pty`) — which also powers `hermes --tui` from a shell —
runs on the Node runtime and the prebuilt TUI bundle. Because this template targets a **Telegram-only**
deployment, Node and the TUI bundle are **removed by default** (`KEEP_TUI=0`). The Chat tab then fails
*closed* with a clear "Chat unavailable" message instead of crashing, and `hermes --tui` goes dark.

If you want the in-browser chat, build with `KEEP_TUI=1` to keep Node (`node`/`npm`/`npx`) and the TUI
bundle. Browser automation (`KEEP_BROWSER`) does **not** require Node, so the two flags are independent.

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

- Dashboard login supports a **pre-hashed password** (`HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`) — see
  *Credential hygiene* below. Prefer it so the plaintext never enters the container environment.
- The dashboard file browser is confined to `/data/.hermes` (`HERMES_DASHBOARD_FILES_ROOT`); the spot
  editor additionally denies `/proc` (sensitive-path guard) — so dashboard-UI access cannot read
  `/proc/<pid>/environ`. The agent's own tools are confined to `/data` (`HERMES_WRITE_SAFE_ROOT`).
- The build upgrades the frozen dependency set's three known-vulnerable HTTP-stack packages to their
  fixed releases (`anyio` 4.12.1→4.14.2, `httpx2` 2.7.0→2.12.0, `httpcore2` 2.7.0→2.12.0) with
  SHA-256-verified wheels, and fails closed if the pinned image ever drifts from the set it targets.
- Keep all credentials in Railway **secret** variables. The boot hook seeds `$HERMES_HOME/.env` with
  mode `0600`.
- The image base is pinned by digest (tag + `@sha256:…`) for reproducible builds.

### Credential hygiene

Railway injects secrets as environment variables, and `/proc/<pid>/environ` exposes them in plaintext to
any process running as the same user — which includes the Hermes agent itself (its shell runs as user
`hermes`, uid 10000, in the same container). Practical rules:

1. **The password hash is handled for you.** Set `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` as a Railway
   secret: Hermes hashes it in-memory at boot, so no pre-computed `_HASH` is needed. If you want the
   *plaintext* out of environ too, pre-compute the hash once and set only
   `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`:
   `python3 -c "import hashlib,base64,secrets;pw=input('pw: ').encode();s=secrets.token_bytes(16);print('scrypt$16384$8$1$%s$%s'%(base64.b64encode(s).decode(),base64.b64encode(hashlib.scrypt(pw,salt=s,n=16384,r=8,p=1,dklen=32,maxmem=0)).decode()))"`
2. **The session secret is handled for you too** — generated and persisted in `$HERMES_HOME/.dash/signing-secret`.
   You only need to manage `HERMES_DASHBOARD_BASIC_AUTH_SECRET` if you want to own it.
3. **After a lease/transcript incident, rotate** the affected values immediately — `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD`/`_HASH`/`_SECRET`, `TELEGRAM_BOT_TOKEN`, and any active model key.

> The `/proc` deny-list covers the dashboard (browser + spot editor), **not** the agent's own shell. The
> documented trust model is that the agent runs *as* the user in the container; treat its filesystem/
> shell access as capable of reading its own environment, and keep secrets out of environ where
> possible (hash for the password; Telegram token and signing secret must remain env/`.env` because the
> gateway process needs them).

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

1. Change `HERMES_IMAGE` (tag + digest) and bump `EXPECTED_HERMES_VERSION` / `EXPECTED_HERMES_PY_VERSION`
   at the top of `prune.sh` to the new released version;
2. re-verify every prune rule and the anchored patches in `prune.sh` against the new image — the script
   now fails up front on the version gate, and each anchored patch (`gateway/run.py`, `files.py`,
   `main-wrapper.sh`, `dashboard/run`) exits non-zero if its upstream line drifted;
3. reconcile the venv security block: if the new release already ships fixed `anyio`/`httpx2`/`httpcore2`,
   the block aborts the build (by design) — remove it or re-target it to the release's actual set;
4. rebuild and test before deploying.

---

## Project files

| File | Purpose |
|---|---|
| `Dockerfile` | Pins Hermes by digest; two-stage prune/flatten build; `KEEP_BROWSER`/`KEEP_TUI` build-args; Railway runtime env. |
| `prune.sh` | Removes build-only + out-of-scope content, aligns `HOME` with `HERMES_HOME`, upgrades the vulnerable venv packages, verifies the pruned runtime (version gate, imports, TUI bundle, dashboard smoke test, `ldd` sweep, clean `/data`). |
| `railway-entrypoint.sh` | Validates `PORT`, routes `ADMIN_USERNAME`/`ADMIN_PASSWORD` aliases, auto-generates the session secret, preflights dashboard auth (fail-fast), creates the `~/.local/bin/hermes` launcher (`hermes doctor` check), logs a boot banner, delegates to Hermes' dispatcher. |
| `railway.json` | Railway health check (`/api/health`) + restart policy (`ON_FAILURE`, ≤5 retries). |
| `README.md` | This guide. |

---

## References

- [Hermes Agent](https://github.com/NousResearch/hermes-agent)
- [Hermes Agent Docker docs](https://hermes-agent.nousresearch.com/docs/user-guide/docker/)
- [Hermes dashboard environment variables](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md)
- [Railway Dockerfiles](https://docs.railway.com/builds/dockerfiles)
- [Railway health checks](https://docs.railway.com/deployments/healthchecks)
