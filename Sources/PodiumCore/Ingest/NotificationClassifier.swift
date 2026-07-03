// NotificationClassifier.swift — port of hooks.js's Notification-message
// classification (lines 188–198): distinguishes "Claude is blocked waiting
// for the user" notifications (permission prompts, explicit "waiting for
// input") from idle/informational notifications, and separately flags
// compaction-related notifications.

import Foundation

public enum NotificationClassifier {
    /// Mirrors hooks.js's WAITING_INPUT_PATTERN exactly (case-insensitive):
    /// "permission", "waiting (for )(your )(input|response|reply|approval)",
    /// "needs your (input|approval|response|attention)",
    /// "approval (needed|required)", "awaiting (your )(input|approval|response)".
    private static let waitingInputPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\bpermission\b|waiting (?:for )?(?:your )?(?:input|response|reply|approval)|needs?\s+your\s+(?:input|approval|response|attention)|approval\s+(?:needed|required)|awaiting\s+(?:your\s+)?(?:input|approval|response)"#,
        options: [.caseInsensitive]
    )

    /// Mirrors hooks.js's compaction-notification sniff:
    /// `/compact|compress|context.*(reduc|truncat|summar)/i`.
    private static let compactionPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"compact|compress|context.*(reduc|truncat|summar)"#,
        options: [.caseInsensitive]
    )

    private static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// True when `message` indicates Claude Code is blocked waiting for the
    /// user (permission prompt or explicit "waiting for input" notice). Idle
    /// notifications like "Claude has finished responding" do NOT match.
    public static func isWaitingForUser(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        return matches(waitingInputPattern, message)
    }

    /// True when `message` looks like a compaction/context-reduction notice.
    public static func isCompactionRelated(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        return matches(compactionPattern, message)
    }
}
