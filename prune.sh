#!/bin/sh
# Prune the official Hermes image down to the Railway dashboard + gateway
# runtime, align HOME with this template's HERMES_HOME layout, and verify
# the result. The pruned tree is flattened into a fresh stage by Dockerfile.
#
#   $1 = KEEP_BROWSER (1 = keep Playwright/Chromium, 0 = remove)
#   $2 = KEEP_TUI    (1 = keep Node + the dashboard Chat tab TUI, 0 = remove)
#
# Default to removing the browser stack: the template optimizes for the
# Railway free tier, matching the Dockerfile's ARG KEEP_BROWSER=0. Callers who
# pass $1 explicitly override this. The TUI is KEPT by default: the dashboard
# Chat tab is always enabled upstream and node + the prebuilt bundle are its
# runtime; stripping it is an explicit opt-out (KEEP_TUI=0).
#
# The image is pinned to a released Hermes version in Dockerfile. Keep the
# hard-coded pruning rules aligned with that pinned release and update the
# version intentionally when Hermes is upgraded.
set -eu

KEEP_BROWSER="${1:-0}"
case "$KEEP_BROWSER" in
    0|1) ;;
    *)
        echo "ERROR: KEEP_BROWSER must be 0 or 1 (got '$KEEP_BROWSER')" >&2
        exit 2
        ;;
esac

KEEP_TUI="${2:-1}"
case "$KEEP_TUI" in
    0|1) ;;
    *)
        echo "ERROR: KEEP_TUI must be 0 or 1 (got '$KEEP_TUI')" >&2
        exit 2
        ;;
esac

# --- Expected Hermes release -------------------------------------------------
# Every anchored patch below matches the exact pinned release, so a version
# bump must be detected once, clearly, rather than failing some arbitrary
# patch in the middle of a prune (see the "Updating Hermes" section in the
# README). Bump EXPECTED_HERMES_VERSION FIRST when changing HERMES_IMAGE, then
# re-run the build and reconcile each patch against the new release.
EXPECTED_HERMES_VERSION="v2026.9.14"
EXPECTED_HERMES_PY_VERSION="0.21.3"
/opt/hermes/.venv/bin/python3 - "$EXPECTED_HERMES_VERSION" "$EXPECTED_HERMES_PY_VERSION" <<'PYBLOCK'
import json, pathlib, sys, tomllib

want_tag, want_py = sys.argv[1], sys.argv[2]

# Authoritative marker baked by the upstream Dockerfile
# (/etc/hermes/image-provenance.json, chmod 444): {"...","version":"<pyproject>"}.
marker = pathlib.Path("/etc/hermes/image-provenance.json")
if marker.is_file():
    try:
        got = json.loads(marker.read_text(encoding="utf-8")).get("version")
    except (json.JSONDecodeError, OSError):
        got = None
    if str(got) == want_py:
        print(f"prune verify: Hermes provenance version {got} (~ {want_tag}) OK")
        raise SystemExit(0)
    print(f"ERROR: provenance marker reports version {got!r}; this template targets "
          f"{want_tag} ({want_py}).", file=sys.stderr)
    print("       Bump EXPECTED_HERMES_VERSION and reconcile every anchored patch before pruning.", file=sys.stderr)
    raise SystemExit(1)

# Fallback: read the pyproject version directly (same mechanism as the marker).
ppt = pathlib.Path("/opt/hermes/pyproject.toml")
if not ppt.is_file():
    raise SystemExit("ERROR: cannot determine Hermes version (no /etc/hermes/image-provenance.json, no /opt/hermes/pyproject.toml)")
try:
    got = tomllib.loads(ppt.read_text(encoding="utf-8"))["project"]["version"]
except (tomllib.TOMLDecodeError, KeyError, OSError) as exc:
    raise SystemExit(f"ERROR: could not parse /opt/hermes/pyproject.toml: {exc}")
