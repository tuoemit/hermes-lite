# Changelog

Pin-bump history for this template. Each entry records the upstream releases
crossed, what changed in the template, and how the bump was verified.

## [v0.22.1] — 2026-10-15

**Base image:** v0.21.6 → v0.22.1 (digest-pinned).

### Added
- Slim build profile via new Dockerfile args: `KEEP_BROWSER=0`, `KEEP_MEDIA=0`,
  `KEEP_GOOGLE=0`, `KEEP_PHOTON=0`, `KEEP_CHANNELS="discord telegram"` — every
  upstream feature is restorable with `--build-arg`.
- Build-time guards: kept-channel adapter import checks, git-without-perl probe,
  fail-fast on contradictory flag combinations.

### Changed
- LLMs Studio renamed to **LLM-studio**: files (`LLM_studio.py`, `LLM-studio.html`)
  and routes (`/LLM-studio`, `/LLM-studio/switch`, `/api/LLM-studio/*`).
- Dashboard shortcut moved to the top-right corner and restyled minimal:
  no shadow, no vertical padding.

### Removed
- Browser stack (~515 MB), ffmpeg/ffprobe (~279 MB), Google stack (~140 MB),
  Photon sidecar (~114 MB), unused venv packages (~165 MB), perl (~56 MB),
  `computer_use` and `hermes-achievements` plugins, macOS-only skills,
  and all platform adapters except Discord + Telegram.
- Rootfs: **2,391 MB → 1,183 MB (−51%)**.

### Security
- Pinned above base image: PyJWT 2.15.1, tornado 6.5.10, urllib3 2.8.0,
  multidict 6.9.1, oauthlib 4.0.0.

### Verified
- Clean rebuild, live boot, auth, gateway, LLM-studio round-trip, doctor
  (no active security advisories), Discord/Telegram adapter imports, git probe.