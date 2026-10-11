# hermes-lite

**Hermes Agent on Railway** — a hardened deployment layer around the official
[Hermes Agent](https://github.com/NousResearch/hermes-agent) container. The default build preserves
upstream browser, TUI, and messaging-platform integrations; reduced-feature builds are opt-in.

> **Pinned to Hermes Agent `v0.21.6`** (`nousresearch/hermes-agent:v0.21.6`, multi-arch digest
> `sha256:55e192fba0cd4fde61142abbff5adeacff40efdb482ccd0ff877924bd274f909`). See [CHANGELOG.md](CHANGELOG.md).

- Hermes gateway + web dashboard, supervised by upstream s6-overlay.
- Supported messaging adapters and plugins, including WhatsApp / WhatsApp Cloud / Photon, are retained.
- Browser automation and the dashboard Chat/TUI runtime are retained by default.
- Traced pruning + build-time verification: patch drift or missing retained assets fail the build.

---

## What it runs

One container, two supervised processes:

| Process | Role |
|---|---|
| **Dashboard** | Web UI on the Railway `PORT`; login via Basic Auth (or OAuth/OIDC). |
| **Gateway** (`gateway-default`, s6 slot) | Configured messaging adapters, cron, notification delivery and agent work. Auto-restarted by s6. |

All state lives in the official Hermes home `~/.hermes`, which is `/data/.hermes` here (`HOME=/data`; attach a `/data` volume for production persistence; see **Storage**).

---

## Deploy

1. **Create a Railway service** from this repository (Dockerfile builder) and generate a public domain.
2. **Attach a Railway Volume mounted at `/data`** before configuring production data.
3. **Set variables** (Railway → Variables) — see below.
4. **Open the public URL**, sign in, and finish Hermes setup (model provider and adapter credentials).

---

## Variables to set in Railway

Configure one **dashboard authentication provider** and the credentials for each messaging adapter and
model provider you actually use. `PORT` is injected by Railway; the template maps it to Hermes' dashboard.
For an internet-facing dashboard, prefer Nous OAuth or a self-hosted OIDC provider. Basic Auth is best kept
behind a VPN or another trusted access layer. Hermes fails closed if no supported provider is configured.

### Dashboard auth (choose one)

| Variable | When to use it |
|---|---|
| `ADMIN_USERNAME` + `ADMIN_PASSWORD` | Basic Auth convenience aliases. Store `ADMIN_PASSWORD` as a Railway **secret**. Canonical `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` + `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` also work; canonical values win when both are set. |
| `HERMES_DASHBOARD_OAUTH_CLIENT_ID` | Nous OAuth provider. For a hosted/public deployment, provision a client ID through Hermes' dashboard registration flow. |
| `HERMES_DASHBOARD_OIDC_ISSUER` + `HERMES_DASHBOARD_OIDC_CLIENT_ID` | Self-hosted OIDC provider; **both** are required. `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` is optional for a confidential client. `HERMES_DASHBOARD_OIDC_SCOPES` is optional (default `openid profile email`). |

`PORT` is injected automatically by Railway; do not set it to a hard-coded value in Railway Variables. The
entrypoint maps it to `HERMES_DASHBOARD_PORT`. The dashboard's Basic Auth session secret is generated and
persisted automatically where writable; see the storage and credential-hygiene sections below.

### Required Railway-provided variable

| Variable | Notes |
|---|---|
| `PORT` | Injected automatically by Railway. Mapped to the dashboard HTTP port (`HERMES_DASHBOARD_PORT`) and used by the `/api/health` check. |

For Basic Auth, the template fills in the rest automatically:

- **Password hash** — with Basic Auth, Hermes hashes the configured plaintext password in memory at boot,
  so you do not need `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`. A pre-computed hash can be configured
  instead when using the hash-only credential mode (see *Credential hygiene*).
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

> **Auth preflight (fail-fast).** If the dashboard is public but no complete Basic Auth, Nous OAuth, or
> self-hosted OIDC provider is configured, the entrypoint exits at boot with the variables to set instead
> of silently crash-looping against the health check.

---

## Storage: persistent volume recommended for production

For production, attach a Railway **Volume at `/data`**. Without it, everything under `/data/.hermes`
(the official Hermes home `~/.hermes`, with `HOME=/data`) — config, sessions, memories, skills, logs and
cron state — can be lost when Railway replaces the container.

In practice:

- **Secrets belong in Railway variables** (they survive redeploys), not in the image or repository.
- **A volume is required to preserve agent state** across container recreation; it is not a substitute for backups.
- Before changing the mount path or deploying an image with different state layout, take a backup of the volume.

Attach a Railway **Volume mounted at `/data`** — nothing else changes. Note that with
a volume attached, config-schema migrations (from `/opt/hermes/scripts/docker_config_migrate.py`) run at
boot as upstream intends.

**Home layout.** The runtime user's `HOME` is `/data`, so the official `~/.hermes` is `/data/.hermes`.
`/opt/data` is a symlink to `/data`, so the upstream `/opt/data` paths resolve to the same place. Existing
volumes keep their data with no migration. Two things move because they follow `HOME`: the gateway's XDG
state (`.local/state`) is now `/data/.local/state`, and the `hermes doctor` launcher link is
`/data/.local/bin/hermes`. The old `/data/.hermes/.local` folder on a warm volume is harmless and can be
deleted.

---

## Browser automation — preserved by default

`KEEP_BROWSER=1` (default) retains the pinned Chromium under `/opt/hermes/tools` and its runtime libraries.
Build with `KEEP_BROWSER=0` only if you explicitly do not need browser-based tools. That reduced image is
smaller, but browser automation will not work. Browser workloads increase image size, startup I/O and RAM use;
use a Railway configuration with at least 2 GB RAM as a starting point and size it from observed peak memory.
Railway Free is limited to 0.5 GB RAM (Trial has 1 GB); both have 1 GB ephemeral storage and a 0.5 GB
volume allowance. The project’s prior verification recorded about 2.3 GB of reconstructed rootfs for the browser
+ TUI profile (historical measurement, not re-benchmarked in this pass); rootfs size is not the same thing as
writable-volume capacity. Prefer Hobby or higher for the full-feature production profile. For Free/Trial,
`KEEP_BROWSER=0` is a deliberate feature compromise, not a guarantee that all resource limits will be sufficient.

## LLMs Studio — provider setup in the dashboard

The build adds a same-origin **LLMs Studio** page at `/model-studio` and a **✦ LLMs Studio** shortcut at the
bottom-right of the stock Hermes dashboard. Use the page header's **Dashboard** link to switch back; both
directions go through the `/model-studio/switch` handler, so this adds no port or separate server. Provider
configuration opens in focused overlays, while the main page shows the provider directory and active providers.

LLMs Studio reads Hermes' installed provider/model catalog at runtime, so its built-in provider list follows
the pinned Hermes release. Built-in providers use the environment-variable names Hermes declares. Custom
providers can be created and edited with a display name, model ID, base URL, API mode, and a user-chosen
`key_env` variable name. Model IDs remain free-form; catalog suggestions do not limit entry.

For either a built-in or custom provider, the primary key is saved through Hermes' credential lifecycle to
`$HERMES_HOME/.env`. Add as many secondary keys as needed: Hermes' credential-pool API stores those in
`auth.json` and returns only masked previews to the page. Existing pool entries can be removed; provider
settings and primary keys can be edited without displaying saved secret values. The page uses Hermes'
existing authenticated APIs and file-protection routines rather than a second configuration store.

The custom endpoint editor manages named OpenAI-compatible provider entries. It does not make incompatible
wire protocols interchangeable: select the endpoint's API mode when auto-detection is not appropriate.
OAuth-only providers still need Hermes' normal OAuth sign-in flow.

## In-browser Chat tab — on by default

The dashboard's embedded Chat tab (`/chat`, `/api/pty`) and `hermes --tui` use Node plus the prebuilt TUI
bundle. The default (`KEEP_TUI=1`) retains them. Because Node is also used by some integrations/plugins,
`KEEP_TUI=0` is a deliberate feature-reduction option: the Chat tab and TUI stop working, and Node-dependent
integrations may fail. Browser automation (`KEEP_BROWSER`) uses a separate build option.

---

## Ports & health checks

Railway pushes `PORT`; the entrypoint validates it and exports it as `HERMES_DASHBOARD_PORT`. Health check:

```
GET /api/health
```

> This is a dashboard-process liveness endpoint, not an end-to-end provider or gateway probe. The gateway is
> supervised independently by s6 and can be down while the container reports healthy. Railway uses this health
> check during deployment activation; it does not continuously poll it as an uptime monitor. If a bot is silent,
> inspect the gateway service/logs (see Troubleshooting).

---

## Security notes

- Dashboard login is a username/password **login form** (provider `basic`, `POST /auth/password-login`) that sets
  signed session cookies; the `HERMES_DASHBOARD_BASIC_AUTH_*` variable names are unchanged. Protected `/api/*`
  routes return 401 without a session. Upstream keeps `GET /api/health` and `GET /api/status` public: they
  expose version and component health, not secrets. (Verified against v0.21.6.)
- Dashboard login supports a **pre-hashed password** (`HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH`) — see
  *Credential hygiene* below. Prefer it so the plaintext never enters the container environment.
- The dashboard file browser is restricted to `/data` (`HERMES_DASHBOARD_FILES_ROOT=/data`), which contains agent state
  but not the container's `/etc` and `/opt` trees. The file browser and spot editor also deny `/proc`, `/run`, and any
  `.dash` folder (sensitive-path guard). Dashboard-UI access therefore cannot read `/proc/<pid>/environ`, Railway secrets
  under `/run/s6/container_environment`, or the dashboard session-signing secret in `/data/.hermes/.dash/`. The agent's
  own tools are configured to write within `/data` (`HERMES_WRITE_SAFE_ROOT`); this is not a sandbox from the agent's own
  process environment or other files its UID can read.
- The build upgrades the frozen dependency set's vulnerable packages to fixed releases, each pinned by
  SHA-256 and checked after the swap: `httpx2` 2.7.0→2.12.0, `httpcore2` 2.7.0→2.12.0, `PyJWT` 2.13.0→2.15.1,
  `tornado` 6.5.8→6.5.10, `urllib3` 2.7.0→2.8.0, `multidict` 6.7.1→6.9.1, `oauthlib` 3.3.1→4.0.0. Tornado and
  multidict have compiled extensions, so they are pinned per architecture (x86_64, aarch64). `anyio` is already
  at the fixed 4.14.2 upstream in v0.21.6, so it is only gate-checked. The build fails closed if the pinned
  image drifts from the set it targets.
- The swapped `PyJWT` (2.15.1) and `oauthlib` (4.0.0) are newer than upstream's pins (`PyJWT==2.13.0` in
  `pyproject.toml`). Upstream's package metadata therefore still declares 2.13.0 for PyJWT. This does not affect
  startup or the security audit, which report clean.
