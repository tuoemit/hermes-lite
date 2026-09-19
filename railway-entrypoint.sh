#!/bin/sh
# Bridge Railway's dynamic PORT to Hermes' dashboard port, preflight the
# dashboard auth contract, and delegate to Hermes' own entrypoint dispatcher.
set -eu

: "${PORT:=9119}"

case "$PORT" in
    ''|*[!0-9]*)
        echo "ERROR: PORT must be a numeric TCP port (got '$PORT')" >&2
        exit 2
        ;;
esac

if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "ERROR: PORT must be between 1 and 65535 (got '$PORT')" >&2
    exit 2
fi

# Railway's PORT is authoritative. Allowing a separate dashboard port causes
# Railway's health probe and Hermes to disagree about where the service lives.
export HERMES_DASHBOARD_PORT="$PORT"

# --- Dashboard auth preflight ------------------------------------------------
# The dashboard binds 0.0.0.0 on Railway's public port, so upstream's auth
# gate is engaged and REQUIRES a registered provider (HERMES_DASHBOARD_INSECURE
# no longer disables it). Without a provider the dashboard service fails
# closed, nothing answers /api/health, and Railway crash-loops with no
# actionable error in the logs. Fail fast here instead.
basic_ok=0
# Basic Auth counts as configured when BOTH username and a credential are
# present. The credential may be the plaintext HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
# (upstream hashes it in-memory) OR a pre-computed scrypt hash in
# HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH. Prefer the hash: it has no plaintext
# to leak, so a stray `/proc/<pid>/environ` dump cannot expose the login.
if [ -n "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}" ] && \
   { [ -n "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ] || [ -n "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:-}" ]; }; then
    basic_ok=1
fi
oauth_ok=0
if [ -n "${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}" ]; then
    oauth_ok=1
fi
case "${HERMES_DASHBOARD:-1}" in
    0|false|FALSE|no|NO)
        # The template's Railway health check is GET /api/health, which only
        # the dashboard answers on the public PORT. Disabling the dashboard
        # would leave nothing to answer the probe and Railway would
        # restart-loop — fail fast instead of booting into that loop.
        echo "ERROR: HERMES_DASHBOARD is disabled, but this template's health" >&2
        echo "       check (GET /api/health on \$PORT) is served by the dashboard." >&2
        echo "       A disabled dashboard has nothing to answer the probe and" >&2
        echo "       Railway would restart-loop. Keep HERMES_DASHBOARD=1 (default)." >&2
        exit 2
        ;;
    *)
        if [ "$basic_ok" = 0 ] && [ "$oauth_ok" = 0 ]; then
            echo "ERROR: the dashboard is public but no auth provider is configured." >&2
            echo "       Set HERMES_DASHBOARD_BASIC_AUTH_USERNAME and HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" >&2
            echo "       (preferred: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH — a pre-computed scrypt hash," >&2
            echo "       so the plaintext never sits in the container environment)." >&2
            echo "       Recommended: also HERMES_DASHBOARD_BASIC_AUTH_SECRET so sessions survive restarts." >&2
            echo "       Or set HERMES_DASHBOARD_OAUTH_CLIENT_ID for OAuth/OIDC." >&2
            exit 2
        fi
        ;;
esac

# Startup banner for Railway log triage: the values that matter at a glance.
if [ "$basic_ok" = 1 ]; then
    auth_label="basic"
else
    auth_label="oauth"
fi
browser_label="off"
[ -d /opt/hermes/.playwright ] && browser_label="on"
echo "[railway-entrypoint] PORT=$PORT HERMES_DASHBOARD_PORT=$HERMES_DASHBOARD_PORT HERMES_HOME=${HERMES_HOME:-} auth_provider=$auth_label browser=$browser_label"

# Delegate to the upstream dispatcher rather than /init directly. The
# dispatcher preserves Hermes' normal s6-overlay PID-1 path and its wrapped-
# runtime fallback path.
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
