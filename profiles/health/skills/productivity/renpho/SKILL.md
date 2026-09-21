---
name: renpho
description: "Use when reading Renpho scale data via MCP."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [renpho, scale, weight, body-composition, mcp]
---

# Renpho (unofficial MCP)

Read the user's Renpho Health **scale** from Hermes. No official API.

## When to Use

- Weight, BMI, body fat, muscle, water, visceral fat, BMR, trends
- Do not use for Yazio calories (skill `yazio`) or Hevy workouts (skill `hevy`)

## Install on this host

- Local build of `renpho-mcp-server` **1.2.0** (Node, restored from the old machine) at
  `/opt/data/profiles/health/mcp/renpho-mcp-server/` (host: `/srv/hermes/data/profiles/health/mcp/renpho-mcp-server/`)
- Server `renpho` = `node …/renpho-mcp-server/dist/index.js`, all 9 tools enabled. Health profile, 2026-09-19.
- Secrets: **BWS only** `RENPHO_EMAIL` / `RENPHO_PASSWORD` → `${env:RENPHO_EMAIL}` / `${env:RENPHO_PASSWORD}`
- Needs **Renpho Health** (app bleue) + email/password
- Do not write a local env file; do not auto-update

## Tools (`mcp__renpho__*`)

Read: `health_check`, `get_current_user`, `get_scale_users`, `get_latest_measurement`, `get_body_composition`,
`get_measurements`, `get_weight_trend`, `get_sync_diagnostics`

Maintenance: `refresh_data` (clears the server's auth/measurement cache and re-fetches — use when the app synced but the MCP still shows an old reading)

No write/upload tools. No tape / girth tools in this server.

## Smoke

```bash
hermes -p health mcp test renpho
```

If auth fails: BWS must list `RENPHO_EMAIL` / `RENPHO_PASSWORD`, then reload MCP.

## Pitfalls

- Body-fat and other composition values use consumer bioelectrical impedance. Treat them as rough estimates, not accurate absolute measurements: hydration, glycogen, salt, meals, training, and foot temperature move the reading.
- Never decide a Fluide phase from one body-fat reading. Prefer weight averages over 7–14 days, waist, and photos; at most use body-fat trend under identical conditions as a weak secondary signal.
- Unofficial `cloud.renpho.com` API can break
- Wi-Fi scale sometimes delays binding until the phone app syncs (`refresh_data`, then retry)
- The server writes `renpho-combined.log` / `renpho-error.log` in its working directory; ignore them.
- Mid-session reload: CLI `/reload-mcp`; Desktop → Capabilities → MCP → toggle the server (slash is hidden).
