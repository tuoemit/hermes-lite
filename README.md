# hermes-lite

A hardened, digest-pinned [Hermes Agent](https://github.com/NousResearch/hermes-agent) deployment for
Railway — **slim by default**, with every upstream feature one build arg away.

> **Pinned:** `nousresearch/hermes-agent:v0.22.1@sha256:861c9756ed6c558530c73d5c27860343b00c0d5efd6997a1d8ec6416c8a2b485`
> · slim rootfs **~1.2 GB** (upstream base 2.4 GB, −51%) · history in [CHANGELOG.md](CHANGELOG.md)

- Hermes **gateway + web dashboard**, supervised by upstream s6-overlay (auto-restart on crash).
- **Discord + Telegram** adapters, import-verified at build time.
- **LLM Studio** (`/LLM-studio`) — same-origin provider/credential manager with a ✦ shortcut in the
  dashboard's top-right corner.
- **Chat tab / TUI** (Node) kept; browser, media processing, Google and Photon stacks pruned by default —
  see [Build profile](#build-profile).
- Traced pruning with build-time verification: patch drift or missing assets **fail the build**.

## Deploy

1. Create a Railway service from this repo (Dockerfile builder) and generate a public domain.
2. Attach a **Volume mounted at `/data`** before first production use — all state lives there.
3. Set variables (below): at minimum one dashboard auth provider and one model-provider key.
4. Open the public URL, sign in, and finish setup (adapters, model route) from the dashboard.
5. Verify: `GET /api/health` returns `{"ok":true,…}`, then test one real message round-trip per adapter.

`PORT` is injected by Railway — leave it alone; the entrypoint maps it to the dashboard.
Keep the service start-command override unset so the image's `ENTRYPOINT`/s6 chain is used.

## Configuration

### Dashboard auth — pick one; the container fails closed without it

| Variables | Notes |
|---|---|
| `ADMIN_USERNAME` + `ADMIN_PASSWORD` | Basic Auth login form. Store the password as a Railway **secret**. Canonical `HERMES_DASHBOARD_BASIC_AUTH_*` names also work and win if both are set; a pre-computed `_PASSWORD_HASH` is supported. |
| `HERMES_DASHBOARD_OAUTH_CLIENT_ID` | Nous OAuth — recommended for public deployments. |
| `HERMES_DASHBOARD_OIDC_ISSUER` + `HERMES_DASHBOARD_OIDC_CLIENT_ID` | Self-hosted OIDC; **both** required. Optional: `_CLIENT_SECRET`, `_SCOPES` (default `openid profile email`). |

The session secret is generated and persisted to `/data/.hermes/.dash/signing-secret` automatically.

### Channels — Discord + Telegram are built in

| Variable | Notes |
|---|---|
| `DISCORD_BOT_TOKEN` | Discord bot token (secret). |
| `TELEGRAM_BOT_TOKEN` | Bot token from @BotFather (secret). |
| `TELEGRAM_ALLOWED_USERS` | Comma-separated user IDs allowed to talk to the bot. |
| `TELEGRAM_ALLOW_ALL_USERS` | `true` lets anyone in — dev only. |
| `TELEGRAM_HOME_CHANNEL` (+ `_NAME`) | Default chat for cron/notification delivery. |

> Discord **voice playback** is unavailable in the slim profile (the voice-decode lib is pruned);
> text and media channels are unaffected.

### Model provider — set the one you use, or configure from the dashboard

`OPENAI_API_KEY` (+ `OPENAI_BASE_URL` for any compatible endpoint), `ANTHROPIC_API_KEY`,
`OPENROUTER_API_KEY`, `GOOGLE_API_KEY` / `GEMINI_API_KEY`, `XAI_API_KEY`, `MISTRAL_API_KEY`,
`GROQ_API_KEY`, `DEEPSEEK_API_KEY`; `HERMES_INFERENCE_MODEL` / `HERMES_INFERENCE_PROVIDER` override the
default route.

## Build profile

| Build arg | Default | Pruned when `0` |
|---|---|---|
| `KEEP_BROWSER` | `0` | Chromium + GUI/GL/font deps (~515 MB) — browser automation unavailable |
| `KEEP_TUI` | `1` | Node + Chat tab/TUI; Node-dependent plugins may fail |
| `KEEP_MEDIA` | `0` | ffmpeg/ffprobe (~279 MB) — voice notes not transcribed, TTS audio not rendered |
| `KEEP_GOOGLE` | `0` | Google stack (~140 MB) — Google Chat/Gmail/Workspace integrations, Vertex AI routes |
| `KEEP_PHOTON` | `0` | Photon sidecar (~114 MB) |
| `KEEP_CHANNELS` | `"discord telegram"` | All unlisted adapters + their venv deps; `"all"` keeps the upstream set |

Also pruned (not switchable; all verified lazily imported or gracefully degrading on v0.22.1): the
AWS/Bedrock and Azure Foundry provider stacks, the OTel exporter, `youtube_transcript_api`, `resvg_py`,
the `computer_use` and `hermes-achievements` plugins, macOS-only skills, and perl. `hermes doctor`
reports these as "not installed" instead of crashing.

```sh
docker build -t hermes-lite:local .                              # slim (default)
docker build --build-arg KEEP_BROWSER=1 -t hermes-lite:browser . # browser automation back
docker build --build-arg KEEP_CHANNELS=all --build-arg KEEP_MEDIA=1 \
             --build-arg KEEP_GOOGLE=1 -t hermes-lite:full .     # near-upstream feature set
```

Notes: `google_chat` in `KEEP_CHANNELS` together with `KEEP_GOOGLE=0` fails the build with an actionable
error. Photon survives only with `KEEP_PHOTON=1` **and** `photon` listed in `KEEP_CHANNELS`.
Browser-enabled builds want ≥ 2 GB RAM (Railway Free has 0.5 GB). Local builds need Docker
BuildKit/buildx and network access to the pinned image; run `./validate-template.sh` first for fast
static checks.

## LLM Studio

`/LLM-studio` — a same-origin page (✦ shortcut, top-right of the dashboard) for provider setup. Built-in
providers follow Hermes' installed catalog; custom OpenAI-compatible providers take a name, base URL,
API mode and a `key_env` variable name. Primary keys are saved to `$HERMES_HOME/.env`; secondary keys go
to Hermes' credential pool (`auth.json`, masked previews only). No extra port or service is added.

## Ports & health

Health check: `GET /api/health` (300 s timeout, `ON_FAILURE` restart, ≤ 5 retries — see `railway.json`).
It proves the dashboard answers, **not** that an adapter is connected; verify gateway delivery separately
after deploy.

## Storage

Everything persistent lives under `/data` (`HOME=/data`, so `~/.hermes` = `/data/.hermes`): config,
sessions, memories, skills, logs, cron state. Attach a Railway Volume at `/data` via the UI (don't
hand-set `RAILWAY_VOLUME_MOUNT_PATH`); `/opt/data` is symlinked to `/data`, so older warm volumes need
no migration. A volume is not a backup — take one before upgrades. Secrets belong in Railway variables,
never in the repo.

## Security

- Auth fails closed: a public dashboard without a complete auth provider exits at boot, naming the
  missing variables.
- Protected `/api/*` returns 401 without a session; `GET /api/health` and `/api/status` stay public
  (version/health only, no secrets).
- The dashboard file browser is restricted to `/data` and denies `/proc`, `/run` and `.dash` — the
  session secret and Railway-injected environ are not readable from the dashboard UI.
- The build swaps known-vulnerable venv packages to fixed, SHA-256-pinned releases (PyJWT 2.15.1,
  tornado 6.5.10, urllib3 2.8.0, multidict 6.9.1, oauthlib 4.0.0) and gate-checks httpx2/httpcore2
  2.12.0 and anyio 4.14.2; the doctor's security audit reports clean on v0.22.1.
- Base image pinned by tag **and** digest; runtime dependency installs are disabled (sealed container).
- PID 1 starts as root for s6 volume/UID setup, then services drop to the `hermes` user — don't override.
- For public deployments prefer Nous OAuth or OIDC over Basic Auth, and rotate secrets after any incident.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Container restart-loops around the boot banner | Read the `[railway-entrypoint]` log line: the auth preflight exits naming the missing variables. Otherwise check Railway memory/OOM metrics. |
| Dashboard up, bot silent | The gateway s6 slot died: run `hermes gateway start` from a shell and check its logs. |
| `install out of sync (ffmpeg…)` warnings | Expected with `KEEP_MEDIA=0` — server-side audio/video processing is pruned. Same for node/npm with `KEEP_TUI=0`. |
| `no dependency environment is committed` | Fixed by this template's build; if seen, redeploy so the image rebuilds. Do not run `hermes pm repair`. |
| Doctor: "No host gateway owns the gateway role" | Run it as the gateway user: `runuser -u hermes -- env HOME=/data HERMES_HOME=/data/.hermes hermes doctor`. Root runs work too (`HOME=/data` is set for all shells). If it persists, the gateway is really down. |
| SIGTERM / `--- Logging error ---` lines on stop or redeploy | Normal teardown noise, not errors. |

## Updating Hermes

1. `docker buildx imagetools inspect nousresearch/hermes-agent:vX.Y.Z` → set `HERMES_IMAGE=…@sha256:…`
   in `Dockerfile` (version tags only, never date tags).
2. Bump `EXPECTED_HERMES_VERSION` / `EXPECTED_HERMES_PY_VERSION` at the top of `prune.sh`.
3. Re-verify the anchored patches in `prune.sh` (runtime launcher, file-browser guard, `/data` HOME
   layout) — each exits non-zero on upstream drift — plus the tool-store paths and the venv security
   block.
4. Rebuild, run `./validate-template.sh`, and test on a throwaway service before deploying.
5. Record the bump in `CHANGELOG.md`. Roll back via Railway Deployments — an image rollback does not
   undo volume migrations.

## Project files

| File | Purpose |
|---|---|
| `Dockerfile` | Digest-pinned base, build args, two-stage prune/flatten build, runtime env. |
| `prune.sh` | The slim build: pruning, patches, venv security swaps, LLM Studio mount, verification. |
| `LLM_studio.py` / `LLM-studio.html` | The LLM Studio router and page. |
| `railway-entrypoint.sh` | PORT validation, auth preflight, secret generation, s6 dispatch. |
| `railway.json` | Health check + restart policy. |
| `validate-template.sh` | Fast static checks: shell/Railway config/feature defaults/preflight. |
| `CHANGELOG.md` | Pin history and verification records. |

## References

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) ·
  [Docker docs](https://hermes-agent.nousresearch.com/docs/user-guide/docker/) ·
  [Environment variables](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/environment-variables.md)
- [Railway Dockerfiles](https://docs.railway.com/builds/dockerfiles) ·
  [Railway health checks](https://docs.railway.com/deployments/healthchecks)
