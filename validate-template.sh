#!/bin/sh
# Fast local checks that do not require Docker or Railway credentials.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

sh -n railway-entrypoint.sh
sh -n prune.sh
python3 - <<'PY'
from pathlib import Path
source = Path('LLM_studio.py').read_text(encoding='utf-8')
compile(source, 'LLM_studio.py', 'exec')
page = Path('LLM-studio.html').read_text(encoding='utf-8')
assert '__HERMES_SESSION_TOKEN__' in page
assert '/api/credentials/pool' in page
assert '<title>Hermes · LLMs Studio</title>' in page
assert '<span>Dashboard</span>' in page and 'M19 12H5' in page
assert 'aria-expanded="false"' in page and 'Providers List' in page
assert 'Add Custom Provider' in page and 'Active providers' in page
assert 'id="builtinOverlay"' in page and 'id="customOverlay"' in page
assert '<label>Provider ID</label>' not in page and 'Stable ID' not in page
assert 'optional unless set as default' in page
assert "if($('#makeActive')?.checked&&!model)" in page
assert "id:provider.isDraft?'':provider.id" in page
assert "content.inert=!open" in page
assert "if(isCustom)$('#builtinModalBody').innerHTML=''" in page
assert 'class="studio-fab"' not in page
assert 'env(safe-area-inset-bottom' in page and 'prefers-reduced-motion:reduce' in page
backend = Path('LLM_studio.py').read_text(encoding='utf-8')
assert 'entry.pop("name", None)' in backend
assert 'optional_model_sentinel' in backend
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

grep -q '^ARG KEEP_BROWSER=0$' Dockerfile
grep -q '^ARG KEEP_TUI=1$' Dockerfile
grep -q '^ARG KEEP_MEDIA=0$' Dockerfile
grep -q '^ARG KEEP_GOOGLE=0$' Dockerfile
grep -q '^ARG KEEP_PHOTON=0$' Dockerfile
grep -q '^ARG KEEP_CHANNELS="discord telegram"$' Dockerfile
grep -q 'RUN /prune.sh "${KEEP_BROWSER}" "${KEEP_TUI}" "${KEEP_MEDIA}" "${KEEP_GOOGLE}" "${KEEP_PHOTON}" "${KEEP_CHANNELS}"' Dockerfile
grep -q 'HERMES_DASHBOARD_FILES_ROOT=/data' Dockerfile
grep -q 'LLM_studio.py' Dockerfile
grep -q 'LLM-studio.html' Dockerfile
grep -q 'app.include_router(_LLM_studio_routes.router)' prune.sh
grep -q 'LLM-studio/switch?dashboard=studio' prune.sh
grep -q '✦ LLMs Studio' prune.sh
# The injected ✦ LLMs Studio link must stay minimal and pinned top-right:
# top safe-area inset, horizontal-only padding, no shadow, no forced height.
grep -q 'safe-area-inset-top,0px' prune.sh
grep -q 'padding:0 16px' prune.sh
if grep -Eq 'min-height:48px|box-shadow' prune.sh; then
    echo 'ERROR: the LLMs Studio dashboard link must stay minimal (no min-height, no box-shadow)' >&2
    exit 1
fi
grep -q '@router.get("/LLM-studio/switch"' LLM_studio.py
grep -q '/api/credentials/pool' LLM-studio.html
grep -q 'exec /opt/hermes/docker/entrypoint-dispatch.sh' railway-entrypoint.sh
grep -q 'HERMES_DASHBOARD_OIDC_ISSUER' railway-entrypoint.sh
grep -q 'HERMES_DASHBOARD_OIDC_CLIENT_ID' railway-entrypoint.sh
grep -q "! -name 'whatsapp-bridge'" prune.sh
# The uv payload seed cache (new in v0.22.x images, ~400 MB) must be pruned.
grep -q 'rm_group "uv payload seed cache" /opt/hermes/uv-cache' prune.sh
# Dockerfile image pin and prune.sh version gate must name the same release.
pinned_tag=$(sed -n 's/^ARG HERMES_IMAGE=nousresearch\/hermes-agent:\(v[0-9.]*\)@sha256:[0-9a-f]\{64\}$/\1/p' Dockerfile)
expected_tag=$(sed -n 's/^EXPECTED_HERMES_VERSION="\(v[0-9.]*\)"$/\1/p' prune.sh)
if [ -z "$pinned_tag" ] || [ "$pinned_tag" != "$expected_tag" ]; then
    echo "ERROR: Dockerfile HERMES_IMAGE tag ($pinned_tag) and prune.sh EXPECTED_HERMES_VERSION ($expected_tag) must match" >&2
    exit 1
fi
if ! grep -q "^EXPECTED_HERMES_PY_VERSION=\"${expected_tag#v}\"$" prune.sh; then
    echo "ERROR: EXPECTED_HERMES_PY_VERSION does not match EXPECTED_HERMES_VERSION ($expected_tag)" >&2
    exit 1
fi
# Platform integrations must never be removed by unconditional rm_group rules;
# channel pruning happens only through rm_channel_group inside the conditional
# channel-selection / KEEP_PHOTON blocks below (this guard keeps it that way).
if grep -Eq 'rm_group .*(/plugins/platforms/(whatsapp|photon)|/gateway/platforms/whatsapp)' prune.sh; then
    echo 'ERROR: prune.sh unconditionally removes a supported platform integration' >&2
    exit 1
fi
channel_block=$(awk '/^# --- Channel selection \(KEEP_CHANNELS\)/{f=1} /^# --- Removed plugins/{f=0} f' prune.sh)
if [ -z "$channel_block" ]; then
    echo 'ERROR: could not locate the channel-selection block in prune.sh' >&2
    exit 1
fi
if ! printf '%s\n' "$channel_block" | grep -q 'rm_channel_group'; then
    echo 'ERROR: channel-selection block does not prune via rm_channel_group' >&2
    exit 1
fi
outside=$(awk '/^# --- Channel selection \(KEEP_CHANNELS\)/{f=1} /^# --- Removed plugins/{f=0} !f' prune.sh)
if printf '%s\n' "$outside" | grep -q 'rm_channel_group'; then
    echo 'ERROR: rm_channel_group used outside the channel-selection block' >&2
    exit 1
fi
# Channel selection must be explicit, validated, and must not silently change
# the upstream-default build ("all" keeps every adapter, as before).
grep -q 'KEEP_CHANNELS="${6:-discord telegram}"' prune.sh
grep -q 'has no plugin under /opt/hermes/plugins/platforms' prune.sh
grep -q "prunes its dependency stack" prune.sh
grep -q 'prune verify: git works without perl' prune.sh
grep -q 'rm_group "perl runtime"' prune.sh
grep -q 'rm_group "macOS-only skills (apple category)"' prune.sh
grep -q 'rm_group "computer_use plugin + tool backend"' prune.sh
grep -q 'rm_group "hermes-achievements plugin"' prune.sh
grep -q 'venv-slim: removed' prune.sh
# Kept-channel adapters must be import-verified in the prune verification.
grep -q 'importlib.import_module(f"plugins.platforms.{ch}.adapter")' prune.sh

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
