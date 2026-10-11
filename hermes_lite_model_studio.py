"""Hermes-lite LLMs Studio routes, mounted into the upstream dashboard at build time.

The UI intentionally delegates model/key writes to Hermes' own config, .env and
credential-pool APIs. This router only serves the standalone page, exposes a
secret-free settings snapshot, and adds the editable key_env field missing from
Hermes' generic custom-endpoint form.
"""
from __future__ import annotations

import html
import re
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

router = APIRouter()
_PAGE = Path(__file__).resolve().parent.parent / "web_dist" / "model-studio.html"
_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class CustomEndpointPayload(BaseModel):
    id: str = ""
    name: str
    base_url: str
    model: str
    key_env: str = ""
    api_mode: str = ""
    discover_models: bool = True
    clear_key: bool = False


@router.get("/model-studio", response_class=HTMLResponse, include_in_schema=False)
def model_studio_page():
    """Serve the standalone provider editor inside Hermes' existing auth boundary."""
    if not _PAGE.is_file():
        raise HTTPException(status_code=404, detail="LLMs Studio page is missing")
    source = _PAGE.read_text(encoding="utf-8")
    # The upstream dashboard's loopback-only session-token auth also protects
    # /api/* for non-OAuth local installs. Railway's Basic/OIDC session cookie
    # remains authoritative when auth_required is enabled.
    try:
        from hermes_cli.web_server import _SESSION_TOKEN, app
        token = "" if getattr(app.state, "auth_required", False) else str(_SESSION_TOKEN)
    except Exception:
        token = ""
    source = source.replace("__HERMES_SESSION_TOKEN__", html.escape(token, quote=True))
    return HTMLResponse(source, headers={"Cache-Control": "no-store"})


@router.get("/model-studio/switch", include_in_schema=False)
def switch_dashboard(dashboard: str = "studio"):
    """Dashboard switch handler: move between LLMs Studio and upstream Hermes UI."""
    if dashboard == "studio":
        return RedirectResponse(url="/model-studio", status_code=303)
    if dashboard == "hermes":
        return RedirectResponse(url="/", status_code=303)
    raise HTTPException(status_code=400, detail="dashboard must be 'studio' or 'hermes'")


@router.get("/api/model-studio/state")
def model_studio_state(profile: Optional[str] = None):
    """Return editable routing metadata, never plaintext API credentials."""
    from hermes_cli.web_routers import config_env

    with config_env._config_profile_scope(profile):
        cfg = config_env.read_raw_config()

    raw_model = cfg.get("model")
    if isinstance(raw_model, dict):
        model = {
            "provider": str(raw_model.get("provider") or ""),
            "name": str(raw_model.get("default", raw_model.get("name", "")) or ""),
            "base_url": str(raw_model.get("base_url") or ""),
            "key_env": str(raw_model.get("key_env") or ""),
        }
    else:
        model = {"provider": "", "name": str(raw_model or ""), "base_url": "", "key_env": ""}

    safe_providers = {}
    providers = cfg.get("providers")
    if isinstance(providers, dict):
        for provider_id, entry in providers.items():
            if not isinstance(entry, dict):
                continue
            models = entry.get("models")
            if isinstance(models, dict):
                model_names = [str(name) for name in models]
            elif isinstance(models, list):
                model_names = [str(name) for name in models]
            else:
                model_names = []
            safe_providers[str(provider_id)] = {
                "name": str(entry.get("name") or provider_id),
                "base_url": str(entry.get("base_url") or entry.get("url") or entry.get("api") or ""),
                "model": str(entry.get("model") or entry.get("default_model") or ""),
                "key_env": str(entry.get("key_env") or entry.get("api_key_env") or ""),
                "api_mode": str(entry.get("api_mode") or entry.get("transport") or ""),
                "discover_models": bool(entry.get("discover_models", True)),
                "models": model_names,
                "has_inline_key": bool(str(entry.get("api_key") or "").strip()),
            }
    # Read-only compatibility for legacy custom_providers: list entries. The
    # generic endpoint API still displays those, so expose their key_env name
    # without sending any key value to the browser.
    try:
        for entry in config_env.get_compatible_custom_providers(cfg) or []:
            if not isinstance(entry, dict) or entry.get("provider_key"):
                continue
            provider_id = config_env._custom_endpoint_id(str(entry.get("name") or ""))
            if not provider_id or provider_id in safe_providers:
                continue
            raw_models = entry.get("models")
            model_names = list(raw_models) if isinstance(raw_models, (list, dict)) else []
            safe_providers[provider_id] = {
                "name": str(entry.get("name") or provider_id),
                "base_url": str(entry.get("base_url") or entry.get("url") or entry.get("api") or ""),
                "model": str(entry.get("model") or entry.get("default_model") or ""),
                "key_env": str(entry.get("key_env") or entry.get("api_key_env") or ""),
                "api_mode": str(entry.get("api_mode") or entry.get("transport") or ""),
                "discover_models": bool(entry.get("discover_models", True)),
                "models": [str(name) for name in model_names],
                "has_inline_key": bool(str(entry.get("api_key") or "").strip()),
            }
    except Exception:
        pass
    return {"model": model, "providers": safe_providers}


