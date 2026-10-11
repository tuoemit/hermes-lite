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

# Bound the digit count before shell arithmetic to avoid integer overflow on
# malformed PORT values. A valid decimal TCP port has at most five digits.
if [ "${#PORT}" -gt 5 ]; then
    echo "ERROR: PORT must be between 1 and 65535 (got '$PORT')" >&2
    exit 2
fi
port_normalized="$PORT"
while [ "${port_normalized#0}" != "$port_normalized" ]; do
    port_normalized=${port_normalized#0}
done
[ -n "$port_normalized" ] || port_normalized=0
if [ "$port_normalized" -lt 1 ] || [ "$port_normalized" -gt 65535 ]; then
    echo "ERROR: PORT must be between 1 and 65535 (got '$PORT')" >&2
    exit 2
fi
PORT="$port_normalized"
export PORT

# Railway's PORT is authoritative. Allowing a separate dashboard port causes
# Railway's health probe and Hermes to disagree about where the service lives.
export HERMES_DASHBOARD_PORT="$PORT"
: "${HERMES_HOME:=/data/.hermes}"
# HOME of the runtime user. The official Hermes home is ~/.hermes, so with this
# HOME the Hermes home is /data/.hermes. Services get HOME from prune.sh.
runtime_home=/data

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
oidc_ok=0
if [ -n "${HERMES_DASHBOARD_OIDC_ISSUER:-}" ] && \
   [ -n "${HERMES_DASHBOARD_OIDC_CLIENT_ID:-}" ]; then
    oidc_ok=1
fi

# ---- Session-signing secret: auto-generate + persist ------------------------
# When Basic Auth is in use and no secret was configured, generate a 32-byte
# hex secret. Persist through an atomic temp-file + rename, rather than writing
# directly through a potentially pre-planted symlink in the writable volume.
# If the persistence path is unsafe or unwritable, keep this boot functional but
# warn that browser sessions may not survive a restart.
if [ "$basic_ok" = 1 ] && [ -z "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}" ]; then
    secret_dir="$HERMES_HOME/.dash"
    secret_file="$secret_dir/signing-secret"
    secret_val=""
    secret_dir_safe=1

    # Never follow a symlink used as the .dash directory or secret file.
    if [ -L "$HERMES_HOME" ] || { [ -e "$HERMES_HOME" ] && [ ! -d "$HERMES_HOME" ]; } || \
       [ -L "$secret_dir" ] || { [ -e "$secret_dir" ] && [ ! -d "$secret_dir" ]; }; then
        secret_dir_safe=0
        echo "[railway-entrypoint] WARNING: dashboard secret path is not a regular directory; persistence skipped" >&2
    elif [ ! -L "$secret_file" ] && [ -f "$secret_file" ]; then
        secret_val="$(cat "$secret_file" 2>/dev/null || true)"
        case "$secret_val" in
            *[!0123456789abcdefABCDEF]*|'') secret_val="" ;;
        esac
        [ "${#secret_val}" -eq 64 ] || secret_val=""
        if [ -n "$secret_val" ]; then
            chmod 700 "$secret_dir" 2>/dev/null || true
            chmod 600 "$secret_file" 2>/dev/null || true
        fi
    fi

    if [ -z "$secret_val" ]; then
        secret_val="$(/opt/hermes/.venv/bin/python3 -c 'import secrets; print(secrets.token_hex(32))' 2>/dev/null || true)"
        if [ -n "$secret_val" ]; then
            persisted=0
            if [ "$secret_dir_safe" = 1 ] && mkdir -p "$secret_dir" 2>/dev/null && chmod 700 "$secret_dir" 2>/dev/null; then
                secret_tmp="$(mktemp "$secret_dir/.signing-secret.XXXXXX" 2>/dev/null || true)"
                if [ -n "$secret_tmp" ] &&
                   (umask 077; printf '%s\n' "$secret_val" > "$secret_tmp") 2>/dev/null &&
                   chmod 600 "$secret_tmp" 2>/dev/null &&
                   mv -f "$secret_tmp" "$secret_file" 2>/dev/null; then
                    persisted=1
                else
                    [ -z "${secret_tmp:-}" ] || rm -f "$secret_tmp" 2>/dev/null || true
                fi
            fi
            if [ "$persisted" = 1 ]; then
                echo "[railway-entrypoint] generated + persisted dashboard session secret"
            else
                echo "[railway-entrypoint] WARNING: could not safely persist the generated dashboard secret; sessions may not survive restarts" >&2
            fi
        fi
    fi
    if [ -n "$secret_val" ]; then
        # s6-overlay imports the exec-time environment at startup, and each
        # supervised service rehydrates it via its with-contenv wrapper.
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
        if [ "$basic_ok" = 0 ] && [ "$oauth_ok" = 0 ] && [ "$oidc_ok" = 0 ]; then
            echo "ERROR: the dashboard is public but no auth provider is configured." >&2
            echo "       Set ADMIN_USERNAME and ADMIN_PASSWORD (or the canonical" >&2
            echo "       HERMES_DASHBOARD_BASIC_AUTH_USERNAME / _PASSWORD names)." >&2
            echo "       The password hash and the session secret are generated automatically," >&2
            echo "       so you do NOT need to set them." >&2
            echo "       Or set HERMES_DASHBOARD_OAUTH_CLIENT_ID for Nous OAuth, or" >&2
            echo "       set BOTH HERMES_DASHBOARD_OIDC_ISSUER and" >&2
            echo "       HERMES_DASHBOARD_OIDC_CLIENT_ID for self-hosted OIDC." >&2
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
# best-effort: it MUST NOT be able to fail the Pod boot.
#
# OWNERSHIP WARNING (fixed): `.local` is the XDG base dir under HOME — the
# supervised gateway (as the `hermes` user) writes `$HOME/.local/state` there
# (gateway/status.py). Because this entrypoint runs as root, a root-created
# `.local` stays root-owned unless we hand it back; upstream's stage2-hook
# chowns only its canonical subdir list (cron/sessions/logs/... lazy-packages)
# and never touches `.local`, so a root-owned `.local` makes Telegram startup
# die with `Permission denied: '$HOME/.local/state'`. We therefore chown the
# whole `.local` subtree to the FINAL runtime uid/gid — computed the same way
# stage2-hook will (HERMES_UID/PUID + HERMES_GID/PGID remap, else the baked
# `hermes` user) so a later usermod cannot strand the ownership. Idempotent,
# and it also heals a warm volume that an earlier boot left root-owned.
#
# HOME is /data, so the volume ROOT must be writable by the runtime user too
# (HOME-anchored files such as .gitconfig, .cache, .config). stage2-hook only
# chowns $HERMES_HOME, so we chown the top-level /data directory here,
# non-recursively: its contents stay as they are.
: "${HERMES_HOME:=/data/.hermes}"

