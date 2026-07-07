# Migrating from the plugin-era (Node/Docker) Podium

If you're running the old Node/Docker Podium plugin today, your data carries
over as-is. This is the recommended switchover path — copy first, verify, then
retire the old container.

## Where your data lives today

The plugin-era dashboard stores everything in one SQLite file:

```
~/.claude/podium/data/dashboard.db
```

bind-mounted into the Docker container. That file is the single source of
truth — sessions, agents, events, transcript metadata, pricing, settings.

## Where the standalone app looks for data

Resolution order (`Sources/PodiumCore/Database/PodiumPaths.swift`):

1. `DASHBOARD_DB_PATH` env var — exact file path override.
2. `DASHBOARD_DATA_DIR` env var — directory; app uses `<dir>/dashboard.db`.
3. Platform default data directory:
   - macOS: `~/Library/Application Support/Podium`
   - Linux: `$XDG_DATA_HOME/podium`, else `~/.local/share/podium`

The native app and `podium-server` use the same resolution, so no `--data-dir`
flag is needed for normal use.

## Recommended switchover (copy-first, safe)

1. **Stop the Docker container.** Don't delete it yet.
   ```bash
   docker stop <podium-container-name>
   ```
2. **Copy (not move) the database** into the app's data dir:
   ```bash
   mkdir -p ~/Library/Application\ Support/Podium
   cp ~/.claude/podium/data/dashboard.db ~/Library/Application\ Support/Podium/dashboard.db
   ```
   Copying keeps the original file untouched in case anything looks wrong.
3. **Launch the Podium app** (macOS or Linux — see the README for install +
   the one-time macOS Gatekeeper step). It reads the copied `dashboard.db`
   directly — no import step, no schema migration needed (same schema, ported
   1:1). Headless Linux server hosts can run `podium-server` directly instead.
4. **Verify.** Open the dashboard, confirm your session history, costs, and
   recent agents look right.
5. **Only then retire the container** (`docker rm <podium-container-name>`) and
   remove the old bind-mount if you want to reclaim disk space.

If anything looks wrong at step 4, the original `dashboard.db` under
`~/.claude/podium/data/` is untouched — restart the Docker container and
you're back to where you started.

## Hooks

The plugin registered its hook command in `~/.claude/settings.json` pointing at
`hook.mjs` (Node). The standalone app's `HookInstaller`
(`Sources/PodiumCore/Hooks/HookInstaller.swift`) detects and removes those
legacy entries — `.claude/podium/hook.mjs`, `plugins/cache/wp-media/podium`,
`hook-handler.js`, `podium/dashboard/scripts` — and installs its own entry
pointing at the native `podium-hook` binary. This happens automatically on
first launch; no manual edit of `settings.json` is needed.
