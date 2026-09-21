---
name: hevy
description: "Use when reading Hevy workouts or routines via MCP."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [hevy, workout, gym, mcp]
---

# Hevy (official API MCP)

Read the user's Hevy training log. **Official API**, Hevy **Pro** key required.

## When to Use

- Last workout, history, routines, exercise search, body measurements logged in Hevy
- Do not use for Yazio (calories) or Renpho (scale/tape)

## Install on this host

- Package `hevy-mcp` **6.1.13** (chrisdoc/hevy-mcp), installed once with npm at
  `/opt/data/mcp/node/` (host: `/srv/hermes/data/mcp/node/`)
- Server `hevy` = `node …/node_modules/hevy-mcp/dist/cli.mjs`, all 22 tools enabled. 2026-09-19.
- Secret: BWS `HEVY_API_KEY` → `${env:HEVY_API_KEY}` (Bitwarden Secrets Manager, EU vault)
- Key from https://hevy.com/settings?developer
- Do not `npx -y hevy-mcp` (re-downloads at each start) and do not write a local env file.

## Tools (`mcp__hevy__*`)

Read: `get-workouts` (`page` ≥ 1, `page_size` 1–10), `get-workout`, `get-workout-events`, `get-routines`, `get-routine`,
`search-routines`, `get-routine-folder`, `get-exercise-template`, `search-exercise-templates`, `get-exercise-history`,
`get-body-measurements`, `get-body-measurement`, `get-training-summary` (4-week rollup: counts, volume, trends)

Write (ask first): `create-workout`, `update-workout`, `replace-workout-exercises`, `create-routine`, `update-routine`,
`create-routine-folder`, `create-exercise-template`, `create-body-measurement`, `update-body-measurement`

Start with `get-training-summary` for "how is training going", `get-workouts` page 1 for "last session".

## Smoke

```bash
hermes mcp test hevy
```

If 401: fix `HEVY_API_KEY` in BWS, then reload MCP.

## Pitfalls

- Pro subscription required
- `page_size` max 10 on list endpoints; the key is `page_size`, not `pageSize` / `limit`
- Mid-session reload: CLI `/reload-mcp`; Desktop → Capabilities → MCP → toggle the server (slash is hidden).