# Compute the uid/gid Hermes' supervised services will actually run as.
chown_uid=""
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
    runtime_uid="$(id -u hermes 2>/dev/null || echo 10000)"
    runtime_gid="$(id -g hermes 2>/dev/null || echo 10000)"
    _uid="${HERMES_UID:-${PUID:-}}"
    _gid="${HERMES_GID:-${PGID:-}}"
    case "$_uid" in
        ''|*[!0-9]*) : ;;
        *) if [ "$_uid" -ge 1 ] && [ "$_uid" -le 65534 ]; then runtime_uid="$_uid"; fi ;;
    esac
    case "$_gid" in
        ''|*[!0-9]*) : ;;
        *) if [ "$_gid" -ge 1 ] && [ "$_gid" -le 65534 ]; then runtime_gid="$_gid"; fi ;;
    esac
    chown_uid="$runtime_uid:$runtime_gid"
fi

if [ -n "$chown_uid" ] && [ -d "$runtime_home" ]; then
    chown "$chown_uid" "$runtime_home" 2>/dev/null || true
fi

if [ -x /opt/hermes/.venv/bin/hermes ]; then
    # `hermes doctor` checks ~/.local/bin/hermes, and ~ is $runtime_home (/data).
    link_dir="$runtime_home/.local/bin"
    target="/opt/hermes/.venv/bin/hermes"
    (
        if [ ! -e "$link_dir/hermes" ]; then
            mkdir -p "$link_dir" 2>/dev/null \
                && ln -s "$target" "$link_dir/hermes" 2>/dev/null \
                && echo "[railway-entrypoint] created $link_dir/hermes -> $target (satisfies 'hermes doctor' command-installation check)"
        fi
    ) || true
    # Hand `.local` back to the runtime user (idempotent; heals root-owned
    # leftovers). `chown -R` uses -P semantics during traversal — it does not
    # follow the bin/hermes symlink, so the sealed venv binary is never touched
    # (the symlink's own ownership may flip, which is harmless).
    if [ -n "$chown_uid" ] && [ -d "$runtime_home/.local" ]; then
        chown -R "$chown_uid" "$runtime_home/.local" 2>/dev/null || true
    fi
fi

# Startup banner for Railway log triage: the values that matter at a glance.
auth_label=""
if [ "$basic_ok" = 1 ]; then
    auth_label="basic"
fi
if [ "$oauth_ok" = 1 ]; then
    auth_label="${auth_label:+$auth_label+}nous-oauth"
fi
if [ "$oidc_ok" = 1 ]; then
    auth_label="${auth_label:+$auth_label+}oidc"
fi
[ -n "$auth_label" ] || auth_label="none"
browser_label="off"
# v0.21.x: the pinned Chromium lives in the managed tool store (not /opt/hermes/.playwright).
for _chromium in /opt/hermes/tools/chromium-* /opt/hermes/.playwright; do
    [ -e "$_chromium" ] && browser_label="on"
done
echo "[railway-entrypoint] PORT=$PORT HERMES_DASHBOARD_PORT=$HERMES_DASHBOARD_PORT HOME=$runtime_home HERMES_HOME=${HERMES_HOME:-} auth_provider=$auth_label browser=$browser_label"

# Delegate to the upstream dispatcher rather than /init directly. The
# dispatcher preserves Hermes' normal s6-overlay PID-1 path and its wrapped-
# runtime fallback path.
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
