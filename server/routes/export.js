/**
 * @file Express router for the session-export endpoint.
 * GET /api/export/session/:id — download a JSON bundle of a session with
 * all its agents, events, and token usage (the format POST
 * /api/import/session — see routes/import.js — accepts back in).
 *
 * ROADMAP N3 — MISSING per docs/N2-GAP.md; ported/adapted from the
 * plugin-era reference server (dashboard/server/routes/export.js) and
 * Sources/PodiumServer/Routes/ExportRouter.swift. Used by
 * client/src/pages/SessionDetail.tsx's export-current-session button.
 */

const { Router } = require("express");
const { buildBundle } = require("../lib/session-transfer");

const router = Router();

router.get("/session/:id", (req, res) => {
  const sessionId = req.params.id;
  const bundle = buildBundle(sessionId);
  if (!bundle) {
    return res.status(404).json({ error: { code: "NOT_FOUND", message: "Session not found" } });
  }

  const shortId = sessionId.slice(0, 8);
  res.setHeader("Content-Disposition", `attachment; filename="podium-session-${shortId}.json"`);
  res.setHeader("Content-Type", "application/json");
  res.json(bundle);
});

module.exports = router;