- Keep all credentials in Railway **secret** variables. The upstream boot hook seeds `$HERMES_HOME/.env` with
  mode `0600`. The image follows upstream's sealed-container model (`HERMES_DISABLE_LAZY_INSTALLS=1`): dependency
  installs are not performed on demand into the immutable `/opt/hermes` tree. Optional integrations/tools whose Python
  packages are not part of the pinned upstream image's production extras must be added and tested at build time.
- The image base is pinned by digest (tag + `@sha256:…`) for reproducible builds.
- The container's PID 1 starts as root because upstream s6 initialization performs volume ownership/UID setup;
  the gateway/dashboard services drop to the configured `hermes` runtime identity. Do not add `USER hermes`
  without redesigning and testing the upstream initialization contract.

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
     /data                  (HOME, the volume root)
     /data/.hermes          (~/.hermes = HERMES_HOME)
```

The container's CMD is `gateway run`; under s6 the gateway runs as the `gateway-default` service slot and
the main program becomes a `sleep infinity` heartbeat. Gateway crashes are restarted by s6 without
restarting the container.

**Shutdown noise is normal:** on stop/redeploy the gateway logs
`Shutdown context: signal=SIGTERM … s6-supervise gateway-default` (WARNING) and sometimes a
`--- Logging error ---` line — both are expected teardown output, not errors.

---


---

## Production deployment checklist

### Environment-variable checklist

- [ ] **Dashboard authentication:** configure one supported provider. For public-internet access, prefer
      `HERMES_DASHBOARD_OAUTH_CLIENT_ID` (Nous OAuth) or both `HERMES_DASHBOARD_OIDC_ISSUER` and
      `HERMES_DASHBOARD_OIDC_CLIENT_ID` (self-hosted OIDC). Use `ADMIN_USERNAME` + `ADMIN_PASSWORD` for
      Basic Auth only behind a trusted access layer; store the password as a Railway secret.
- [ ] **Model provider:** configure credentials for the provider selected in Hermes (for example
      `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GOOGLE_API_KEY`, or provider-specific
      cloud credentials), or finish setup through the authenticated dashboard.
- [ ] **Messaging adapter:** configure its credentials and access controls (for Telegram, normally
      `TELEGRAM_BOT_TOKEN` and optionally `TELEGRAM_ALLOWED_USERS`). Set only adapters you intend to run.
- [ ] **Persistence:** attach a Railway Volume at `/data`. Do not try to set `RAILWAY_VOLUME_MOUNT_PATH`
      yourself; Railway supplies it when the volume is attached.
- [ ] **Port:** leave Railway's injected `PORT` variable alone. The entrypoint maps it to Hermes.
- [ ] **No secrets in source:** check that API keys, bot tokens, passwords, and exported `.env` files are
      absent from the repository and Docker build context before deployment.

1. **Pin the source revision.** Deploy from a reviewed Git commit; the base Hermes image is already pinned by release tag and digest.
2. **Attach a Railway Volume at `/data` before first production use.** Do not change this mount casually; both `HOME` and `HERMES_HOME` are rooted there.
3. **Set dashboard credentials as Railway secrets.** Use `ADMIN_USERNAME` and `ADMIN_PASSWORD`, or the canonical `HERMES_DASHBOARD_BASIC_AUTH_*` variables. Do not enable insecure/public unauthenticated access.
4. **Configure your adapter and model-provider credentials.** Examples include `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, provider API keys and any adapter-specific variables you actually need. Do not commit `.env` files.
5. **Start with suitable resources.** With browser automation enabled, allocate at least 2 GB RAM as an initial target and watch peak memory, restarts, latency and volume usage. A full-feature build is not a good fit for a 0.5 GB memory budget.
6. **Keep the health check** at `GET /api/health` on Railway's injected `PORT`. Verify gateway delivery separately after deploy; a dashboard 200 is not proof that Telegram or another adapter is connected.
7. **Back up before upgrades.** A deploy rollback restores the old image but does not automatically roll back data/schema migrations in the volume.

