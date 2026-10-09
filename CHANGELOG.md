# Changelog

## Hermes home is the official `~/.hermes`

- *Layout.* The runtime user's `HOME` is `/data` (was `/data/.hermes`), so the official Hermes home
  `~/.hermes` is `/data/.hermes`. `HERMES_HOME` stays set to that same path because upstream's startup scripts
  read it.
- *Every runnable HOME.* `prune.sh` sets `HOME=/data` in each place upstream hard-codes `/opt/data`:
  the dashboard s6 service and `main-wrapper.sh` (plus the inactive copy under `docker/s6-rc.d`); the
  `hermes` privilege-drop shim (`/opt/hermes/bin/hermes`, which every shell `hermes` command runs through); and
  the gateway s6 script that `service_manager.py` renders at runtime (the Telegram gateway). The `HERMES_HOME`
  fallbacks in `service_manager.py`, `container_boot.py`, and `stage2-hook.sh` now default to `/data/.hermes`.
  Each patch fails the build if its upstream anchor drifts, and a final check fails if a runnable `/opt/data`
  reference remains. Comments and docs still mention `/opt/data`; they do not run.
- *`/opt/data` symlink.* now points at `/data` (was `/data/.hermes`). `/opt/data/.hermes` is `/data/.hermes`.
- *Volume root writable.* `railway-entrypoint.sh` chowns the top-level `/data` to the runtime uid/gid,
  non-recursively. HOME-anchored files (`.gitconfig`, `.cache`, `.config`) need it.
- *Doctor launcher and `.local`.* The `hermes doctor` launcher link and the `.local` chown now use
  `/data/.local`, the runtime `HOME`. The boot banner prints `HOME=/data`.
- *File browser.* Opens at `$HOME` (`/data`). `.hermes` is one click in. Browsing stays free; the `/proc`,
  `/run`, and `.dash` guard is unchanged.
- *Moved state.* The XDG state (`.local/state`, including the gateway lock record) moves from
  `/data/.hermes/.local` to `/data/.local`. Existing volumes keep their data; the old `.local` folder is inert.

## v0.21.6 — Hermes Agent pin moved from v0.21.3 to v0.21.6

Pinned image (tag **and** digest):

```
nousresearch/hermes-agent:v0.21.6@sha256:55e192fba0cd4fde61142abbff5adeacff40efdb482ccd0ff877924bd274f909
```

Replaces `nousresearch/hermes-agent:v2026.9.14@sha256:99641e57…`. Versions are now referenced by
release number (`vX.Y.Z`), not by date tag.

### What changed upstream (v0.21.3 → v0.21.6)

Three patch releases (v0.21.4, v0.21.5, v0.21.6) roll up about 4,400 merged PRs. Upstream says the full curated
notes ship with v0.22.0. Highlights that matter for this template:

- **Security fixes** (shipped in v0.21.6, inherited automatically by the pin):
  - Dashboard auth: spoofed `X-Forwarded-For` could reset the password-login rate limit; unbounded writes to the
    auth audit log; no body-size limit on `/auth/`; native sign-in could send login codes to a non-loopback redirect
    (session takeover).
  - Repository git filters: automatic git calls could run `clean`/`smudge`/`process` programs from an untrusted repo.
  - Email gateway: a quoted display name in `From:` could pass the sender allowlist.
- **Managed tool store** at `/opt/hermes/tools`: managed Python 3.14.7, ffmpeg/ffprobe/ffplay, ripgrep, uv, and
  (in the image) node/npm and a pinned Chromium (`chromium-1208`). Previously the browser lived in
  `/opt/hermes/.playwright`. Hermes now resolves its tools through `HERMES_RUNTIME_DIR`.
- **Python 3.14.7** in the venv and managed runtime (the old prune rules assumed 3.13). Bundled SQLite is 3.53.1.
- **Environment**: upstream now sets `HERMES_RUNTIME_DIR`, `HERMES_PYTHON`, `XDG_RUNTIME_DIR`, and
  `PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/tools`. `HERMES_LAZY_INSTALL_TARGET` is no longer read anywhere.
- **Version metadata**: `/etc/hermes/image-provenance.json` and `/opt/hermes/pyproject.toml` report `0.0.0`
  placeholders. The real version is in `/opt/hermes/install-stamp.json` (`displayVersion: 0.21.6`).
- **Venv**: `anyio` is already at the fixed 4.14.2. `httpx2` and `httpcore2` are still at the vulnerable 2.7.0.
- **Dashboard auth** is a username/password login form (`POST /auth/password-login`, provider `basic`) that sets
  signed session cookies. The `HERMES_DASHBOARD_BASIC_AUTH_*` variable names still work. Protected `/api/*` routes
  return 401 without a session.
