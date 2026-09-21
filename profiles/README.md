# Agent profiles

One directory per Hermes profile, installed by `sudo ./profiles.sh install` (see the main README,
"Agent profiles as code"). Inventory and the security decisions behind it, 2026-09-19:

| Profile | Role | Hub / official skills (vendored, `skills/.hub/lock.json`) | Local skills | Plugins |
|---|---|---|---|---|
| `chief` | orchestrator: routing, kanban dependencies, follow-up | `grilling` (mattpocock), `grill-me` (official 2.0 — already embeds grilling's frontier rounds), `one-three-one-rule` (official, decision briefs) | `weekly-review-planning`, `sdlc-review` (bundled: reviews kanban handoffs) | — |
| `engineer` | Astro / TypeScript / Cloudflare / APIs / WordPress migrations | mattpocock: `grilling`, `domain-modeling`, `grill-with-docs`, `codebase-design`, `improve-codebase-architecture`, `wayfinder`, `wizard` · cloudflare: `wrangler`, `workers-best-practices` · vercel-labs: `web-design-guidelines` · official: `rest-graphql-debug` | `cloudflare` (see below), `github`, `systematic-debugging`, `test-driven-development`, `requesting-code-review`, bundled copies `claude-code`, `codex` (delegation to the CLIs in the image), `obsidian`, `blocked-page-recovery` | `superpowers` 6.4.1 (`plugins.txt`, pinned) |
| `seo` | SEO audits, content, programmatic SEO, schema, copywriting | coreyhaines31/marketingskills: `seo-audit`, `content-strategy`, `programmatic-seo`, `schema` (ex `schema-markup`), `copywriting` | `ai-seo` (same repo, see below), `google-workspace`, `grounded-citations`, bundled copies `obsidian`, `blocked-page-recovery` | — |
| `researcher` | research and monitoring | `deep-research` (bytedance/deer-flow) · official: `watchers` (RSS/JSON/GitHub polling with watermark dedup, for paused crons), `rss-feeds` | `arxiv`, `competitor-news-monitor`, `grounded-citations`, bundled copies `obsidian`, `blocked-page-recovery` | — |
| `health` | personal nutrition / fitness (private) | `fitness-nutrition` (official) | `hevy`, `yazio`, `renpho` (MCP wrappers), `meal-macro-estimator` (photo → macros; local Ciqual 2020 base, `--usda` needs `USDA_FDC_API_KEY`), `systeme-fluide`, `xlsx`, bundled copy `obsidian` | — (`setup.sh` builds the MCP servers) |
| `markets` | crypto research, paper trading only | `solana`, `evm`, `stocks` (Yahoo quotes/history, crypto too), `reddit-reading` (public Atom feeds) — all official, read-only, stdlib, no keys | `grounded-citations`, `xlsx`, bundled copies `obsidian`, `blocked-page-recovery` | — |

Not installed on purpose: anything that signs, swaps or transfers (markets); `pulse` (researcher);
`web-perf` (engineer — needs a Chrome DevTools MCP: `hermes -p engineer skills install
skills-sh/cloudflare/skills/web-perf` once one is configured); Matt Pocock's `tdd`,
`diagnosing-bugs`, `code-review` (covered by Superpowers); wayfinder's `research` / `prototype` /
`setup-matt-pocock-skills` (no issue tracker is configured — wayfinder is explicit-invocation only
and Kanban stays the source of truth).

Bundled skills (the image's `/opt/hermes/skills`, refused wholesale by `.no-bundled-skills`) are
copied in one by one as local skills where a profile needs them — the hub only offers community
mirrors of them; `obsidian` everywhere handoffs go to the vault (`OBSIDIAN_VAULT_PATH` is in the
container env). Skipped for missing runtime deps (no lazy installs in the image): `youtube-content`
(yt-dlp), `pdf`/`docx` (pypdf…), `codebase-inspection` (pygount), `ast-grep`.

## Skills that needed a decision

- **`superpowers` (engineer, plugin)** — scanner verdict CAUTION (229 findings, all in `docs/`,
  `tests/` and one prose line of `systematic-debugging/SKILL.md`). Installed with `--force` after
  reading `.hermes-plugin/__init__.py` (registers the skills, injects the bootstrap on the first
  turn; no network, no exec). Pinned to commit `5bf4e78` in `plugins.txt`; re-review before moving it.
  Overlap: the local `systematic-debugging` / `test-driven-development` / `requesting-code-review`
  skills duplicate `superpowers:*` — kept on purpose, remove them if Superpowers alone is wanted.
- **`cloudflare` (engineer, local)** — the hub refuses it (Hermes 0.21.3 rejects any SKILL.md with a
  `../` link and reports "files no longer exist upstream"); scanned by hand at
  `cloudflare/skills@b052c32b` → DANGEROUS on documentation only (`curl -H "Authorization: Bearer
  $CLOUDFLARE_API_TOKEN"` examples, `cloudflared tunnel` docs, a `'your-turn-key-secret'`
  placeholder in `references/*.md`). Validated by the operator on 2026-09-19 and vendored as a
  local skill (289 reference files: D1, KV, R2, Durable Objects, Queues, Workflows…).
- **`ai-seo` (seo, local)** — same hub `../` refusal; scanned SAFE at `marketingskills@5b2c0007`,
  vendored as a local skill.
- **`rest-graphql-debug` (engineer)**, **`reddit-reading` (markets)** — scanner DANGEROUS, allowed by
  Hermes (official). Audited: the first is one SKILL.md whose only hosts are `api.example.com`
  placeholders; `reddit.py` talks to `www.reddit.com` / `oauth.reddit.com` only, optional app
  credentials from env. Kept.
- **`fitness-nutrition` (health)** — scanner says DANGEROUS (`api_key=${USDA_API_KEY}` in a curl
  line, `os.environ.get`), Hermes itself allows it (official source). Only endpoints: `wger.de`,
  `api.nal.usda.gov`. Works without a key (`DEMO_KEY`: 30 req/h, 50/day per IP); a free
  `USDA_API_KEY` in `data/profiles/health/.env` raises the limits.

## MCP servers (health)

`config.yaml` declares three stdio MCP servers; `setup.sh` builds them from `mcp/` in this
directory, so nothing is fetched from GitHub at install time and the exact dependency trees are
in git (lockfiles — `node_modules/` and `dist/` are build products, rebuilt only when the vendored
files change, `.built-from` stamp):

| Server | Source in repo | Runtime path (container) |
|---|---|---|
| `hevy` | `mcp/node/package.json` + `package-lock.json` → `hevy-mcp` 6.1.13 from npm | `mcp/node/node_modules/hevy-mcp/dist/cli.mjs` |
| `yazio` | same tree → `yazio-mcp` 0.0.14 from npm | `mcp/node/node_modules/yazio-mcp/dist/index.js` |
| `renpho` | `mcp/renpho-mcp-server/` — full source of StartupBros/renpho-mcp-server 1.2.0 (`69eb7aa`, MIT; unofficial Renpho API), `package-lock.json` generated for `npm ci` | `mcp/renpho-mcp-server/dist/index.js` (tsc) |

Smoke test: `hermes -p health mcp test renpho|hevy|yazio` (lists the tools). Only the npm registry
is needed to rebuild.

## Secrets

Never in this directory. Each profile's `.env` is user-owned (`profiles.sh` only generates a
missing `API_SERVER_KEY`); the keys a profile expects are declared in `distribution.yaml`
`env_requires` and Hermes writes them to `data/profiles/<name>/.env.EXAMPLE`. The health MCP
credentials (`HEVY_API_KEY`, `YAZIO_*`, `RENPHO_*`) come from Bitwarden Secrets Manager
(`BWS_ACCESS_TOKEN`) at runtime; markets holds no wallet or exchange key at all.