### Build profiles

The default build is feature-preserving:

```sh
docker build -t hermes-lite:local .
```

Optional reduced-feature profile (removes Chromium/browser automation):

```sh
docker build --build-arg KEEP_BROWSER=0 -t hermes-lite:no-browser .
```

Optional reduced-feature profile (removes Node/TUI; may break Node-dependent integrations):

```sh
docker build --build-arg KEEP_TUI=0 -t hermes-lite:no-tui .
```

These flags reduce components intentionally; do not use them if the corresponding feature is required. Local builds require Docker BuildKit/buildx and network access to the pinned base image and hash-verified dependency wheels. Run `./validate-template.sh` for fast shell/config/preflight checks before building.

### Deploy, verify, and roll back

- **Deploy:** push the reviewed commit to the Git branch connected to Railway and let Railway build the Dockerfile. Keep the service start-command override unset so the Docker `ENTRYPOINT`/`CMD` and s6 dispatcher are used.
- **Verify:** inspect build logs for all `prune verify` checks; wait for Railway's `/api/health` check; log into the dashboard; run Hermes Doctor/security audit; test one real model request and one message round-trip on every configured adapter; confirm the `/data` volume remains mounted.
- **Rollback:** use Railway's Deployments view to redeploy the last known-good deployment/image. Do not detach, wipe, or remount the `/data` volume as part of image rollback. If the failed release ran a config/schema migration, restore a compatible volume backup only after determining whether the migration was backward-compatible.
- **Validate before production:** test the same image and a copy of representative state in a staging service. A successful Docker build alone does not validate provider credentials, Railway volume behavior, Telegram polling or third-party integrations.

