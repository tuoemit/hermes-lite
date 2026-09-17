#!/bin/sh
# Prune the official Hermes image down to the Railway dashboard + gateway
# runtime, align HOME with this template's HERMES_HOME layout, and verify
# the result. The pruned tree is flattened into a fresh stage by Dockerfile.
#
#   $1 = KEEP_BROWSER (1 = keep Playwright/Chromium, 0 = remove)
#
# The image is pinned to a released Hermes version in Dockerfile. Keep the
# hard-coded pruning rules aligned with that pinned release and update the
# version intentionally when Hermes is upgraded.
set -eu

KEEP_BROWSER="${1:-1}"
case "$KEEP_BROWSER" in
    0|1) ;;
    *)
        echo "ERROR: KEEP_BROWSER must be 0 or 1 (got '$KEEP_BROWSER')" >&2
        exit 2
        ;;
esac

before=$(du -sm / 2>/dev/null | cut -f1)

rm_group() {
    label=$1
    shift
    for p in "$@"; do rm -rf "$p"; done
    echo "  pruned: ${label}"
}

# --- Build caches ----------------------------------------------------------
rm_group "uv wheel cache"        /root/.cache/uv
rm_group "npm/_npx cache"        /root/.npm
rm_group "node compile cache"    /tmp/node-compile-cache

# --- Node build-time trees -------------------------------------------------
# Keep the prebuilt dashboard and in-browser chat/TUI bundles. Node itself
# remains because the dashboard Chat tab can spawn the bundled TUI runtime.
rm_group "root node_modules"     /opt/hermes/node_modules
rm_group "web/ SPA source"       /opt/hermes/web
rm_group "ui-tui TS source" \
    /opt/hermes/ui-tui/src \
    /opt/hermes/ui-tui/packages \
    /opt/hermes/ui-tui/node_modules \
    /opt/hermes/ui-tui/scripts \
    /opt/hermes/ui-tui/tsconfig.json \
    /opt/hermes/ui-tui/tsconfig.build.json \
    /opt/hermes/ui-tui/vitest.config.ts \
    /opt/hermes/ui-tui/eslint.config.mjs

# macOS-only iMessage bridge; cannot run in the Linux Railway image.
rm_group "photon iMessage sidecar" \
    /opt/hermes/plugins/platforms/photon/sidecar/node_modules