@router.put("/api/model-studio/custom-endpoint")
def save_custom_endpoint(body: CustomEndpointPayload, profile: Optional[str] = None):
    """Create/update a named custom provider with a user-selected environment-key name."""
    from hermes_cli.web_routers import config_env
    from hermes_cli.web_models import CustomEndpointUpdate

    name = (body.name or "").strip()
    base_url = (body.base_url or "").strip()
    model = (body.model or "").strip()
    key_env = (body.key_env or "").strip()
    api_mode = (body.api_mode or "").strip()
    if not name or not base_url or not model:
        raise HTTPException(status_code=400, detail="Provider name, base URL, and model are required")
    if key_env and not _ENV_NAME.fullmatch(key_env):
        raise HTTPException(status_code=400, detail="Key variable must be a valid environment-variable name")
    if api_mode not in {"", "chat_completions", "codex_responses", "anthropic_messages"}:
        raise HTTPException(status_code=400, detail="Unsupported API mode")

    request = CustomEndpointUpdate(
        id=(body.id or "").strip(), name=name, base_url=base_url, model=model,
        api_key=None, api_mode=api_mode, discover_models=body.discover_models,
        make_default=False,
    )
    try:
        with config_env._config_profile_scope(profile), config_env._CONFIG_MUTATION_LOCK:
            cfg = config_env.require_readable_config_before_write()
            endpoint_id, entry = config_env._write_custom_endpoint(cfg, request)
            migrated_key_env = str(entry.get("key_env") or "").strip()
            # The generic endpoint helper preserves an existing API mode when
            # the payload asks for auto-detection; LLMs Studio exposes an
            # explicit auto choice, so clear stale pins here.
            if api_mode:
                entry["api_mode"] = api_mode
            else:
                entry.pop("api_mode", None)
                entry.pop("transport", None)
            # Hermes supports named-provider key_env indirection. Keep the
            # secret in .env; the manager UI only persists the variable name.
            if key_env:
                entry["key_env"] = key_env
                entry.pop("api_key", None)
            elif body.clear_key:
                entry.pop("key_env", None)
                entry.pop("api_key", None)
            # An empty key_env without an explicit clear means "preserve". This
            # matters when the upstream helper migrates a legacy inline key to
            # its generated .env variable during the same save.
            config_env.save_config(cfg)
        return {
            "ok": True, "id": endpoint_id,
            "key_env": str(entry.get("key_env") or ""),
            "cleared_key_env": migrated_key_env if body.clear_key else "",
        }
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=500, detail="Could not save custom provider configuration") from exc