## Troubleshooting

**Container restart-looping**
Check logs for the `[railway-entrypoint] PORT=… auth_provider=…` banner. Dying before it suggests an
image/cold-start issue. Seeing the auth error means dashboard credentials/provider configuration is missing.
Otherwise inspect Railway memory metrics and OOM events; full browser-enabled workloads need more headroom
than a 0.5 GB instance provides.

**Dashboard up, but the bot is dark**
The `gateway-default` s6 slot can enter permanent-failure. From a shell run `hermes gateway start`
(no `-p` targets the root profile slot).

**Dashboard Doctor / Security audit / Prompt size shows `no dependency environment is committed`**
This was an upstream v0.21.6 bug for Docker images (dashboard and gateway actions launched on the
store Python). This template fixes it at build time. If you still see it, redeploy this template so the
image is rebuilt. Do not run `hermes pm repair`: it rebuilds the whole dependency environment.

**`install out of sync (node: …; npm: …)` warning**
Not expected on the default build, which keeps Node and npm (`KEEP_TUI=1`). If you built with `KEEP_TUI=0`, the
warning is expected: Node and npm were removed. Rebuild with `KEEP_TUI=1` to clear it.

**`doctor` says "No host gateway owns the gateway role"**
The gateway's host record is owned by the `hermes` user, and Hermes refuses to read a record owned by
another user. So when the venv binary is run directly as `root` (for example
`/opt/hermes/.venv/bin/hermes doctor`), the gateway is invisible and the doctor reports a false warning.
The image sets `HOME=/data` for every process, including root shells, so direct root runs now look in the
same lock dir as the gateway. If you still see the warning, check that the gateway is up
(`/command/s6-svstat /run/service/gateway-default` should say `up`, and
`/data/.local/state/hermes/gateway-locks/host-gateway.json` should exist), then run the doctor as the
gateway's user:

