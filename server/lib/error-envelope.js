/**
 * @file P5 (ROADMAP §2, ported from Sources/PodiumServer/APIErrorEnvelopeMiddleware.swift):
 * a uniform error envelope — `{"error":{"code","message"}}` — on every
 * `/api/*` failure path, including the two gaps individual route handlers
 * don't cover themselves:
 *
 *   1. No route matches at all (unknown `/api/*` path) — Express's default
 *      404 is a plain-text "Cannot GET /api/whatever", not JSON.
 *   2. A handler throws (sync) or calls `next(err)` without its own
 *      try/catch — Express's default error page is an HTML stack trace.
 *
 * Route handlers that already produce deliberate 4xx/5xx JSON bodies
 * (`{"error":{"code","message"}}`, the documented shape) are unaffected —
 * these two middlewares only fire when nothing upstream already responded.
 */

/** Mount as `app.use("/api", apiNotFoundHandler)` AFTER every real route. */
function apiNotFoundHandler(req, res, _next) {
  res.status(404).json({
    error: { code: "NOT_FOUND", message: `No route for ${req.method} ${req.originalUrl}` },
  });
}

/**
 * Mount as `app.use("/api", apiErrorHandler)` — Express only recognizes an
 * error-handling middleware when it declares exactly 4 parameters, so `next`
 * must stay even though it's unused here.
 */
// eslint-disable-next-line no-unused-vars
function apiErrorHandler(err, req, res, next) {
  if (res.headersSent) {
    // Response already started streaming (e.g. partial SSE/file) — delegate
    // to Express's default handler, which will close the connection.
    return next(err);
  }
  const status = Number.isInteger(err?.status) ? err.status : Number.isInteger(err?.statusCode) ? err.statusCode : 500;
  const code = err?.code && typeof err.code === "string" ? err.code : status === 500 ? "INTERNAL" : `HTTP_${status}`;
  res.status(status).json({
    error: { code, message: err?.message || "Internal server error" },
  });
}

module.exports = { apiNotFoundHandler, apiErrorHandler };
