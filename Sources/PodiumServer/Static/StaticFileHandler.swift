// StaticFileHandler — port of the static-serving block in
// dashboard/server/index.js lines 118–142.
//
// Not implemented via Hummingbird's built-in `FileMiddleware` because that
// middleware applies a single `CacheControl` policy to every file; the Node
// behavior varies the `Cache-Control` header per path:
//   - anything under /assets/            -> immutable, 1 year
//   - index.html, sw.js, manifest.json   -> no-cache, must-revalidate
//   - everything else under the dist dir -> public, max-age=300, must-revalidate
//   - any non-/api GET that doesn't match a file on disk (SPA routes)
//                                         -> serve index.html with no-cache
//
// Resolution order for the dist directory (this task's spec, not Node's):
//   env PODIUM_WEB_DIST > /usr/local/share/podium/web > <repo>/WebClient/dist
// exposed as a parameter with those defaults so callers/tests can override.

import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// Resolves the built web client's `dist/` directory.
public enum WebDistResolver {
    /// Resolve the dist directory: `PODIUM_WEB_DIST` env override, then the
    /// installed Linux layout, then a dev-relative path next to the running
    /// executable, then falling back to the given `fallback` (typically the
    /// repo's `WebClient/dist` when running from source).
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: String
    ) -> String {
        if let override = environment["PODIUM_WEB_DIST"], !override.isEmpty {
            return override
        }
        let installed = "/usr/local/share/podium/web"
        if FileManager.default.fileExists(atPath: installed) {
            return installed
        }
        return fallback
    }
}

/// Serves `WebClient/dist` with Node-parity cache headers, falling back to
/// `index.html` (SPA client-side routing) for any GET that isn't `/api/*`
/// and doesn't match a file on disk.
public struct StaticFileHandler<Context: RequestContext>: RouterMiddleware {
    public let distDirectory: String
    private let fileManager = FileManager.default

    public init(distDirectory: String) {
        self.distDirectory = distDirectory
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // Never intercept the API — only GET/HEAD for static assets & SPA fallback.
        let path = request.uri.path
        guard !path.hasPrefix("/api/") else {
            return try await next(request, context)
        }
        guard request.method == .get || request.method == .head else {
            return try await next(request, context)
        }

        if let response = try serveFile(forRequestPath: path) {
            return response
        }

        // SPA fallback: serve index.html for any other non-API GET (client-side router).
        if let indexResponse = try serveIndexHTML() {
            return indexResponse
        }

        return try await next(request, context)
    }

    // MARK: - File resolution

    private func serveFile(forRequestPath requestPath: String) throws -> Response? {
        guard requestPath != "/" else {
            return try serveIndexHTML()
        }
        let relative = String(requestPath.dropFirst()) // drop leading "/"
        guard !relative.isEmpty, !relative.contains("..") else { return nil }

        let fileURL = URL(fileURLWithPath: distDirectory).appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return nil
        }
        return try response(forFileAt: fileURL.path, requestPath: requestPath)
    }

    private func serveIndexHTML() throws -> Response? {
        let indexPath = URL(fileURLWithPath: distDirectory).appendingPathComponent("index.html").path
        guard fileManager.fileExists(atPath: indexPath) else { return nil }
        return try response(forFileAt: indexPath, requestPath: "/index.html")
    }

    private func response(forFileAt filePath: String, requestPath: String) throws -> Response {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        var headers = HTTPFields()
        headers[.contentType] = mediaType(forPath: filePath)
        headers[.cacheControl] = cacheControlValue(forPath: filePath)
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    // MARK: - Cache policy (index.js lines 122–136)

    /// Mirrors the Node `setHeaders` callback exactly:
    ///   - path contains "/assets/"                          -> immutable, 1yr
    ///   - basename is index.html / sw.js / manifest.json     -> no-cache, must-revalidate
    ///   - anything else                                       -> public, max-age=300, must-revalidate
    func cacheControlValue(forPath filePath: String) -> String {
        if filePath.contains("/assets/") {
            return "public, max-age=31536000, immutable"
        }
        let base = (filePath as NSString).lastPathComponent
        if base == "index.html" || base == "sw.js" || base == "manifest.json" {
            return "no-cache, must-revalidate"
        }
        return "public, max-age=300, must-revalidate"
    }

    // MARK: - Media type

    private static let extensionMediaTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "txt": "text/plain; charset=utf-8",
        "map": "application/json",
        "webmanifest": "application/manifest+json",
    ]

    private func mediaType(forPath filePath: String) -> String {
        let ext = (filePath as NSString).pathExtension.lowercased()
        return Self.extensionMediaTypes[ext] ?? "application/octet-stream"
    }
}