```sh
runuser -u hermes -- env HOME=/data HERMES_HOME=/data/.hermes hermes doctor
```

The dashboard's Doctor button uses `TERMINAL_HOME_MODE=real` (set in the image), so it keeps `HOME=/data`
and finds the gateway record. Upstream's default would move it into `/data/.hermes/home`, which is what
caused the warning in the dashboard. If the `hermes`-user doctor run also reports no gateway, the gateway is really down. See
"Dashboard up, but the bot is dark" above.

**Free-tier reality check**
Free/Trial resource limits are tight for this container: Free has 0.5 GB RAM, Trial has 1 GB RAM, and both have 1 GB ephemeral storage plus a 0.5 GB volume allowance. Prefer Hobby or higher with at least 2 GB RAM and sufficient volume capacity as an initial production target. If you must experiment on Free/Trial, reduce concurrent work, monitor the actual metrics, and use `KEEP_BROWSER=0` only if you accept losing browser automation; that switch does not guarantee the whole deployment fits every plan limit.

**Idle CPU**
The deployed service performs no template-owned background work. Upstream, the gateway runs a 60 s cron
tick + 60 s housekeeping tick (mostly config-gated chores) and 30 s heartbeats; Telegram uses long-poll
(event-driven between polls). To reduce the minute-level memory-trim (`gc.collect`) churn on very tight
budgets, set `context.memory_trim.enabled: false` under `config.yaml` — this is an upstream
default-preserving option, not a template change.

---

## Updating Hermes