- **Build provenance note**: the image's install stamp records commit `a28a5d03` (branch `rc.2-v0.21.6`). The
  `v0.21.6` git tag points to `818c13be`, 39 commits later. The image is the one published under the `v0.21.6` tag.

### Changes to the template

**Dockerfile**
- Pin moved to `v0.21.6` (tag + multi-arch index digest).
- `KEEP_TUI` now defaults to `1`: Node and the TUI bundle are kept, so the in-browser Chat tab and `hermes --tui` work and the
  install matches its runtime manifest. Set `KEEP_TUI=0` to drop them for a smaller image.
- Environment aligned with upstream: `PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/tools`, added `HERMES_RUNTIME_DIR`,
  `HERMES_PYTHON`, `XDG_RUNTIME_DIR`. Removed the dead `HERMES_LAZY_INSTALL_TARGET`.
- *Dashboard file browser unlocked.* `HERMES_DASHBOARD_FILES_ROOT=/data/.hermes` is commented out, not deleted. Setting it
  locked the browser to that folder (no parent navigation). Unset, the browser opens at `$HOME` (`/data/.hermes`) and
  can move freely through directories. To lock it again, uncomment the line.

**prune.sh**
- *Version gate* reads `/opt/hermes/install-stamp.json` (`displayVersion` and `baseVersion` must equal `0.21.6`).
  The `0.0.0` placeholders are no longer trusted.
- *Silent-skip bug fixed.* `dpkg-architecture` is not installed in the Hermes base image, so the multiarch lookup
  returned an empty string. That silently skipped every multiarch-path prune: the Mesa/LLVM GPU stack, NSS, and the
  X11 client libraries. In the v0.21.6 base image those removals never ran. The directory is now derived from
  `/usr/lib/*-linux-gnu`, with `dpkg-architecture` as a fallback.
- *Comment-vs-code bug fixed.* The comment said `/usr/libexec/gcc` and `/usr/lib/gcc` were removed. They were not.
  They are now (about 127 MB).
- *Browser* (`KEEP_BROWSER=0`) removes `/opt/hermes/tools/chromium-*` and the
  `/etc/hermes/agent-browser-executable-path` pointer, so boot does not warn about a missing binary. The fail-fast
  check covers the new location.
- *Node / TUI* (`KEEP_TUI=0`, now opt-in) removes `/opt/hermes/tools/node-*` and `npm-*` as well as the
  `/usr/local/bin` symlinks into them.
- *New trims* in the managed tool store: `ffplay` (about 148 MB; Hermes uses only ffmpeg/ffprobe), ffmpeg
  man/doc pages, managed-Python C headers and static `.a` archives, the unused Tk stack (`tkinter`, Tcl/Tk libraries,
  IDLE, turtledemo), and sanitizer runtimes (libasan/libtsan/libhwasan/liblsan/libubsan).
- *Library-integrity sweep* now covers the managed tool store: `rg`, `ffmpeg`, `ffprobe`, `git`, and every `.so` under
  the venv and the managed Python.
- *Venv security gate*: `anyio` is gate-only (must be `>= 4.14.2`). Seven packages are swapped for fixed releases, each
  pinned by SHA-256 and checked after the swap: `httpx2` 2.7.0→2.12.0, `httpcore2` 2.7.0→2.12.0, `PyJWT` 2.13.0→2.15.1,
  `tornado` 6.5.8→6.5.10, `urllib3` 2.7.0→2.8.0, `multidict` 6.7.1→6.9.1, `oauthlib` 3.3.1→4.0.0. Tornado and multidict
  have compiled extensions, so they are pinned per architecture (x86_64 and aarch64). The gate fails the build unless
  each package is at its exact expected vulnerable version before the swap.
- *PyJWT and oauthlib are above upstream's pins.* `pyproject.toml` pins `PyJWT==2.13.0`, so the swapped 2.15.1 disagrees
  with Hermes' own metadata. Nothing at startup or in the security audit reads that pin. Verified with a dependency
  check: no other conflicts.
- *Dashboard/gateway child launches fixed.* Upstream v0.21.6 starts every child process (dashboard Doctor, Security
  audit, Prompt size, Backup, gateway lifecycle) on the managed store Python whenever the store records one, which
  the image always does. A Docker image records no committed dependency environment, so the child was refused with
  "no dependency environment is committed for this install; run `hermes pm repair`". `hermes pm repair` would
  rebuild the whole environment, so it is not the fix. The patch makes those children run on the image venv
  (`/opt/hermes/.venv`, built from the same managed interpreter) when nothing is committed. The anchored patch
  fails the build if the upstream line drifts, and a build-time check runs the dashboard launch path.
