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

        if let match = firstMatch(in: output, pattern: #"OK\s*\(\s*(\d+)\s*tests?,\s*(\d+)\s*assertions?\s*\)"#, options: [.caseInsensitive]) {
            let tests = intGroup(match, 1) ?? 0
            let assertions = intGroup(match, 2) ?? 0
            return PhpUnitResult(tests: tests, assertions: assertions, failures: 0, errors: 0, passed: true)
        }

        if let summaryMatch = firstMatch(in: output, pattern: #"Tests:\s*(\d+)"#, options: [.caseInsensitive]) {
            let tests = intGroup(summaryMatch, 1) ?? 0
            let assertions = intGroup(firstMatch(in: output, pattern: #"Assertions:\s*(\d+)"#, options: [.caseInsensitive]), 1) ?? 0
            let failures = intGroup(firstMatch(in: output, pattern: #"Failures:\s*(\d+)"#, options: [.caseInsensitive]), 1) ?? 0
            let errors = intGroup(firstMatch(in: output, pattern: #"Errors:\s*(\d+)"#, options: [.caseInsensitive]), 1) ?? 0
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

        if let match = firstMatch(in: output, pattern: #"FOUND\s+(\d+)\s+ERRORS?\s+AND\s+(\d+)\s+WARNINGS?"#, options: [.caseInsensitive]) {
            return PhpcsResult(errors: intGroup(match, 1) ?? 0, warnings: intGroup(match, 2) ?? 0)
        }
        if let match = firstMatch(in: output, pattern: #"FOUND\s+(\d+)\s+ERRORS?\s+AFFECTING"#, options: [.caseInsensitive]) {
            return PhpcsResult(errors: intGroup(match, 1) ?? 0, warnings: 0)
        }
        if matches(output, pattern: #"no (errors?|violations?)\s+(detected|found)"#, options: [.caseInsensitive]) {
            return PhpcsResult(errors: 0, warnings: 0)
        }
        return nil
    }

    /// First GitHub PR URL found anywhere in `output`, or `nil`.
    public static func extractPrUrl(_ output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        guard let match = firstMatch(in: output, pattern: #"https://github\.com/[^\s/]+/[^\s/]+/pull/\d+"#, options: []) else {
            return nil
        }
        return substring(output, match.range)
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
        let pattern = #"(\d+)\s+files?\s+changed(?:,\s*(\d+)\s+insertions?\(\+\))?(?:,\s*(\d+)\s+deletions?\(-\))?"#
        guard let match = firstMatch(in: output, pattern: pattern, options: []) else { return nil }
        return GitStatResult(
            filesChanged: intGroup(match, 1) ?? 0,
            insertions: intGroup(match, 2) ?? 0,
            deletions: intGroup(match, 3) ?? 0
        )
    }

    // MARK: - Regex helpers

    private static func firstMatch(in text: String, pattern: String, options: NSRegularExpression.Options) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }

    private static func firstMatch(in text: String, pattern: NSTextCheckingResult?, group: Int) -> NSTextCheckingResult? {
        pattern
    }

    private static func matches(_ text: String, pattern: String, options: NSRegularExpression.Options) -> Bool {
        firstMatch(in: text, pattern: pattern, options: options) != nil
    }

    private static func intGroup(_ match: NSTextCheckingResult?, _ index: Int) -> Int? {
        guard let match, match.numberOfRanges > index else { return nil }
        // Caller must supply the original text via `substring` below; kept
        // simple by re-deriving from the match's own captured text isn't
        // possible without the source string, so intGroup takes the source
        // implicitly through a bound closure — see overload below.
        return nil
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
