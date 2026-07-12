# N5-A Spike: `bun build --compile` single-file binary for the Node server

## Verdict

**YES — works cleanly.** Winning approach is **(b) a thin `bun:sqlite` adapter**
behind the same interface `db.js` already expects (better-sqlite3-shaped:
`.prepare().get()/.all()/.run()`, `.exec()`, `.pragma()`, `.transaction()`).
No changes to any SQL, schema, or route code were needed — only the sqlite
backend-selection shim at the top of `db.js` plus one new adapter file.

Approach (a) — fixing the existing `node:sqlite` compat path — is a dead end
under bun: **bun 1.3.14 does not implement `node:sqlite` at all** (`error: No
such built-in module: node:sqlite`, confirmed both under `bun run` and inside
the compiled binary). This isn't a compile-time-only gap; it's absent at
runtime too. (Earlier belief that bun 1.2+ ships `node:sqlite` was wrong for
1.3.14 — worth flagging if that assumption shows up elsewhere in planning.)

Approach (c) — embedding better-sqlite3's native `.node` addon — was not
pursued to completion because it's blocked upstream of bun: on this machine
(Node 26.3.0 toolchain), `better-sqlite3@11.10.0` has no prebuilt binary for
`node-v137-darwin-arm64` and the source build fails against newer V8 headers
(`no member named 'GetPrototype' in 'v8::Object'`, `no member named
'GetIsolate' in 'v8::Context'` — V8 API removed in newer versions). This
reproduces with a plain `bun install` (no `--omit=optional`) and confirms the
compat-layer fallback is necessary regardless of bun; it is not a
bun-specific problem. Not worth chasing further since (b) already works.

## Patches required (unified diffs, relative to repo's `server/`)

### 1. New file: `server/compat-bunsqlite.js`

```diff
--- /dev/null
+++ b/server/compat-bunsqlite.js
@@
+/**
+ * Compatibility wrapper around bun:sqlite so the rest of the codebase
+ * (written against the better-sqlite3 API) works unmodified when running
+ * under a `bun build --compile` binary or `bun run`.
+ *
+ * bun:sqlite's Database/Statement already implement .prepare/.get/.all/.run/
+ * .exec/.transaction with better-sqlite3-compatible signatures. The only gap
+ * is `.pragma(str, options)`, which better-sqlite3 exposes but bun:sqlite
+ * does not — implemented here on top of .exec/.prepare, mirroring
+ * compat-sqlite.js's node:sqlite shim.
+ */
+
+const { Database: BunDatabase } = require("bun:sqlite");
+
+class Database extends BunDatabase {
+  pragma(str, options) {
+    if (str.includes("=")) {
+      this.exec(`PRAGMA ${str}`);
+      return undefined;
+    }
+    const row = this.prepare(`PRAGMA ${str}`).get();
+    if (!row) return undefined;
+    const keys = Object.keys(row);
+    if (options?.simple || keys.length === 1) return row[keys[0]];
+    return row;
+  }
+}
+
+module.exports = Database;
```

### 2. `server/db.js` — try the bun adapter between better-sqlite3 and node:sqlite

```diff
--- a/db.js
+++ b/db.js
@@
 let Database;
 try {
   Database = require("better-sqlite3");
 } catch {
   try {
-    Database = require("./compat-sqlite");
+    Database = require("./compat-bunsqlite");
   } catch {
-    console.error(
-      "\n" + ...
-    );
-    process.exit(1);
+    try {
+      Database = require("./compat-sqlite");
+    } catch {
+      console.error(
+        "\n" + ...
+      );
+      process.exit(1);
+    }
   }
 }
```

(Full patched block is a straightforward one-level-deeper nested try/catch;
see `$SCRATCHPAD/spike-server/db.js` lines 1-33 for the exact result.)

### 3. `lib/redoc.js` — already-known bundler patch (from earlier spike step, unrelated to sqlite)

```diff
--- a/lib/redoc.js
+++ b/lib/redoc.js
@@
-const redocPath = require.resolve("redoc/bundles/redoc.standalone.js");
+const redocPath = require.resolve(["redoc", "bundles", "redoc.standalone.js"].join("/"));
```

Needed because the redoc UMD bundle contains a literal `require("null")` that
breaks bun's bundler when `require.resolve` is called with a static string
bun tries to pre-resolve; making the argument computed dodges it.

That's the complete patch set — 1 new file, 2 small edits, no SQL/schema/route changes.

## Build

```
cd server/
bun install --omit=optional      # or a full install; see note below on approach (c)
bun build --compile index.js --outfile podium-server
```

- Binary size: **~61 MiB** (64,171,234 bytes), arm64 Mach-O, 319 bundled modules.
- Compile time: ~80-140ms (bundle) + ~80ms (compile) on this machine — fast.
- No difference in binary size whether or not better-sqlite3 is present in
  node_modules (it's `require()`d dynamically inside a try/catch, bun leaves
  it as a runtime lookup rather than statically bundling a missing package).

## Verification (end-to-end)

