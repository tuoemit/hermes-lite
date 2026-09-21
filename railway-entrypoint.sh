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
: "${HERMES_HOME:=/data/.hermes}"

# ---- Short credential aliases -----------------------------------------------
# Friendly names for the dashboard login. The canonical (underscored) Hermes
# variables take precedence if both are set; otherwise the short name is routed
# into the canonical one. This keeps upstream's variables intact while letting
# operators use the shorter names in Railway.
if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}" ] && [ -n "${ADMIN_USERNAME:-}" ]; then
    export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$ADMIN_USERNAME"
fi
if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$ADMIN_PASSWORD"
fi

# ---- Dashboard credential contract ------------------------------------------
# The dashboard binds 0.0.0.0 on the public port, so upstream's auth gate
# REQUIRES a provider. This template's contract:
#
#   * YOU set   ADMIN_USERNAME / ADMIN_PASSWORD (short aliases below route into
#               HERMES_DASHBOARD_BASIC_AUTH_USERNAME / _PASSWORD — plaintext is
#               fine). You may also set the canonical names directly, or a
#               pre-computed HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH instead
#               of the plaintext if you prefer not to.
#   * AUTO      the password hash — Hermes hashes the plaintext in-memory at
#               boot, so you never need a _HASH. The session-signing secret is
#               generated + persisted below so sessions survive restarts
#               without you maintaining a HERMES_DASHBOARD_BASIC_AUTH_SECRET.
#
# OAuth is the alternative to the Basic-Auth pair: set
# HERMES_DASHBOARD_OAUTH_CLIENT_ID instead.

# Basic Auth is configured when BOTH username and a credential are present.
basic_ok=0
if [ -n "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}" ] && \
   { [ -n "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ] || [ -n "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:-}" ]; }; then
    basic_ok=1
fi
oauth_ok=0
if [ -n "${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}" ]; then
    oauth_ok=1
fi

# ---- Session-signing secret: auto-generate + persist ------------------------
# When Basic Auth is in use and the operator set no secret, generate one and
# persist it so dashboard sessions stay valid across restarts (and are shared
# by the supervised processes within a boot). Hex-form so the plugin's secret
# decoder (bytes.fromhex -> 32 bytes) accepts it. Persisted at
# $HERMES_HOME/.dash/signing-secret (0600): re-used on volume-backed redeploys,
# regenerated on the ephemeral free tier. Best-effort: if we cannot persist, we
# still export the in-memory value for this boot and warn (otherwise upstream
# would fall back to a random per-process key and log everyone out on every
# restart).
if [ "$basic_ok" = 1 ] && [ -z "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}" ]; then
    secret_file="$HERMES_HOME/.dash/signing-secret"
    secret_val="$(cat "$secret_file" 2>/dev/null || true)"
    if [ -z "$secret_val" ]; then
        secret_val="$(/opt/hermes/.venv/bin/python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || true)"
        if [ -n "$secret_val" ]; then
            if mkdir -p "$HERMES_HOME/.dash" 2>/dev/null \
               && printf '%s\n' "$secret_val" > "$secret_file" 2>/dev/null \
               && chmod 600 "$secret_file" 2>/dev/null; then
                echo "[railway-entrypoint] generated + persisted HERMES_DASHBOARD_BASIC_AUTH_SECRET ($secret_file)"
            else
                echo "[railway-entrypoint] WARNING: could not persist the generated dashboard secret; sessions may not survive restarts" >&2
            fi
        fi
    fi
    if [ -n "$secret_val" ]; then
        # Export for this process tree. This is exactly equivalent to the
        # operator setting a Railway variable: s6-overlay's /init imports the
        # exec-time environment at startup, and every supervised service
        # (dashboard, gateways) rehydrates it via its `with-contenv` shebang —
        # the same path TELEGRAM_BOT_TOKEN and the other runtime variables
        # take. So the auto-generated secret reaches the dashboard process
        # without the operator maintaining it.
        export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$secret_val"
    fi
fi

# --- Dashboard auth preflight ------------------------------------------------
# The dashboard binds 0.0.0.0 on Railway's public port, so upstream's auth
# gate is engaged and REQUIRES a registered provider (HERMES_DASHBOARD_INSECURE
# no longer disables it). Without a provider the dashboard service fails
# closed, nothing answers /api/health, and Railway crash-loops with no
# actionable error in the logs. Fail fast here instead.
case "${HERMES_DASHBOARD:-1}" in
    0|false|FALSE|no|NO)
        echo "ERROR: HERMES_DASHBOARD is disabled, but this template's health" >&2
        echo "       check (GET /api/health on \$PORT) is served by the dashboard." >&2
        echo "       A disabled dashboard has nothing to answer the probe and" >&2
        echo "       Railway would restart-loop. Keep HERMES_DASHBOARD=1 (default)." >&2
        exit 2
        ;;
    *)
        if [ "$basic_ok" = 0 ] && [ "$oauth_ok" = 0 ]; then
            echo "ERROR: the dashboard is public but no auth provider is configured." >&2
            echo "       Set ADMIN_USERNAME and ADMIN_PASSWORD (or the canonical" >&2
            echo "       HERMES_DASHBOARD_BASIC_AUTH_USERNAME / _PASSWORD names)." >&2
            echo "       The password hash and the session secret are generated automatically," >&2
            echo "       so you do NOT need to set them." >&2
            echo "       Or set HERMES_DASHBOARD_OAUTH_CLIENT_ID for OAuth/OIDC." >&2
            exit 2
        fi
        ;;
esac

# ---- Command-launcher for `hermes doctor` (and PATH-less shells) -----------
# `hermes doctor` runs `_check_command_installation`, which expects the
# pip-install layout: the venv entry point PLUS a `$HOME/.local/bin/hermes`
# symlink pointing at it. The Docker image legitimately ships
# /opt/hermes/bin/hermes (the root-drop exec shim) first on PATH instead, so
# in this layout the "Missing ~/.local/bin/hermes symlink" finding is a
# false positive BY DESIGN — the launch surface here is the shim, not the
# `pip install -e` symlink the check models.
#
# Rather than dismissing the finding we make it pass truthfully: create the
# same symlink `hermes doctor --fix` would create (target = the venv entry
# point) at the RUNTIME home. It also survives the ephemeral re-deploy case,
# where a one-off `--fix` would otherwise be wiped on every fresh
# (no-volume) restart and the warning would return. Everything here is
# best-effort: it MUST NOT be able to fail the Pod boot, and it deliberately
# does not chown (stage2-hook may usermod the hermes UID afterwards, so any
# pre-remap chown here would dangle). The symlink is only consulted when the
# shim is not first on PATH; the shim (which re-execs the venv binary by
# absolute path) still takes precedence and keeps its root-drop contract.
: "${HERMES_HOME:=/data/.hermes}"
if [ -x /opt/hermes/.venv/bin/hermes ]; then
    (
        link_dir="$HERMES_HOME/.local/bin"
        target="/opt/hermes/.venv/bin/hermes"
        if [ ! -e "$link_dir/hermes" ]; then
            mkdir -p "$link_dir" 2>/dev/null \
                && ln -s "$target" "$link_dir/hermes" 2>/dev/null \
                && echo "[railway-entrypoint] created $link_dir/hermes -> $target (satisfies 'hermes doctor' command-installation check)"
        fi
    ) || true
fi

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
