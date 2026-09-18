# syntax=docker/dockerfile:1.7
# ============================================================================
# Railway wrapper around the official Hermes Agent image.
#
# The upstream image is pinned to a released version so the pruning rules and
# runtime checks are reproducible. The first stage removes build-only and
# unused runtime content; the second stage copies the remaining rootfs into a
# fresh image so the removed bytes do not remain in parent layers.
# ============================================================================

ARG HERMES_IMAGE=nousresearch/hermes-agent:v2026.9.14

# ---------------------------------------------------------------------------
# Stage 1 — prune the official Hermes image.
# ---------------------------------------------------------------------------
FROM ${HERMES_IMAGE} AS pruned
USER root

# Fail the build if the base regresses to a SQLite version older than the
# release required to avoid the SQLite WAL-reset corruption bug.
RUN python3 -c 'import sqlite3, sys; v=sqlite3.sqlite_version_info; print("SQLite", sqlite3.sqlite_version); sys.exit("ERROR: SQLite WAL-reset fix missing; need >= 3.51.3") if v < (3,51,3) else None'

# Browser automation OFF by default for Railway $5 free tier (Telegram+Dashboard).
# Set to 1 only if you need Playwright/Chromium browser tools.
ARG KEEP_BROWSER=0

COPY --chmod=0755 prune.sh /prune.sh
RUN /prune.sh "${KEEP_BROWSER}" && rm -f /prune.sh

# ---------------------------------------------------------------------------
# Stage 2 — flatten the pruned tree into a fresh image.
# ---------------------------------------------------------------------------
FROM scratch AS runtime
COPY --from=pruned / /

# --- Hermes runtime environment -------------------------------------------
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    npm_config_install_links=false \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_TUI_DIR=/opt/hermes/ui-tui \
    HERMES_HOME=/data/.hermes \
    HERMES_WRITE_SAFE_ROOT=/data \
    HERMES_DASHBOARD_FILES_ROOT=/ \
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    HERMES_LAZY_INSTALL_TARGET=/data/lazy-packages \
    PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# HERMES_WEB_DIST is load-bearing after pruning the web source tree: it makes
# the dashboard serve the prebuilt SPA instead of attempting a boot-time
# frontend build.

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