Use **version tags** (e.g. `v0.21.6`), never date tags. Each release is pinned by tag **and** digest.

1. Get the digest of the new release's multi-arch index:
   `docker buildx imagetools inspect nousresearch/hermes-agent:vX.Y.Z` (the top `Digest:` line), and set
   `HERMES_IMAGE=nousresearch/hermes-agent:vX.Y.Z@sha256:…` in the `Dockerfile`.
2. Bump `EXPECTED_HERMES_VERSION` (`vX.Y.Z`) and `EXPECTED_HERMES_PY_VERSION` (`X.Y.Z`) at the top of
   `prune.sh`. The version gate reads `/opt/hermes/install-stamp.json` (`displayVersion`/`baseVersion`); the
   `pyproject.toml` and `image-provenance.json` values are `0.0.0` placeholders in v0.21.x images.
3. Re-verify the anchored patches in `prune.sh` against the new image. Each one exits non-zero if its upstream
   line drifted: the runtime-command launcher in `hermes_cli/terminal/_launchers.py`, the sensitive-path guard
   in `hermes_cli/web_routers/files.py`, and the `HOME=/opt/data` / `cd /opt/data` defaults in the dashboard,
   launcher, and stage-2 scripts (patched to the `/data` layout). Platform adapters are retained; they are no
   longer edited out of `gateway/run.py`.
4. Check the managed tool-store paths (`/opt/hermes/tools/chromium-*`, `node-*`, `npm-*`, `ffmpeg-*`,
   `python-*`, `ripgrep-*`) and `/etc/hermes/agent-browser-executable-path` still match the prune rules.
5. Reconcile the venv security block: if the new release already ships fixed `httpx2`/`httpcore2`, the block
   aborts the build by design. Remove the swap or re-target it. The `anyio` gate requires `>= 4.14.2`.
6. Rebuild and test before deploying (`docker build`, then a deploy to a throwaway Railway service).

---

## Project files

| File | Purpose |
|---|---|
| `Dockerfile` | Pins Hermes by digest; two-stage prune/flatten build; preserves browser/TUI by default; installs the same-origin LLMs Studio page and router; Railway runtime env. |
| `prune.sh` | Removes build-only content, preserves supported platform adapters, aligns `HOME` to `/data`, upgrades selected pinned dependencies, mounts LLMs Studio and its dashboard switch link, and verifies runtime assets, optional browser/TUI, dashboard startup and shared-library integrity. |
| `hermes_lite_model_studio.py` | Serves `/model-studio`, implements the UI-switch handler, returns a secret-free settings snapshot, and saves named providers with an editable `key_env`. |
| `model-studio.html` | Self-contained LLMs Studio interface with a provider directory, active-provider list, and overlay-based setup. Uses Hermes APIs for provider discovery, `.env` credentials and unlimited secondary `auth.json` credential-pool keys. |
| `railway-entrypoint.sh` | Validates `PORT`, routes `ADMIN_USERNAME`/`ADMIN_PASSWORD` aliases, auto-generates the session secret, preflights dashboard auth (fail-fast), creates the `~/.local/bin/hermes` launcher (`hermes doctor` check), logs a boot banner, delegates to Hermes' dispatcher. |
| `railway.json` | Railway health check (`/api/health`) + restart policy (`ON_FAILURE`, ≤5 retries). |
| `CHANGELOG.md` | What changed in each pin bump (v0.21.3 → v0.21.6), and how it was verified. |
| `validate-template.sh` | Fast shell, Railway JSON, feature-default, `PORT`, and auth-preflight regression checks without Docker. |
| `README.md` | Deployment guide, environment checklist, troubleshooting, and update procedure. |

---

## References

- [Hermes Agent](https://github.com/NousResearch/hermes-agent)
- [Hermes Agent Docker docs](https://hermes-agent.nousresearch.com/docs/user-guide/docker/)
- [Hermes dashboard environment variables](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md)
- [Railway Dockerfiles](https://docs.railway.com/builds/dockerfiles)
- [Railway health checks](https://docs.railway.com/deployments/healthchecks)