# --- Build-time toolchain --------------------------------------------------
# Native extensions are already built into the upstream venv. These packages
# are not needed to run Hermes. Avoid architecture-specific filenames except
# where necessary so the same template works on amd64 and arm64 releases.
rm_group "C/C++ toolchain" \
    /usr/libexec/gcc /usr/lib/gcc /usr/include/c++ \
    /usr/bin/*-linux-gnu-lto-dump-*
rm_group "cmake/ctest/cpack" \
    /usr/bin/cmake /usr/bin/ctest /usr/bin/cpack /usr/share/cmake-3.31

multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
if [ -n "$multiarch" ]; then
    rm_group "static libs" \
        /usr/lib/python3.13/config-3.13-* \
        "/usr/lib/${multiarch}/libc.a"
else
    rm_group "static libs" /usr/lib/python3.13/config-3.13-*
fi

rm_group "docker CLI"            /usr/bin/docker

# --- OS noise --------------------------------------------------------------
rm_group "apt lists"             /var/lib/apt/lists
rm_group "docs/man/info"         /usr/share/doc /usr/share/man /usr/share/info
rm_group "locales"               /usr/share/locale
rm_group "dev/CI leftovers" \
    /opt/hermes/evals /opt/hermes/tests-js /opt/hermes/contributors \
    /opt/hermes/mcp-research-data /opt/hermes/nix /opt/hermes/flake.nix \
    /opt/hermes/flake.lock /opt/hermes/eslint.config.shared.mjs

# --- Browser automation ---------------------------------------------------
# Disabled by default in the optimized $5 tier template (Telegram+Dashboard).
# Set KEEP_BROWSER=1 only if browser automation is required.
if [ "$KEEP_BROWSER" = "1" ]; then
    echo "  KEPT: browser automation (KEEP_BROWSER=1)"
else
    rm_group "playwright chromium+ffmpeg" /opt/hermes/.playwright
    rm_group "fonts"                      /usr/share/fonts

    if [ -n "$multiarch" ]; then
        rm_group "mesa/LLVM GPU stack" \
            "/usr/lib/${multiarch}/libLLVM.so.19.1" \
            "/usr/lib/${multiarch}/libgallium-25.0.7-2+deb13u1.so" \
            "/usr/lib/${multiarch}/libz3.so.4" \
            "/usr/lib/${multiarch}/dri"
    fi
    rm_group "Xvfb/X11 utils" \
        /usr/bin/Xvfb /usr/bin/xkbcomp /usr/bin/xkbprint \
        /usr/bin/xkbevd /usr/share/X11
fi

# PYTHONDONTWRITEBYTECODE=1 prevents new bytecode files at runtime.
# Remove safe, non-runtime cache/junk artifacts from Hermes itself. Keep this
# scoped to known junk names so we do not accidentally delete runtime assets.
find /opt/hermes -xdev \
    \( -type d \
        \( -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache \
           -o -name htmlcov -o -name coverage -o -name .git \) -prune -exec rm -rf {} + \
       -o -type f \
        \( -name '*.pyc' -o -name '*.pyo' -o -name '.coverage' -o -name '.DS_Store' \
           -o -name 'Thumbs.db' -o -name '*.orig' -o -name '*.rej' \) -delete \
    \) 2>/dev/null || true

# Remove Python bytecode caches anywhere else in the runtime tree as well.
find / -xdev -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

# --- HOME alignment for this template's data layout ------------------------
# This template sets HERMES_HOME=/data/.hermes, but upstream v2026.9.14
# hard-codes HOME=/opt/data in the dashboard s6 service and in the main
# program wrapper. Left unpatched, HOME-anchored state (git config, .netrc,
# provider SDK config, XDG state) would land in the non-persistent /opt/data
# skeleton instead of the mounted volume. Re-point both at $HERMES_HOME;
# the upstream stage2 hook guarantees $HERMES_HOME exists (root mkdir -p)
# before any supervised process starts. Fail loudly if the upstream lines
# drift so a version bump is caught at build time.
for f in /etc/s6-overlay/s6-rc.d/dashboard/run /opt/hermes/docker/main-wrapper.sh; do
    grep -q '^export HOME=/opt/data$' "$f" || {
        echo "ERROR: HOME line not found in $f — update this patch for the pinned Hermes release" >&2
        exit 1
    }
    grep -q '^cd /opt/data$' "$f" || {
        echo "ERROR: cwd line not found in $f — update this patch for the pinned Hermes release" >&2
        exit 1
    }
    sed -i 's|^export HOME=/opt/data$|export HOME="$HERMES_HOME"|' "$f"
    sed -i 's|^cd /opt/data$|cd "$HERMES_HOME"|' "$f"
done
echo "  patched: HOME aligned to \$HERMES_HOME (dashboard/run + main-wrapper)"

after=$(du -sm / 2>/dev/null | cut -f1)
echo "prune: ${before}M -> ${after}M (browser=${KEEP_BROWSER})"

# --- Verify the pruned tree still works -----------------------------------
# Use a throwaway HERMES_HOME so the root build user cannot create root-owned
# Hermes state in the image's /data volume mountpoint. Imports catch missing
# Python assets; the HTTP smoke test below verifies the actual dashboard can
# start and answer a health request.
HERMES_HOME=/tmp/prune-verify-home \
HERMES_WRITE_SAFE_ROOT=/tmp/prune-verify-home \
HERMES_DASHBOARD_FILES_ROOT=/ \
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=verify \
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=verify-password \
/opt/hermes/.venv/bin/python3 - <<'PY'
import importlib
import pathlib
import sys

for module in (
    "hermes_cli.main",
    "hermes_cli.web_server",
    "gateway.run",
    "tools.web_tools",
    "agent.agent_init",
    "tui_gateway",
):
    importlib.import_module(module)

must = [
    "/opt/hermes/hermes_cli/web_dist/index.html",
    "/opt/hermes/ui-tui/dist/entry.js",
    "/opt/hermes/ui-tui/package.json",
    "/opt/hermes/docker/entrypoint-dispatch.sh",
    "/opt/hermes/docker/main-wrapper.sh",
    "/etc/s6-overlay/s6-rc.d/dashboard/run",
]
missing = [p for p in must if not pathlib.Path(p).exists()]
if missing:
    sys.exit("prune broke the image, missing: " + ", ".join(missing))
print("prune verify: imports OK, runtime assets present")
PY

HERMES_HOME=/tmp/prune-verify-home \
HERMES_WRITE_SAFE_ROOT=/tmp/prune-verify-home \
HERMES_DASHBOARD_FILES_ROOT=/ \
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=verify \
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=verify-password \
/opt/hermes/.venv/bin/hermes dashboard --host 127.0.0.1 --port 19119 --no-open >/tmp/hermes-dashboard-smoke.log 2>&1 &
dash_pid=$!

cleanup_dashboard() {
    kill "$dash_pid" 2>/dev/null || true
    wait "$dash_pid" 2>/dev/null || true
    rm -f /tmp/hermes-dashboard-smoke.log
}
trap cleanup_dashboard EXIT

HERMES_SMOKE_PID="$dash_pid" /opt/hermes/.venv/bin/python3 - <<'PY'
import os
import time
import urllib.request

url = "http://127.0.0.1:19119/api/health"
for _ in range(40):
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            if response.status == 200:
                print("prune verify: dashboard health OK")
                break
    except Exception:
        time.sleep(0.5)
else:
    pid = os.environ.get("HERMES_SMOKE_PID", "")
    raise SystemExit(f"dashboard smoke test failed; pid={pid}")
PY

cleanup_dashboard
trap - EXIT

rm -rf /tmp/prune-verify-home

# Guard the guard: importing/verifying Hermes must not leave persistent
# state in the image's data-volume mountpoint. This template mounts its
# volume at /data (HERMES_HOME=/data/.hermes lives inside it); upstream
# creates nothing under /data, and the smoke test above ran with a
# throwaway HERMES_HOME under /tmp — so /data must not exist (or be empty)
# in the pruned image.
stray=$(find /data -mindepth 1 -print 2>/dev/null | head -5)
if [ -n "$stray" ]; then
    echo "ERROR: state baked into the /data volume mountpoint:" >&2
    echo "$stray" >&2
    exit 1
fi
echo "prune verify: /data clean"