if str(got) != want_py:
    print(f"ERROR: pyproject version {got!r}; this template targets {want_tag} ({want_py}).", file=sys.stderr)
    print("       Bump EXPECTED_HERMES_VERSION and reconcile every anchored patch before pruning.", file=sys.stderr)
    raise SystemExit(1)
print(f"prune verify: Hermes pyproject version {got} (~ {want_tag}) OK")
PYBLOCK

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

# --- Optional: strip the in-browser Chat tab runtime (KEEP_TUI=0) ----------
# The dashboard Chat tab is the only runtime consumer of Node in a
# Telegram-only deployment (verified: gateway/platforms/*, boot hooks
# docker/stage2-hook.sh, cont-init.d and s6-rc.d have no node/npm usage; the
# WhatsApp/photon adapters that also used node are already removed above).
# With KEEP_TUI=0 we drop node itself and the bundled TUI it runs. The Python
# launch plumbing is DELIBERATELY KEPT: web_server.py and web_routers/audio.py
# import web_server_chat at module level, so deleting those modules would
# crash the dashboard at boot. Instead, with node gone the Chat tab launcher
# hits upstream's own designed degradation — _tui_node_bin() exits 1 and
# chat_ws catches the SystemExit and closes the WS with a clear reason — so
# the tab fails closed rather than breaking the dashboard. `hermes --tui`
# also goes dark (opt-out semantics). Browsers (KEEP_BROWSER) do not need
# node.
if [ "$KEEP_TUI" = "0" ]; then
    rm_group "node runtime (KEEP_TUI=0)" \
        /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx \
        /usr/local/lib/node_modules
    rm_group "TUI bundle (KEEP_TUI=0)"    /opt/hermes/ui-tui
else
    echo "  KEPT: node + in-browser Chat tab TUI (KEEP_TUI=1)"
fi

# --- Out-of-scope messaging platforms (Telegram is the only target) --------
# The user removed WhatsApp + iMessage/Photon from scope. This template must
# stay a Telegram+dashboard deployment. Below we delete only what has been
# dependency-traced against the pinned release:
#
#   plugins/platforms/whatsapp/   directory plugin (Baileys node bridge):
#                                discovered via plugins/platforms/* plugin.yaml
#                                scan — no Python module imports it; removing
#                                the dir removes it from discovery.
#   plugins/platforms/photon/    directory plugin (iMessage via Spectrum
#                                sidecar); same discovery mechanism, no imports.
#   plugins/platforms/photon/sidecar/node_modules/
#                                build-time-baked sidecar deps (macOS/Linux
#                                node sidecar we do not run).
#   scripts/whatsapp-bridge/     bridge.js + manifest, mirrored into
#                                HERMES_HOME at runtime. With the plugin gone
#                                it is dead weight (also covered by the
#                                scripts/ sweep further down in this file —
#                                kept here explicit for clarity).
#   gateway/platforms/whatsapp_common.py + whatsapp_cloud.py
#                                Builtin modules. whatsapp_cloud is wired into
#                                gateway/run.py:_BUILTIN_ADAPTERS (a module
#                                removed never breaks startup: dispatch is
#                                lazy + adapter-creation failures degrade to
#                                "No adapter" logs), BUT an operator could
#                                still enable whatsapp_cloud in config.yaml,
#                                and the lazy import_module() would raise
#                                ModuleNotFoundError out of _instantiate_*.
#                                We DEFUSE that upstream line in-place below,
#                                mirroring the exact v2026.9.14 text so nothing
#                                else changes. Keeping whatsapp_common would
#                                pull WhatsAppBehaviorMixin runtime deps; it is
#                                only referenced by the two removed modules &
#                                the whatsapp plugin (all gone or defused).
#
# We do NOT touch the CLI surface (hermes_cli/subcommands/whatsapp.py, the
# dashboard messaging routes). They keep working but only import the removed
# core modules lazily, inside function bodies, so a shell invocation cannot
# import-crash. Erasing them would be a deeper upstream patch with zero
# runtime benefit (they are already dead code at rest).
rm_group "whatsapp platform plugin"   /opt/hermes/plugins/platforms/whatsapp
rm_group "photon/iMessage plugin"     /opt/hermes/plugins/platforms/photon
rm_group "whatsapp bridge scripts"    /opt/hermes/scripts/whatsapp-bridge
rm_group "whatsapp core modules"      \
    /opt/hermes/gateway/platforms/whatsapp_common.py \
    /opt/hermes/gateway/platforms/whatsapp_cloud.py

