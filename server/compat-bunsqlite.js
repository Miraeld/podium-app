/**
 * @file compat-bunsqlite.js
 * @description Compatibility wrapper around `bun:sqlite` so the rest of the
 * codebase (written against the better-sqlite3 API) works unmodified when
 * running under `bun run` or a `bun build --compile` binary (ROADMAP N5
 * TASK A — the Tauri sidecar).
 *
 * `bun:sqlite`'s `Database`/`Statement` already implement
 * `.prepare()/.get()/.all()/.run()`, `.exec()`, and `.transaction()` with
 * better-sqlite3-compatible signatures. The only gap is `.pragma(str,
 * options)`, which better-sqlite3 exposes but `bun:sqlite` does not —
 * implemented here on top of `.exec()`/`.prepare()`, mirroring
 * `compat-sqlite.js`'s `node:sqlite` shim.
 *
 * This module is only ever `require()`d from the middle `catch` in `db.js`'s
 * fallback chain (better-sqlite3 → bun:sqlite → node:sqlite), so it is never
 * loaded — and `require("bun:sqlite")` never attempted — under plain Node.
 *
 * @author Podium (Node-pivot N5)
 */

const { Database: BunDatabase } = require("bun:sqlite");

class Database extends BunDatabase {
  pragma(str, options) {
    if (str.includes("=")) {
      this.exec(`PRAGMA ${str}`);
      return undefined;
    }
    const row = this.prepare(`PRAGMA ${str}`).get();
    if (!row) return undefined;
    const keys = Object.keys(row);
    if (options?.simple || keys.length === 1) return row[keys[0]];
    return row;
  }
}

module.exports = Database;
