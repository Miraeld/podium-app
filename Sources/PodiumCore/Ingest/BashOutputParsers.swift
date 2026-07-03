// BashOutputParsers.swift — port of hooks.js's structured Bash-output
// parsers (lines 16–130): parsePhpUnit, parsePhpcs, extractPrUrl,
// parseGitStat. Pure functions, no DB/broadcast side effects, so they're
// trivially unit-testable in isolation.

import Foundation

public enum BashOutputParsers {
    public struct PhpUnitResult: Equatable, Sendable {
        public let tests: Int
        public let assertions: Int
        public let failures: Int
        public let errors: Int
        public let passed: Bool
    }

    /// Matches "OK (47 tests, 123 assertions)" or
    /// "Tests: 47, Assertions: 123, Failures: 2, Errors: 1".
    public static func parsePhpUnit(_ output: String?) -> PhpUnitResult? {
        guard let output, !output.isEmpty else { return nil }
        let matcher = RegexMatcher(source: output)

        if let match = matcher.firstMatch(#"OK\s*\(\s*(\d+)\s*tests?,\s*(\d+)\s*assertions?\s*\)"#, caseInsensitive: true) {
            let tests = match.intGroup(1) ?? 0
            let assertions = match.intGroup(2) ?? 0
            return PhpUnitResult(tests: tests, assertions: assertions, failures: 0, errors: 0, passed: true)
        }

        if let summaryMatch = matcher.firstMatch(#"Tests:\s*(\d+)"#, caseInsensitive: true) {
            let tests = summaryMatch.intGroup(1) ?? 0
            let assertions = matcher.firstMatch(#"Assertions:\s*(\d+)"#, caseInsensitive: true)?.intGroup(1) ?? 0
            let failures = matcher.firstMatch(#"Failures:\s*(\d+)"#, caseInsensitive: true)?.intGroup(1) ?? 0
            let errors = matcher.firstMatch(#"Errors:\s*(\d+)"#, caseInsensitive: true)?.intGroup(1) ?? 0
            return PhpUnitResult(tests: tests, assertions: assertions, failures: failures, errors: errors, passed: failures == 0 && errors == 0)
        }

        return nil
    }

    public struct PhpcsResult: Equatable, Sendable {
        public let errors: Int
        public let warnings: Int
    }

    /// Matches "FOUND N ERRORS AND N WARNINGS AFFECTING N LINES",
    /// "FOUND N ERRORS AFFECTING N LINES", or "No errors detected".
    public static func parsePhpcs(_ output: String?) -> PhpcsResult? {
        guard let output, !output.isEmpty else { return nil }
        let matcher = RegexMatcher(source: output)

        if let match = matcher.firstMatch(#"FOUND\s+(\d+)\s+ERRORS?\s+AND\s+(\d+)\s+WARNINGS?"#, caseInsensitive: true) {
            return PhpcsResult(errors: match.intGroup(1) ?? 0, warnings: match.intGroup(2) ?? 0)
        }
        if let match = matcher.firstMatch(#"FOUND\s+(\d+)\s+ERRORS?\s+AFFECTING"#, caseInsensitive: true) {
            return PhpcsResult(errors: match.intGroup(1) ?? 0, warnings: 0)
        }
        if matcher.firstMatch(#"no (errors?|violations?)\s+(detected|found)"#, caseInsensitive: true) != nil {
            return PhpcsResult(errors: 0, warnings: 0)
        }
        return nil
    }

    /// First GitHub PR URL found anywhere in `output`, or `nil`.
    public static func extractPrUrl(_ output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        let matcher = RegexMatcher(source: output)
        return matcher.firstMatch(#"https://github\.com/[^\s/]+/[^\s/]+/pull/\d+"#, caseInsensitive: false)?.fullMatch
    }

    public struct GitStatResult: Equatable, Sendable {
        public let filesChanged: Int
        public let insertions: Int
        public let deletions: Int
    }

    /// Matches a `git diff --stat` summary line anywhere in `output`:
    /// "N files changed, N insertions(+), N deletions(-)".
    public static func parseGitStat(_ output: String?) -> GitStatResult? {
        guard let output, !output.isEmpty else { return nil }
        let matcher = RegexMatcher(source: output)
        let pattern = #"(\d+)\s+files?\s+changed(?:,\s*(\d+)\s+insertions?\(\+\))?(?:,\s*(\d+)\s+deletions?\(-\))?"#
        guard let match = matcher.firstMatch(pattern, caseInsensitive: false) else { return nil }
        return GitStatResult(
            filesChanged: match.intGroup(1) ?? 0,
            insertions: match.intGroup(2) ?? 0,
            deletions: match.intGroup(3) ?? 0
        )
    }
}

/// Small helper bundling an `NSRegularExpression` match with the source
/// string it matched against, so callers can pull out numbered capture
/// groups without re-threading the source text through every call site.
private struct RegexMatcher {
    let source: String

    func firstMatch(_ pattern: String, caseInsensitive: Bool) -> Match? {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let result = regex.firstMatch(in: source, options: [], range: range) else { return nil }
        return Match(source: source, result: result)
    }
}

private struct Match {
    let source: String
    let result: NSTextCheckingResult

    var fullMatch: String? { group(0) }

    func intGroup(_ index: Int) -> Int? {
        group(index).flatMap { Int($0) }
    }

    func group(_ index: Int) -> String? {
        guard index < result.numberOfRanges else { return nil }
        let range = result.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else { return nil }
        return String(source[swiftRange])
    }
}
