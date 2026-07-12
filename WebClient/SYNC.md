# WebClient/dist — vendored web dashboard

`WebClient/dist/` is a **built, vendored copy** of the React 18 + Vite + Tailwind
dashboard client from the Podium Node.js project
(`/Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/client`).

`PodiumServer` serves this directory as static assets (SPA, cache policy
matching `dashboard/server/index.js` lines 118–142). Do **not** vendor
`node_modules/` or the client's TypeScript/JSX sources — only the built
`dist/` output.

## Provenance

Copied on 2026-07-03 (package restructure, task P0.1) from a dist/ that was
already built and fresh at that time (`vite build` output, `package.json`
version `1.4.0`). No client source changes were made — this is a pure vendor
copy.

## How to rebuild + re-sync

Run these commands whenever the Node reference app's dashboard client
changes and you need to refresh the vendored copy:

```bash
# 1. Build the client from the reference (read-only) repo
cd /Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/client
npm install
PODIUM_APP_VERSION=<the release version, e.g. 0.5.3> npm run build   # runs `tsc -b && vite build`, outputs dist/

# 2. Copy the built assets into this repo (replace, don't merge)
rm -rf /Users/gaelrobin/Desktop/PodiumSwiftApp/WebClient/dist
cp -R /Users/gaelrobin/Desktop/Work/Claude/podium/dashboard/client/dist \
      /Users/gaelrobin/Desktop/PodiumSwiftApp/WebClient/dist

# 3. Verify PodiumServer still serves it correctly
cd /Users/gaelrobin/Desktop/PodiumSwiftApp
swift build --product podium-server
# then boot the server and hit http://localhost:<port>/ to sanity check
```

**`PODIUM_APP_VERSION` is mandatory for `npm run build`.** PRE-1.0 audit D1:
`vite.config.ts` used to silently fall back to the legacy
`.claude-plugin/plugin.json` version when the env var was unset — this
shipped a stale sidebar version (`v1.4.0`) TWICE. There is no fallback
anymore: `npm run build` without `PODIUM_APP_VERSION` set now throws and
fails the build outright. Always set it explicitly to the version you're
releasing before building/re-vendoring.

If `dist/` doesn't exist yet or is stale (i.e. files under `src/` are newer
than `dist/index.html`), you MUST run `npm install && npm run build` first —
never hand-copy a stale `dist/`.

## What NOT to vendor

- `node_modules/`
- `src/`, `index.html` (source), `vite.config.ts`, `tailwind.config.js`, etc.
- `package.json` / `package-lock.json`
- Any dev/test artifacts (`vitest.config.ts`, `tsconfig.tsbuildinfo`)

Only the contents of the built `dist/` directory belong in this repo.
