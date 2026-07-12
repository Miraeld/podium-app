# Upstream provenance

This `server/` directory is vendored from:

- **Repository:** https://github.com/hoangsonww/Claude-Code-Agent-Monitor
- **Upstream commit SHA:** `f8b52a81db3f689460b9a5fda9b2048847298593` (default
  branch, fetched 2026-07-12)
- **Upstream subdirectory:** `server/` (the whole monorepo's Node server)
- **License:** MIT — see `server/LICENSE-upstream` (copied verbatim from the
  upstream repo root `LICENSE`). Copyright (c) 2026 - Now, Son Nguyen.

Per the MIT license, this notice + the upstream LICENSE file must be retained
alongside any substantial portion of the vendored code. See also
`ROADMAP.md` §0 (the Node-pivot decision) and `PRE-1.0-AUDIT.md` P10 (root
LICENSE/README must carry the same attribution).

## What was copied, and what changed to make it boot standalone

Upstream is a single monorepo with **one root `package.json`** (no per-package
`server/package.json`) and `server/*.js` referencing sibling directories via
relative paths (`../scripts/...`, `../package.json`). Since only `server/` is
vendored into this repo (not the whole monorepo), those relative paths would
break. Fixes applied, scoped strictly to "what's needed to boot":

1. **`server/package.json` (new, not upstream)** — a minimal manifest scoped
   to the dependencies `server/*.js` actually `require()`s (checked via
   grep across `server/`): `adm-zip`, `cors`, `express`, `multer`, `redoc`,
   `swagger-ui-express`, `tar`, `uuid`, `web-push`, `ws`, plus optional
   `better-sqlite3` (falls back to Node's built-in `node:sqlite` via
   `compat-sqlite.js` if the native build fails — see `server/db.js`).
   Versions pinned to match upstream's root `package-lock.json` at the vendored
   commit. `npm install` (no upstream lockfile scoped to `server/` alone, so
   `npm ci` was not applicable) — this generates a new `server/package-lock.json`.

2. **`server/scripts/` (new)** — two files copied from upstream's top-level
   `scripts/` because `server/routes/hooks.js` and `server/lib/session-liveness.js`
   require them at module-load time (not lazily), so the server cannot even
   `require("./routes/hooks")` without them:
   - `scripts/import-history.js`
   - `scripts/install-hooks.js`

   Upstream's `scripts/hook-handler.js` (the CLI invoked by the Claude Code
   hook itself) was deliberately **not** vendored — it's a separate concern
   (ROADMAP N5, the hook client) and nothing in `server/`'s boot path requires
   it. `server/__tests__/hook-handler.test.js` will fail to resolve that path
   until N5 lands; left as-is rather than deleted.

3. **Require-path patches** (sed, mechanical, no logic changes):
   - `server/index.js`: `require("../scripts/X")` → `require("./scripts/X")`
   - `server/routes/{hooks,import,settings}.js`,
     `server/lib/{session-liveness,workflow-ingest}.js`:
     `require("../../scripts/X")` → `require("../scripts/X")`
   - `server/scripts/{import-history,install-hooks}.js`:
     `require("../server/X")` → `require("../X")` (scripts now live one level
     under `server/`, not as a sibling of it)
   - `server/openapi.js`: `require("../package.json")` → `require("./package.json")`
     (reads `name`/`version` for the OpenAPI doc info block)
   - Ten `server/__tests__/*.test.js` files had the same
     `../../scripts/` → `../scripts/` fix applied so they resolve correctly
     (not run as part of this task — N4 ports/adapts the contract-test
     equivalent; these are upstream's own unit tests, left green-or-not for
     N3/N4 to assess).

No other logic was touched. `node_modules` was excluded per the task.

## Boot verification

```
DASHBOARD_PORT=4899 DASHBOARD_DATA_DIR=<scratch dir> NODE_ENV=development \
  node server/index.js
```

Result: `Agent Dashboard server running on http://localhost:4899
(development)`. Confirmed via curl:
- `GET /api/health` → `{"status":"ok","timestamp":"..."}`
- `GET /api/sessions` → real session list (auto-imported from
  `~/.claude/projects/**` on first boot per upstream's
  `autoImportLegacySessions()` — this reads the real Claude Code history
  directory regardless of `DASHBOARD_DATA_DIR`, which only controls where the
  SQLite DB file itself lives; expected upstream behavior, not a bug)
- `GET /api/openapi.json` → valid OpenAPI 3.0.3 document

`better-sqlite3` built successfully via `npm install` (Node v26.3.0 locally);
the `node:sqlite` fallback path (`compat-sqlite.js`) was not exercised here
but exists for environments where the native build fails.
