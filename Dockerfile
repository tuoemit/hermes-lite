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
# Pinned: nousresearch/hermes-agent:v0.22.1 (multi-arch index digest below).
# ============================================================================

ARG HERMES_IMAGE=nousresearch/hermes-agent:v0.22.1@sha256:861c9756ed6c558530c73d5c27860343b00c0d5efd6997a1d8ec6416c8a2b485

# ---------------------------------------------------------------------------
# Stage 1 — prune the official Hermes image.
# ---------------------------------------------------------------------------
FROM ${HERMES_IMAGE} AS pruned
USER root

# Fail the build if the base regresses to a SQLite version older than the
# release required to avoid the SQLite WAL-reset corruption bug. Hermes runs on
# its managed Python (/usr/local/bin/python3 -> /opt/hermes/tools/python-*), which
# bundles its own SQLite, so this checks the interpreter Hermes actually uses.
# (v0.22.1 ships SQLite 3.53.1; the gate needs >= 3.51.3.)
RUN python3 -c 'import sqlite3, sys; v=sqlite3.sqlite_version_info; print("SQLite", sqlite3.sqlite_version); sys.exit("ERROR: SQLite WAL-reset fix missing; need >= 3.51.3") if v < (3,51,3) else None'

# --- Build profile switches -------------------------------------------------
# This template's default profile is slim: no browser, no server-side media
# processing, no Google stack, no Photon sidecar, and only the Discord +
# Telegram messaging channels. Every switch below is a documented feature
# trade, not a silent removal; flip the ARGs (or override at build time with
# --build-arg) to restore upstream behavior.

# Browser automation (Chromium + its GUI/GL/font dependencies, ~515 MB with
# KEEP_BROWSER=0). Full browser workloads should be deployed with adequate
# RAM (start at >= 2 GB) when re-enabled.
ARG KEEP_BROWSER=0

# Node + the prebuilt TUI (dashboard Chat tab). Node may also be required by
# platform/plugin bridges, so KEEP_TUI=0 is a deliberate feature-reduction mode,
# not a generic production optimization.
ARG KEEP_TUI=1

# ffmpeg/ffprobe (~279 MB): voice-note transcription, TTS delivery and media
# transcoding on the channels. KEEP_MEDIA=0 keeps channels fully usable for
# text and file attachments but drops server-side audio/video processing.
ARG KEEP_MEDIA=0

# Google dependency stack (~140 MB: googleapiclient, google-auth, grpcio,
# protobuf, ...). KEEP_GOOGLE=0 disables the Google Chat / Gmail / Workspace
# integrations and the native Vertex/Gemini routes. The build fails fast if
# KEEP_CHANNELS still includes google_chat.
ARG KEEP_GOOGLE=0

# Photon sidecar (~114 MB), the WhatsApp-adjacent hosted channel. It survives
# only when KEEP_PHOTON=1 AND photon is listed in KEEP_CHANNELS.
ARG KEEP_PHOTON=0

# Messaging channels to keep: space-separated plugin ids under
# /opt/hermes/plugins/platforms, or "all" for the complete upstream channel
# set. Unselected adapters, their gateway-side files and their channel-only
# venv dependencies are pruned (the gateway lazy-imports adapters only when a
# platform is actually configured).
ARG KEEP_CHANNELS="discord telegram"

COPY --chmod=0755 prune.sh /prune.sh
# Hermes-lite LLMs Studio is mounted as a small same-origin page/router inside
# Hermes' existing authenticated dashboard; it does not add a service or port.
COPY --chmod=0644 LLM_studio.py /opt/hermes/hermes_cli/web_routers/LLM_studio.py
COPY --chmod=0644 LLM-studio.html /opt/hermes/hermes_cli/web_dist/LLM-studio.html
RUN /prune.sh "${KEEP_BROWSER}" "${KEEP_TUI}" "${KEEP_MEDIA}" "${KEEP_GOOGLE}" "${KEEP_PHOTON}" "${KEEP_CHANNELS}" && rm -f /prune.sh

# ---------------------------------------------------------------------------
# Stage 2 — flatten the pruned tree into a fresh image.
# ---------------------------------------------------------------------------
FROM scratch AS runtime
COPY --from=pruned / /

# --- Hermes runtime environment -------------------------------------------
# Mirrors the upstream v0.22.1 image environment where it matters, with the
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
    # Official Hermes home is ~/.hermes. HOME is /data for every process, including root shells and
    # direct root runs (the gateway's lock/record dir is $HOME/.local/state/hermes, so a root run with
    # HOME=/root cannot see the gateway). ~/.hermes is therefore /data/.hermes. HERMES_HOME is set to
    # that same path explicitly because the upstream startup scripts read it.
    HOME=/data \
    # Upstream runs dashboard actions and tool subprocesses with HOME=$HERMES_HOME/home once that
    # folder exists. Then the dashboard Doctor looked for the gateway record there and reported
    # "No host gateway owns the gateway role". "real" keeps HOME=/data for them too.
    TERMINAL_HOME_MODE=real \
    HERMES_HOME=/data/.hermes \
    HERMES_WRITE_SAFE_ROOT=/data \
    # Restrict dashboard file browsing to runtime state; do not expose /etc, /opt, or other OS paths.
    HERMES_DASHBOARD_FILES_ROOT=/data \
    # The upstream image is sealed/immutable; optional dependencies must be baked into the image.
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Railway-specific environment ----------------------------------------
ENV HERMES_DASHBOARD=1 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    PORT=9119

WORKDIR /opt/hermes
EXPOSE 9119

# The persistent data root: HOME (/data) and the Hermes home ~/.hermes (/data/.hermes) live inside it. On
# Railway the volume is attached via the UI at /data; this declaration keeps
# `docker run` / compose users on the same contract. Data is ephemeral by
# design when no volume is attached.
# VOLUME ["/data"]

COPY --chmod=0755 railway-entrypoint.sh /railway-entrypoint.sh
ENTRYPOINT [ "/railway-entrypoint.sh" ]
CMD [ "gateway", "run" ]
