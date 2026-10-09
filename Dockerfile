# syntax=docker/dockerfile:1.7
# ============================================================================
# Railway wrapper around the official Hermes Agent image.
#
# The upstream image is pinned to a released version (v0.21.6) by tag AND
# digest so the pruning rules and runtime checks are reproducible. The first
# stage removes build-only and unused runtime content; the second stage copies
# the remaining rootfs into a fresh image so the removed bytes do not remain in
# parent layers.
#
# Pinned: nousresearch/hermes-agent:v0.21.6 (multi-arch index digest below).
# ============================================================================

ARG HERMES_IMAGE=nousresearch/hermes-agent:v0.21.6@sha256:55e192fba0cd4fde61142abbff5adeacff40efdb482ccd0ff877924bd274f909

# ---------------------------------------------------------------------------
# Stage 1 — prune the official Hermes image.
# ---------------------------------------------------------------------------
FROM ${HERMES_IMAGE} AS pruned
USER root

# Fail the build if the base regresses to a SQLite version older than the
# release required to avoid the SQLite WAL-reset corruption bug. Hermes runs on
# its managed Python (/usr/local/bin/python3 -> /opt/hermes/tools/python-*), which
# bundles its own SQLite, so this checks the interpreter Hermes actually uses.
RUN python3 -c 'import sqlite3, sys; v=sqlite3.sqlite_version_info; print("SQLite", sqlite3.sqlite_version); sys.exit("ERROR: SQLite WAL-reset fix missing; need >= 3.51.3") if v < (3,51,3) else None'

# Browser automation OFF by default for Railway free-tier-class hosts.
# Set to 1 only if you need the Chromium-backed browser tools (needs >= 2 GB RAM).
ARG KEEP_BROWSER=0

# In-browser Chat tab: ON. Node + the prebuilt TUI bundle are kept, so the
# dashboard's embedded chat and `hermes --tui` work. Keeping Node also keeps the
# install consistent with the runtime manifest, so startup and the dashboard
# security audit no longer report "install out of sync (node/npm)". Set to 0 to
# drop Node and the TUI (smaller image; the Chat tab then fails closed and the
# out-of-sync warning returns). Browsers (KEEP_BROWSER) have no node dependency
# either way.
ARG KEEP_TUI=1

COPY --chmod=0755 prune.sh /prune.sh
RUN /prune.sh "${KEEP_BROWSER}" "${KEEP_TUI}" && rm -f /prune.sh

# ---------------------------------------------------------------------------
# Stage 2 — flatten the pruned tree into a fresh image.
# ---------------------------------------------------------------------------
FROM scratch AS runtime
COPY --from=pruned / /

# --- Hermes runtime environment -------------------------------------------
# Mirrors the upstream v0.21.6 image environment where it matters, with the
# template's /data layout on top.
#
# HERMES_RUNTIME_DIR (/opt/hermes/tools) is the managed tool store (managed
# Python, ffmpeg, ripgrep, uv and, with KEEP_TUI=1, node/npm; and with
# KEEP_BROWSER=1 the pinned Chromium). Hermes resolves those tools through it,
# so it must stay set even though the tree itself is pruned.
#
# HERMES_WEB_DIST is load-bearing after pruning the web source tree: it makes
# the dashboard serve the prebuilt SPA instead of attempting a boot-time
# frontend build.
#
# With KEEP_TUI=1 (this template's default) the Node runtime and TUI bundle are
# kept. With KEEP_TUI=0 they are pruned and the Chat tab launcher fails CLEANLY (chat_ws catches the SystemExit and returns a 4xx-style
# WS close), which is the documented behavior for opting the tab out.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/tools \
    HERMES_RUNTIME_DIR=/opt/hermes/tools \
    HERMES_PYTHON=/opt/hermes/.venv/bin/python \
    npm_config_install_links=false \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_TUI_DIR=/opt/hermes/ui-tui \
    XDG_RUNTIME_DIR=/tmp/hermes-runtime \
    HERMES_HOME=/data/.hermes \
    HERMES_WRITE_SAFE_ROOT=/data \
    # HERMES_DASHBOARD_FILES_ROOT=/data/.hermes is intentionally unset: setting it locks the dashboard
    # file browser to that folder (no parent navigation). Unset, the browser opens at $HOME, which this
    # template aligns to $HERMES_HOME (/data/.hermes), and you can go up and back freely.
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Railway-specific environment ----------------------------------------
ENV HERMES_DASHBOARD=1 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    PORT=9119

WORKDIR /opt/hermes
EXPOSE 9119

# The persistent data root (HERMES_HOME=/data/.hermes lives inside it). On
# Railway the volume is attached via the UI at /data; this declaration keeps
# `docker run` / compose users on the same contract. Data is ephemeral by
# design when no volume is attached.
# VOLUME ["/data"]

COPY --chmod=0755 railway-entrypoint.sh /railway-entrypoint.sh
ENTRYPOINT [ "/railway-entrypoint.sh" ]
CMD [ "gateway", "run" ]
