---
name: yazio
description: "Use when reading or logging Yazio meals via MCP."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [yazio, calories, nutrition, mcp]
---

# Yazio (unofficial MCP)

Read and log the user's Yazio diary from Hermes. **No official API.**

## When to Use

- User asks about today's / this week's meals, calories, macros, water, weight
- User wants to add or remove a forgotten Yazio entry
- Do not use for other calorie apps (MFP, Cronometer)

## Install on this host

- Pinned **yazio-mcp 0.0.14** (fliptheweb/yazio-mcp), installed once with npm at
  `/opt/data/mcp/node/` (host: `/srv/hermes/data/mcp/node/`)
- Server `yazio` = `node …/node_modules/yazio-mcp/dist/index.js`, all 15 tools enabled. 2026-09-19.
- Secrets: **BWS only** (`YAZIO_USERNAME`, `YAZIO_PASSWORD`). Hermes interpolates `${env:YAZIO_USERNAME}` / `${env:YAZIO_PASSWORD}` into the MCP env. No live env file.
- **Do not** `npx -y yazio-mcp` and do not auto-update — re-audit any new version

## Auth

Email + Yazio password only. Apple/Google-only accounts need a Yazio password first, or use `yazio-cli` cookie login (not wired).

Never print the password, token, or env file contents.

## Tools (`mcp__yazio__*`)

Read: `get_user`, `get_user_daily_summary`, `get_user_consumed_items`, `get_user_weight`, `get_user_exercises`, `get_user_water_intake`,
`get_user_goals`, `get_user_settings`, `get_user_dietary_preferences`, `get_user_suggested_products`, `search_products`, `get_product`

Write (ask first): `add_user_consumed_item`, `remove_user_consumed_item`, `add_user_water_intake`

Dates: MCP `add_user_consumed_item` takes `YYYY-MM-DD` only. The API stores `00:00:00`. Yazio app often hides midnight lunch/dinner (looks « not logged »). After every write: `get_user_consumed_items` and check the `date` time. If `00:00:00`, recast to Europe/Paris meal time before telling the user it is logged: breakfast 08:00, lunch 13:00, dinner 20:00, snack = now. MCP cannot set time; POST `/user/consumed-items` with `date: "YYYY-MM-DD HH:mm:ss"` (same pattern as water). Never print credentials. Product nutrients are **per gram**; `simple_products` nutrients are absolute.

## Smoke

```bash
hermes mcp test yazio
```

If auth fails: `hermes secrets bitwarden sync` must list `YAZIO_USERNAME` / `YAZIO_PASSWORD`, then reload MCP. Do not recreate a plaintext env file.

## Pitfalls

- API can return `version_blocked` or 401 after a Yazio change. If every authenticated endpoint returns 401 while OAuth still initializes, inspect the bundle's base URL: `yazio-mcp 0.0.14` embeds `https://yzapi.yazio.com/v15` (2 occurrences in `dist/index.js`); Yazio has been migrating to `/v20`. Still working on `/v15` as of 2026-09-19. Updating the file does not affect an already-running MCP process; reload/restart the server before retesting.
- Water intake is **cumulative ml**, not a delta
- `itemId` to delete ≠ `product_id`
- MCP add with date-only = midnight. The raw API timestamp may be `00:00:00` while Yazio still displays the entry correctly under its `daytime` category. Do not infer invisibility from timestamp alone. Recast to lunch 13:00 / dinner 20:00 only if the user reports it missing in the app; otherwise verify entry presence and `daytime` before saying « logué ».
- `steps=0`, `goals.activity.step=10000`, `user.goal=build_muscle`, poids cible 63 kg : bruit Fluide. Pas déclarés = **12 000 / j**. Phase déclarée prime. Jamais « non sync ».
- Mid-session reload: CLI `/reload-mcp`; Desktop → Capabilities → MCP → toggle the server (slash is hidden).
