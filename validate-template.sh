#!/bin/sh
# Fast local checks that do not require Docker or Railway credentials.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

sh -n railway-entrypoint.sh
sh -n prune.sh
python3 - <<'PY'
from pathlib import Path
source = Path('hermes_lite_model_studio.py').read_text(encoding='utf-8')
compile(source, 'hermes_lite_model_studio.py', 'exec')
page = Path('model-studio.html').read_text(encoding='utf-8')
assert '__HERMES_SESSION_TOKEN__' in page
assert '/api/credentials/pool' in page
assert '<title>Hermes · LLMs Studio</title>' in page
assert '<span>Dashboard</span>' in page and 'M19 12H5' in page
assert 'aria-expanded="false"' in page and 'Providers List' in page
assert 'Add Custom Provider' in page and 'Active providers' in page
assert 'id="builtinOverlay"' in page and 'id="customOverlay"' in page
assert "content.inert=!open" in page
assert "if(isCustom)$('#builtinModalBody').innerHTML=''" in page
assert 'class="studio-fab"' not in page
prune = Path('prune.sh').read_text(encoding='utf-8')
marker = "# --- Hermes-lite LLMs Studio: same-origin page + dashboard switch"
block = prune[prune.index(marker):]
start = block.index("/opt/hermes/.venv/bin/python3 - <<'PY'")
start = block.index('\n', start) + 1
end = block.index('\nPY', start)
compile(block[start:end], 'prune-studio-injection.py', 'exec')
PY
jq -e '
  .build.builder == "DOCKERFILE" and
  .build.dockerfilePath == "Dockerfile" and
  .deploy.healthcheckPath == "/api/health" and
  .deploy.healthcheckTimeout == 300 and
  .deploy.restartPolicyType == "ON_FAILURE" and
  .deploy.restartPolicyMaxRetries == 5
' railway.json >/dev/null

grep -q '^ARG KEEP_BROWSER=1$' Dockerfile
grep -q '^ARG KEEP_TUI=1$' Dockerfile
grep -q 'HERMES_DASHBOARD_FILES_ROOT=/data' Dockerfile
grep -q 'hermes_lite_model_studio.py' Dockerfile
grep -q 'model-studio.html' Dockerfile
grep -q 'app.include_router(_hermes_lite_model_studio_routes.router)' prune.sh
grep -q 'model-studio/switch?dashboard=studio' prune.sh
grep -q '✦ LLMs Studio' prune.sh
grep -q 'bottom:18px' prune.sh
grep -q '@router.get("/model-studio/switch"' hermes_lite_model_studio.py
grep -q '/api/credentials/pool' model-studio.html
grep -q 'exec /opt/hermes/docker/entrypoint-dispatch.sh' railway-entrypoint.sh
grep -q 'HERMES_DASHBOARD_OIDC_ISSUER' railway-entrypoint.sh
grep -q 'HERMES_DASHBOARD_OIDC_CLIENT_ID' railway-entrypoint.sh
grep -q "! -name 'whatsapp-bridge'" prune.sh
if grep -Eq 'rm_group .*(/plugins/platforms/(whatsapp|photon)|/gateway/platforms/whatsapp)' prune.sh; then
    echo 'ERROR: prune.sh appears to remove a supported platform integration' >&2
    exit 1
fi

# Invalid values must fail at the entrypoint preflight with an actionable PORT error.
for port in abc 0 65536 999999999999999999999999 000000; do
    set +e
    output=$(env -i PATH="$PATH" PORT="$port" sh ./railway-entrypoint.sh 2>&1)
    status=$?
    set -e
    if [ "$status" -ne 2 ] || ! printf '%s' "$output" | grep -q 'PORT must'; then
        echo "ERROR: invalid PORT test failed for '${port:-<empty>}' (status=$status)" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
done

# Valid ports pass PORT validation and then fail only at the expected missing-auth preflight.
for port in '' 80 080 9119 65535; do
    set +e
    output=$(env -i PATH="$PATH" PORT="$port" sh ./railway-entrypoint.sh 2>&1)
    status=$?
    set -e
    if [ "$status" -ne 2 ] || ! printf '%s' "$output" | grep -q 'dashboard is public but no auth provider is configured'; then
        echo "ERROR: valid PORT test did not reach auth preflight for '$port' (status=$status)" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
done

# Extract just the credential alias/provider preflight block for OIDC regression
# tests. This avoids running the rest of the container entrypoint on the host,
# where its runtime preparation could touch /data or system ownership.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
awk '/^# ---- Short credential aliases/{capture=1} /^# ---- Command-launcher for /{capture=0} capture{print}' \
  railway-entrypoint.sh > "$tmpdir/auth-preflight.sh"
if [ ! -s "$tmpdir/auth-preflight.sh" ]; then
    echo 'ERROR: could not extract auth preflight for regression tests' >&2
    exit 1
fi

# An incomplete self-hosted OIDC pair must fail closed.
set +e
output=$(env -i PATH="$PATH" HERMES_HOME="$tmpdir/hermes" \
  HERMES_DASHBOARD_OIDC_ISSUER=https://idp.example.test \
  sh "$tmpdir/auth-preflight.sh" 2>&1)
status=$?
set -e
if [ "$status" -ne 2 ] || ! printf '%s' "$output" | grep -q 'no auth provider is configured'; then
    echo 'ERROR: incomplete OIDC settings did not fail closed' >&2
    printf '%s\n' "$output" >&2
    exit 1
fi

# A complete self-hosted OIDC pair must pass the auth preflight.
set +e
output=$(env -i PATH="$PATH" HERMES_HOME="$tmpdir/hermes" \
  HERMES_DASHBOARD_OIDC_ISSUER=https://idp.example.test \
  HERMES_DASHBOARD_OIDC_CLIENT_ID=hermes-lite-test \
  sh "$tmpdir/auth-preflight.sh" 2>&1)
status=$?
set -e
if [ "$status" -ne 0 ]; then
    echo 'ERROR: complete OIDC settings failed the auth preflight' >&2
    printf '%s\n' "$output" >&2
    exit 1
fi

echo 'validate-template: shell syntax, Railway config, feature defaults, PORT/OIDC preflight and LLMs Studio wiring OK'
echo 'validate-template: Docker image build and live Railway behavior still require integration testing'