# Defuse the upstream builtin-adapter entry for the removed whatsapp_cloud
# module so an operator who enables `platforms.whatsapp_cloud` in config.yaml
# can never crash-loop the gateway on a missing module import. The upstream
# entry is a TWO-LINE statement (key + message continuation): delete both
# lines together. Anchor on the exact upstream text so a version bump fails
# the build instead of drifting.
_runpy=/opt/hermes/gateway/run.py
grep -qF 'Platform.WHATSAPP_CLOUD: ("whatsapp_cloud", "WhatsAppCloudAdapter", "check_whatsapp_cloud_requirements",' "$_runpy" || {
    echo 'ERROR: whatsapp_cloud builtin-adapter line not found in gateway/run.py — update this patch for the pinned Hermes release' >&2
    exit 1
}
# N joins the following continuation line into the pattern space; d deletes both.
sed -i '/^    Platform\.WHATSAPP_CLOUD:/{N;d;}' "$_runpy"
echo "  defused: whatsapp_cloud builtin-adapter entry removed from gateway/run.py"

# --- Build-time toolchain --------------------------------------------------
# Native extensions are already built into the upstream venv, and the compiler
# backends (/usr/libexec/gcc, /usr/lib/gcc) are removed, so runtime
# compilation was already impossible — the frontends, headers and build tools
# are pure dead weight. Keep this architecture-neutral (globs, no exact
# versions) so a base-image bump cannot silently skip a rule.
rm_group "C/C++ frontends" \
    /usr/bin/gcc /usr/bin/g++ /usr/bin/cc /usr/bin/c++ \
    /usr/bin/x86_64-linux-gnu-gcc* /usr/bin/aarch64-linux-gnu-gcc* \
    /usr/bin/x86_64-linux-gnu-g++* /usr/bin/aarch64-linux-gnu-g++* \
    /usr/bin/x86_64-linux-gnu-cc /usr/bin/aarch64-linux-gnu-cc \
    /usr/bin/*-linux-gnu-lto-dump-*
rm_group "binutils" \
    /usr/bin/as /usr/bin/ld /usr/bin/ld.bfd /usr/bin/ld.gold \
    /usr/bin/ar /usr/bin/ranlib /usr/bin/nm /usr/bin/objcopy \
    /usr/bin/objdump /usr/bin/strip /usr/bin/size /usr/bin/addr2line \
    /usr/bin/c++filt
rm_group "make"          /usr/bin/make /usr/bin/gmake
rm_group "C headers"     /usr/include
rm_group "pkg-config" \
    /usr/bin/pkg-config /usr/bin/x86_64-linux-gnu-pkg-config \
    /usr/bin/aarch64-linux-gnu-pkg-config /usr/share/pkgconfig
rm_group "cmake/ctest/cpack" \
    /usr/bin/cmake /usr/bin/ctest /usr/bin/cpack /usr/share/cmake-*

multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
if [ -n "$multiarch" ]; then
    rm_group "static libs" \
        /usr/lib/python3.13/config-3.13-* \
        "/usr/lib/${multiarch}/libc.a" \
        "/usr/lib/${multiarch}/libffi.so" \
        "/usr/lib/${multiarch}/libolm.a"
else
    rm_group "static libs" /usr/lib/python3.13/config-3.13-*
fi

rm_group "docker CLI"            /usr/bin/docker

# --- Dev-only trees (build inputs only, no runtime references) -------------
# apps/ (only apps/shared reaches the image, as a web-build input already
# bundled into the SPA) and the setup/lint shims are monorepo build/CI inputs.
rm_group "dev-only trees" \
    /opt/hermes/apps \
    /opt/hermes/setup.py /opt/hermes/setup-hermes.sh \
    /opt/hermes/.coderabbit.yaml /opt/hermes/.prettierrc \
    /opt/hermes/.prettierignore

# scripts/ is mostly dev/CI tooling, but upstream's stage2 boot hook EXECUTES
# two files from it on every container start (docker/stage2-hook.sh, pinned
# release): scripts/docker_config_migrate.py (config-schema migrations) and
# scripts/docker_rebootstrap_nous_session.py (HERMES_AUTH_JSON_REBOOTSTRAP).
# Deleting scripts/ wholesale silently disables config migrations on
# volume-backed upgrades and prints a boot warning every start. Preserve just
# those two (both stdlib-only, no intra-scripts imports); delete the rest
# (CI/release/dev tooling, the WhatsApp bridge, installer shims).
find /opt/hermes/scripts -mindepth 1 -maxdepth 1 \
    ! -name 'docker_config_migrate.py' \
    ! -name 'docker_rebootstrap_nous_session.py' \
    -exec rm -rf {} + 2>/dev/null || true
echo "  pruned: dev-only scripts (kept stage2 utils: docker_config_migrate.py, docker_rebootstrap_nous_session.py)"

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

    # The GPU/Xvfb parts are below; this removes the remaining GUI/X11 client
    # libraries that `playwright install --with-deps` pulled in. Shared runtime
    # libs are deliberately kept (libexpat -> Python, libglib, freetype,
    # fontconfig, pixman) — the ldd integrity sweep below fails the build if
    # anything we removed is still load-time-required.
    if [ -n "$multiarch" ]; then
        # NB: the ${multiarch} dir part is quoted, the glob is NOT — rm_group
        # passes each argument to `rm -rf` verbatim, so a quoted glob would be
        # a literal filename and silently match nothing. Unmatched patterns are
        # harmless (rm -f ignores them), which keeps this safe across base
        # image bumps.
        rm_group "mesa/LLVM GPU stack" \
            "/usr/lib/${multiarch}"/libLLVM.so.* \
            "/usr/lib/${multiarch}"/libgallium*.so* \
            "/usr/lib/${multiarch}"/libz3.so.* \
            "/usr/lib/${multiarch}"/libdri2.so.* \
            "/usr/lib/${multiarch}"/libGL.so.1* \
            "/usr/lib/${multiarch}"/libEGL.so.1* \
            "/usr/lib/${multiarch}"/libOpenGL.so.1* \
            "/usr/lib/${multiarch}"/libGLX*.so* \
            "/usr/lib/${multiarch}"/libgbm.so.1* \
            "/usr/lib/${multiarch}"/libdrm.so.2* \
            "/usr/lib/${multiarch}/dri"
        rm_group "GUI/X11 client libs (playwright apt deps)" \
            "/usr/lib/${multiarch}"/libnss3.so* "/usr/lib/${multiarch}"/libnssutil3.so* \
            "/usr/lib/${multiarch}"/libsmime3.so* "/usr/lib/${multiarch}"/libssl3.so* \
            "/usr/lib/${multiarch}"/libfreebl3.so* "/usr/lib/${multiarch}"/libnspr4.so* \
            "/usr/lib/${multiarch}"/libatk-1.0.so.0* "/usr/lib/${multiarch}"/libatk-bridge-2.0.so.0* \
            "/usr/lib/${multiarch}"/libatspi.so.0* \
            "/usr/lib/${multiarch}"/libpango-1.0.so.0* "/usr/lib/${multiarch}"/libpangocairo-1.0.so.0* \
            "/usr/lib/${multiarch}"/libpangoft2-1.0.so.0* "/usr/lib/${multiarch}"/libcairo.so.2* \
            "/usr/lib/${multiarch}"/libcups.so.2* \
            "/usr/lib/${multiarch}"/libxkbcommon.so.0* "/usr/lib/${multiarch}"/libxkbcommon-x11.so.0* \
            "/usr/lib/${multiarch}"/libxcomposite.so.1* "/usr/lib/${multiarch}"/libxdamage.so.1* \
            "/usr/lib/${multiarch}"/libxfixes.so.3* "/usr/lib/${multiarch}"/libxrandr.so.2* \
            "/usr/lib/${multiarch}"/libxrender.so.1* "/usr/lib/${multiarch}"/libxext.so.6* \
            "/usr/lib/${multiarch}"/libX11.so.6* "/usr/lib/${multiarch}"/libX11-xcb.so.1* \
            "/usr/lib/${multiarch}"/libxcb.so.1* \
            "/usr/lib/${multiarch}"/libxshmfence.so.1* \
            "/usr/lib/${multiarch}"/libwayland-client.so.1* \
            "/usr/lib/${multiarch}"/libasound.so.2*
    fi
    rm_group "ALSA data"                  /usr/share/alsa
    rm_group "Xvfb/X11 utils" \
        /usr/bin/Xvfb /usr/bin/xkbcomp /usr/bin/xkbprint \
        /usr/bin/xkbevd /usr/share/X11
fi

# --- Browser-prune fail-fast --------------------------------------------------
# If KEEP_BROWSER=0 the Playwright/Chromium tree must actually be gone. A
# dangling selector (e.g. an upstream layout change that moved the browser
# tree) would otherwise fail silently here and only surface later as a
# surprise --browser-enabled path (and a size regression) on the $5 tier.
# Fail fast, and say WHICH tree survived so a layout change is actionable.
if [ "$KEEP_BROWSER" = "0" ] && [ -d /opt/hermes/.playwright ]; then
    echo "ERROR: KEEP_BROWSER=0 but /opt/hermes/.playwright still exists — the browser tree" >&2
    echo "       was not pruned (upstream layout changed?). Wire the new location into the" >&2
    echo "       KEEP_BROWSER prune list above." >&2
    exit 1
fi

# --- Shared-library integrity sweep -----------------------------------------
# Every prune above must leave no runtime binary or venv native extension with
# an unresolvable DT_NEEDED dependency. A "not found" line fails the build —
# this is what makes the aggressive toolchain/GUI pruning safe.
missing=$( {
    ldd "$(command -v python3)" 2>/dev/null
    [ "$KEEP_TUI" = "1" ] && ldd /usr/local/bin/node 2>/dev/null
    ldd /opt/hermes/.venv/bin/python3 2>/dev/null
    find /opt/hermes/.venv -type f -name '*.so' -print0 2>/dev/null \
        | xargs -0 -r -n 200 ldd 2>/dev/null
    ldd /usr/bin/rg /usr/bin/git /usr/bin/ffmpeg 2>/dev/null
} | grep -i "not found" || true)
if [ -n "$missing" ]; then
    echo "ERROR: prune removed a shared library still required at runtime:" >&2
    echo "$missing" >&2
    exit 1
fi
echo "prune verify: shared-library integrity OK"

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

# --- /opt/data -> /data/.hermes compatibility symlink -----------------------
# The sed patch above only covers STATIC image files. Upstream also renders
# per-profile gateway s6 scripts at RUNTIME (hermes_cli/service_manager.py
# hard-codes `export HOME=/opt/data` + `cd /opt/data` and writes them to the
# tmpfs /run/service at boot — unreachable from any build-time patch). That
# gateway-default slot is the process that actually serves the Telegram bot,
# so a static patch alone leaves its HOME-anchored state (git config, .netrc,
# provider SDK config, XDG state) in the non-persistent /opt/data skeleton.
#
# Replacing the hermes user's home skeleton with a symlink into the template's
# data root makes EVERY current and future /opt/data reference (static
# scripts, generated scripts, HOME fallbacks) resolve to /data/.hermes.
# The upstream stage2 hook guarantees /data/.hermes exists (root mkdir -p +
# chown) before any supervised process starts, so the link never dangles.
rm -rf /opt/data
ln -s /data/.hermes /opt/data
echo "  linked: /opt/data -> /data/.hermes"

# --- Dashboard file-browser hardening: block /proc from the spot editor -----
# The dashboard's /api/fs/* routes (spot editor / terminal helper) resolve
# arbitrary absolute paths and do NOT honor HERMES_DASHBOARD_FILES_ROOT. Their
# read-side guard (hermes_cli/web_routers/files.py::_is_sensitive_path) blocks
# credential basenames but not /proc. Because dashboard + gateway share the
# hermes uid, /proc/<pid>/environ is owner-readable and would expose every
# container secret (Telegram token, model keys, the dashboard password) to an
# authenticated dashboard user through the UI.
#
# Fix: teach _is_sensitive_path to reject the ABSOLUTE /proc root subtree
# (path.parts[0]=="/" and parts[1]=="proc"). Scoped precisely to /proc so a
# legitimately named "<workdir>/proc" directory is unaffected. The browser tab
# (managed /api/files/*) is already confined to
# HERMES_DASHBOARD_FILES_ROOT=/data/.hermes, so this only hardens the spot
# editor routes. Gateway-side /proc diagnostics are untouched (this module is
# dashboard-only). Anchor on the exact upstream line so a version bump fails
# the build instead of silently drifting.
_fsfiles=/opt/hermes/hermes_cli/web_routers/files.py
grep -qF '    return any(part.lower() in _SENSITIVE_MANAGED_DIR_NAMES for part in path.parts)' "$_fsfiles" || {
    echo 'ERROR: sensitive-path guard line not found in hermes_cli/web_routers/files.py — update this patch for the pinned Hermes release' >&2
    exit 1
}
sed -i 's|^    return any(part\.lower() in _SENSITIVE_MANAGED_DIR_NAMES for part in path\.parts)$|    if len(path.parts) >= 2 and path.parts[0] == "/" and path.parts[1] == "proc":\n        return True\n    return any(part.lower() in _SENSITIVE_MANAGED_DIR_NAMES for part in path.parts)|' "$_fsfiles"
echo "  hardened: dashboard file browser blocks /proc (sensitive-path guard)"

# --- Security repair / gate: known-vulnerable venv packages ------------------
# The pinned release's frozen dependency set contains three packages the
# dashboard security audit flagged, with these upgrades:
#
#   anyio     4.12.1  ->  4.14.2   GHSA-82r6-8w77-94w6 (CRITICAL)
#                                + GHSA-5p39-cfhj-2xmp (MODERATE)
#   httpx2    2.7.0   ->  2.12.0   GHSA-7mj9-2mp8-4m2p (HIGH, fixed 2.10.0)
#                                + GHSA-8xx6-hgc6-gc2m (HIGH, fixed 2.12.0)
#                                + remaining MODERATE/UNKNOWN findings (fixed <= 2.12.0)
#   httpcore2 2.7.0   ->  2.12.0   GHSA-7mj9-2mp8-4m2p (HIGH) + PYSEC-2026-3844 (UNKNOWN)
#
# httpx2==2.12.0 requires httpcore2==2.12.0 exactly and anyio>=4.10 (confirmed
# via PyPI metadata). anyio 4.14.2 requires no new transitive (idna>=2.8, already
# locked at 3.18; typing-extensions only for py<3.13). All three are pure-Python
# wheels, so we swap them in-place deterministically: download -> SHA-256 verify
# -> unzip the wheel's top-level package dir + dist-info over the venv.
#
# The block is a GATE first: it aborts the build unless the venv still matches
# the exact pinned vulnerable set being targeted (so a future Hermes bump, with
# the advisories already fixed upstream, cannot apply a now-wrong swap). The fix
# runs in stage 1, so the corrected venv is captured by the stage-2 flatten COPY.
mkdir -p /run/venv-wheels
cat > /run/venv-swap.py <<'PYBLOCK'
import hashlib
import importlib.metadata
import os
import shutil
import urllib.request
import zipfile

VENV = "/opt/hermes/.venv"
_lib = os.path.join(VENV, "lib")
_pydirs = [p for p in os.listdir(_lib) if p.startswith("python")]
SP = os.path.join(_lib, _pydirs[0], "site-packages")
WHEEL_DIR = "/run/venv-wheels"

# dist_name -> (module_dir, fixed_version, sha256, wheel url)
PINS = {
    "anyio": (
        "anyio", "4.14.2",
        "9f505dda5ac9f0c8309b5e8bd445a8c2bf7246f3ce950121e45ea15bc41d1494",
        "https://files.pythonhosted.org/packages/da/35/f2287558c17e29fafc8ef3daf819bb9834061cfa43bff8014f7df7f63bdc/anyio-4.14.2-py3-none-any.whl",
    ),
    "httpx2": (
        "httpx2", "2.12.0",
        "cc8b6eecb8661c146b8f89a60e97456ee086e91a784ed31ac450c3a9e613dd36",
        "https://files.pythonhosted.org/packages/c8/95/411ba65569158e862368917aaf56597f3e5fa3b91b0502919638465a08f3/httpx2-2.12.0-py3-none-any.whl",
    ),
    "httpcore2": (
        "httpcore2", "2.12.0",
        "7e04258ce01013d7d615e5b910a3b27fac937d7a95038227e79652b4ba3b4ceb",
        "https://files.pythonhosted.org/packages/d2/74/d370e55600d9bcfa0d9794b0166126d49291a3d2b20c268fc98c453a4948/httpcore2-2.12.0-py3-none-any.whl",
    ),
}

installed = {
    d.metadata["Name"].lower(): d.version
    for d in importlib.metadata.distributions(path=[SP])
}

# GATE: only proceed if we recognise the exact vulnerable set being patched.
expected_vuln = {"anyio": "4.12.1", "httpx2": "2.7.0", "httpcore2": "2.7.0"}
for name, (mod, want, want_sha, url) in PINS.items():
    cur = installed.get(name)
    if cur != expected_vuln[name]:
        raise SystemExit(
            f"venv-verify: '{name}' is {cur!r}, expected {expected_vuln[name]!r} — "
            f"this blocker targets the pinned Hermes release; reconcile it before pruning."
        )

def _fetch(url, sha, dest):
    if os.path.exists(dest) and hashlib.sha256(open(dest, "rb").read()).hexdigest() == sha:
        return
    req = urllib.request.Request(url, headers={"User-Agent": "hermes-lite-template"})
    with urllib.request.urlopen(req, timeout=180) as r:
        data = r.read()
    if hashlib.sha256(data).hexdigest() != sha:
        raise SystemExit(f"venv-fix: SHA-256 mismatch for {dest} (aborting)")
    with open(dest, "wb") as f:
        f.write(data)

for name, (mod, want, want_sha, url) in PINS.items():
    whl = os.path.join(WHEEL_DIR, f"{name}-{want}.whl")
    _fetch(url, want_sha, whl)
    stage = whl + ".u"
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    with zipfile.ZipFile(whl) as z:
        z.extractall(stage)
    shutil.rmtree(os.path.join(SP, mod), ignore_errors=True)
    shutil.copytree(os.path.join(stage, mod), os.path.join(SP, mod))
    for stale in os.listdir(SP):
        if stale.startswith(name + "-") and stale.endswith(".dist-info"):
            shutil.rmtree(os.path.join(SP, stale), ignore_errors=True)
    shutil.copytree(
        os.path.join(stage, f"{name}-{want}.dist-info"),
        os.path.join(SP, f"{name}-{want}.dist-info"),
    )
    print(f"venv-fix: {name} {expected_vuln[name]} -> {want}")

# Post-swap smoke: imports must resolve against the fixed copies.
import importlib
for name, (mod, want, _sha, _url) in PINS.items():
    importlib.import_module(mod)
print("venv-fix: all three swapped and importable")
PYBLOCK

/opt/hermes/.venv/bin/python3 /run/venv-swap.py || {
    echo "ERROR: venv security gate failed (see output above). If you bumped HERMES_IMAGE," >&2
    echo "       reconcile this block against the new release's dependency set." >&2
    exit 1
}
rm -rf /run/venv-wheels /run/venv-swap.py
echo "  secured: venv anyio/httpx2/httpcore2 upgraded to fixed releases"


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
KEEP_TUI="$KEEP_TUI" \
/opt/hermes/.venv/bin/python3 - <<'PY'
import importlib
import os
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
    "/opt/hermes/docker/entrypoint-dispatch.sh",
    "/opt/hermes/docker/main-wrapper.sh",
    "/etc/s6-overlay/s6-rc.d/dashboard/run",
]
# TUI assets are only required when the Chat tab runtime was kept.
if os.environ.get("KEEP_TUI") == "1":
    must += [
        "/opt/hermes/ui-tui/dist/entry.js",
        "/opt/hermes/ui-tui/package.json",
    ]
missing = [p for p in must if not pathlib.Path(p).exists()]
if missing:
    sys.exit("prune broke the image, missing: " + ", ".join(missing))
print("prune verify: imports OK, runtime assets present")
PY

# The dashboard Chat tab spawns the prebuilt TUI bundle. Prove the bundle is
# loadable (every import resolves): with non-TTY stdin the entry evaluates the
# whole bundle, prints 'hermes-tui: no TTY' and exits 0 — a corrupt or
# incomplete bundle dies non-zero before that point. Run it exactly the way
# the launcher's fast path does (node --expose-gc).
if [ "$KEEP_TUI" = "1" ]; then
    tui_probe=$(/usr/local/bin/node --expose-gc /opt/hermes/ui-tui/dist/entry.js </dev/null 2>&1) || {
        echo "ERROR: TUI bundle probe crashed (exit=$?):" >&2
        echo "$tui_probe" >&2
        exit 1
    }
    case "$tui_probe" in
        *"hermes-tui: no TTY"*) echo "prune verify: TUI bundle loads" ;;
        *)
            echo "ERROR: TUI bundle probe gave unexpected output: $tui_probe" >&2
            exit 1
            ;;
    esac
else
    echo "prune verify: TUI intentionally removed (KEEP_TUI=0)"
fi

# Bind 0.0.0.0 (still reachable only from inside the build container) so the
# production auth gate — non-loopback bind + required provider, fail-closed —
# is actually exercised. /api/health is on the dashboard's public (auth-exempt)
# path list, so a 200 still means "gated dashboard started correctly".
HERMES_HOME=/tmp/prune-verify-home \
HERMES_WRITE_SAFE_ROOT=/tmp/prune-verify-home \
HERMES_DASHBOARD_FILES_ROOT=/ \
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=verify \
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=verify-password \
/opt/hermes/.venv/bin/hermes dashboard --host 0.0.0.0 --port 19119 --no-open >/tmp/hermes-dashboard-smoke.log 2>&1 &
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
if [ -d /data ] && [ -n "$(ls -A /data 2>/dev/null)" ]; then
    echo "ERROR: state baked into the /data volume mountpoint:" >&2
    ls -A /data | head -5 >&2
    exit 1
fi
echo "prune verify: /data clean"