Boot:
```
$ DASHBOARD_PORT=4899 DASHBOARD_DATA_DIR=$SCRATCHPAD/spike-data ./podium-server-spike
Claude Code hooks auto-configured.
Agent Dashboard server running on http://localhost:4899 (development)
Client dev server expected at http://localhost:5173
```
No sqlite error banner — boots clean. (First boot also exercised the
existing `migrateLegacyDatabase` non-destructive VACUUM INTO path against a
real `~/Library/Application Support/Podium` DB found via legacy-path
discovery, since `spike-data` started empty — a nice bonus proof the
bun:sqlite adapter also handles `VACUUM INTO`, ATTACH-less multi-db access,
and large real data: 57 MB / 67 sessions / 16.7k events loaded and queried
fine.)

Endpoint checks:

| Endpoint | Result |
|---|---|
| `GET /api/health` | `200 {"status":"ok","timestamp":"..."}` |
| `GET /api/stats` | `200` — real aggregate counts (`total_sessions:67, total_events:16717, ...`) |
| `POST /api/hooks/event` (`SessionStart`, fresh `session_id`) | `200 {"ok":true,"event":{...}}` — event object returned with generated `agent_id` |
| `GET /api/sessions?limit=5` | `200` — includes the just-created session's ancestor set, full JSON shape matches client `types.ts` fields (`id, name, status, cwd, model, started_at, ended_at, metadata, updated_at, transcript_path, agent_count, last_activity, cost`) |
| `GET /api/docs` | `301` → `/api/docs/` (normal express redirect, not a crash) |
| `GET /api/docs/` | `200`, 3120 bytes, real swagger-ui HTML |
| `GET /api/docs/swagger-ui.css`, `swagger-ui-bundle.js` | `200` — static assets served fine from inside the compiled binary |
| `GET /api/redoc` | `200`, real redoc HTML shell |
| `GET /api/redoc/redoc.standalone.js` | `200`, 1,097,271 bytes — the full redoc bundle serves correctly from the compiled binary |

No 500s, no crashes anywhere, including the doc/redoc asset paths that were
the main worry from the earlier bundler patch.

Process cleanup: server killed after verification, `lsof -ti:4899` confirmed
empty, no orphans left.

## Approach (d): does it still work with better-sqlite3 actually installed?

Ran `bun install` (no `--omit=optional`) in a fresh copy
(`$SCRATCHPAD/spike-server-full`, deleted after the test). Result:
**better-sqlite3 fails to install on this machine** — not a bun issue:

```
prebuild-install warn install No prebuilt binaries found (target=26.3.0 runtime=node arch=arm64 libc= platform=darwin)
...
./src/util/binder.lzz:40:37: error: no member named 'GetPrototype' in 'v8::Object'
./src/better_sqlite3.lzz:68:34: error: no member named 'GetIsolate' in 'v8::Context'
```

better-sqlite3@11.10.0's native addon doesn't build against the Node 26 /
newer-V8 headers present on this box, and no prebuilt binary exists for that
ABI yet. `bun install` silently drops the optional dep after the postinstall
build script fails (final `node_modules` has no `better-sqlite3` directory at
all), so `require("better-sqlite3")` throws `MODULE_NOT_FOUND` the same way
it does with `--omit=optional` — the fallback chain in `db.js` (patch #2
above) engages identically either way. **This means the bun:sqlite adapter
isn't just a workaround for the spike's `--omit=optional` snapshot — it's
currently the only sqlite backend that reliably works at all on this Node
version**, independent of bun. Did not pursue embedding a prebuilt `.node`
addon manually (approach c) since (b) already fully satisfies the goal and
this failure is upstream/unrelated to bun.

## Caveats for real N5-A implementation

1. **`node:sqlite` is unusable under bun 1.3.14** — don't rely on it as a
   fallback tier in the real implementation; `bun:sqlite` is the only sqlite
   path that works inside a bun-compiled binary today. Keep the existing
   `compat-sqlite.js` (node:sqlite) file only for the *non-bun* (plain
   Node ≥22) runtime path — it's still valid there, just never reached when
   running under bun.
2. **`lib/redoc.js`'s `require.resolve` patch is required** for `bun build
   --compile` to succeed at all (unrelated to sqlite) — must ship alongside
   the sqlite patch.
3. **Optional-dep story needs a decision**: since better-sqlite3 currently
   fails to build/install in this environment (Node 26 + no prebuilt
   binary), the real implementation should probably treat bun:sqlite as the
   primary backend when running the compiled binary, not merely a fallback,
   and only try better-sqlite3 first for parity with the existing `npm
   start`/dev flow on machines where it does build.
4. `/api/docs` and `/api/redoc` (including the large redoc.standalone.js and
   swagger-ui static assets) work fine from inside the compiled binary with
   no extra bundler config beyond the existing redoc.js patch — no caveat
   needed here, contrary to the original worry.
5. Binary is architecture/OS-specific (this was an arm64 macOS Mach-O
   build) — cross-compiling for Linux targets wasn't tested in this spike
   and should be checked separately before N5-A ships.

## Files

- Patched snapshot (compiles + boots + verified): `$SCRATCHPAD/spike-server/`
  - `$SCRATCHPAD/spike-server/compat-bunsqlite.js` (new)
  - `$SCRATCHPAD/spike-server/db.js` (patched require chain)
  - `$SCRATCHPAD/spike-server/lib/redoc.js` (pre-existing patch from earlier spike step)
  - `$SCRATCHPAD/spike-server/podium-server-spike` (compiled binary, 61 MiB)
- Boot logs: `$SCRATCHPAD/spike-boot.log` (original failing boot),
  `$SCRATCHPAD/spike-boot2.log` (working boot after patch)