- *Dashboard file-browser guard extended.* The sensitive-path guard (which already blocked `/proc`) now also blocks:
  - `/run`: s6-overlay writes every container environment variable (Railway secrets such as `TELEGRAM_BOT_TOKEN`) to
    `/run/s6/container_environment/<NAME>`.
  - any `.dash` folder: the dashboard session-signing secret is stored at `$HERMES_HOME/.dash/signing-secret`. A reader
    could forge dashboard session cookies.
  The guard applies to the file browser (list and read) and the spot editor. `/data/.hermes` and the rest of the tree
  stay browsable.
- *Cleanup*: `PYTHONDONTWRITEBYTECODE=1` for the whole script, and `__pycache__` is removed after the verification
  imports.

**railway-entrypoint.sh**
- Boot banner detects the pinned Chromium in the tool store (`/opt/hermes/tools/chromium-*`).

**README.md / CHANGELOG.md**
- Pin, upgrade procedure (version-tag based), browser and tool-store locations, and login behavior documented.

### Verification

Done in this sandbox (no Docker daemon is available, so the Dockerfile itself was not built):

- Pulled the `v0.21.6` amd64 image layers from Docker Hub and reconstructed the root filesystem (3.2 GB).
- Ran the updated `prune.sh` as the Dockerfile's `RUN` would, on a throwaway copy, inside a rootless chroot
  (`KEEP_BROWSER=0`, `KEEP_TUI=0`). Result: exit 0. Version gate, anchored patches (WhatsApp Cloud adapter,
  `/proc` guard, `HOME` lines), library-integrity sweep, venv swap, module imports, dashboard health smoke test, and
  the `/data` cleanliness check all pass.
  - Root filesystem: **3,183 MB → 1,483 MB** after prune.
- Entrypoint preflight against the pruned tree: bad `PORT` → exit 2; no auth → exit 2 with the remediation message;
  `ADMIN_USERNAME`/`ADMIN_PASSWORD` → session secret generated and persisted, `hermes` launcher created, banner
  printed (`auth_provider=basic browser=off`).
- Dashboard auth on the pruned tree (v0.21.6): login returns 200 and sets session cookies; a wrong password returns
  401; protected `/api/config` returns 401 without a session and 200 with one; a tampered cookie is rejected.
- Second configuration, `KEEP_BROWSER=1 KEEP_TUI=1` (browser and Chat tab kept): exit 0. The TUI bundle probe
  loads. The sandbox cannot mount `/proc`, so this run used a `/proc/self/{stat,statm}` shim that Node reads for
  `process.memoryUsage()`. Real containers always have `/proc`. Root filesystem: 3,184 MB → 2,297 MB.
- Dashboard child launch path, against the pruned trees (both configurations): `--version`, `prompt-size`, and
  `security audit` launch with no refusal. The build-time check runs the same path before the image is sealed.
- Managed Python SQLite 3.53.1 (passes the 3.51.3 gate); `hermes --version` reports `0.21.6` and
  `Install method: docker`.

**Default build with Node kept (`KEEP_TUI=1`, now the default)**
- `prune.sh` run with `KEEP_BROWSER=0 KEEP_TUI=1` (the template default): exit 0. Version gate, all anchored patches,
  venv swap, module imports, TUI bundle probe, and dashboard health all pass. Root filesystem: 3,184 MB → 1,742 MB.
- `hermes --version` on that tree no longer prints `install out of sync`.
- `hermes security audit` on that tree: `No known vulnerabilities found across 145 component(s).` (exit 0). Before
  this change it reported 42 findings in the venv, including PyJWT 2.13.0 (CRITICAL) and tornado, urllib3, multidict,
  and oauthlib.
- Functional smoke test of the swapped libraries (x86_64): PyJWT HS256 sign/verify and wrong-key rejection,
  oauthlib client, urllib3 pool and URL parsing, multidict C extension, tornado HTTP round trip. All pass.

**Still unverified (sandbox limits)**
- The aarch64 wheels for tornado and multidict are SHA-256 pinned to PyPI, but the sandbox is x86_64 only, so they
  were not executed.
- Upstream's own test suite was not run against PyJWT 2.15.1 or oauthlib 4.0.0.

**Not verified here** (needs a real environment): a `docker build`, the Railway deploy, s6 supervision (the
gateway and dashboard as supervised services, which need root), and a live Telegram round trip.
