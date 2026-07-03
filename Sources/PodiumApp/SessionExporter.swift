#if os(macOS)
import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreText

// MARK: - SessionExporter

enum SessionExporter {

    // MARK: - Public API

    /// Build a Markdown document for a session.
    static func markdown(session: Session,
                         agents: [Agent],
                         events: [DashboardEvent],
                         stats: SessionStats?) -> String {
        var lines: [String] = []
        let projectName = Theme.projectName(from: session.cwd)
        let title = session.name ?? projectName

        // Title + metadata table
        lines += [
            "# \(title)",
            "",
            "| Field | Value |",
            "|---|---|",
            "| Session ID | `\(session.id)` |",
            "| Status | \(session.status.rawValue.capitalized) |",
        ]

        if let cwd = session.cwd {
            lines.append("| Working Directory | `\(cwd)` |")
        }
        if let model = session.model {
            lines.append("| Model | \(model) |")
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        lines.append("| Started | \(dateFormatter.string(from: session.startedAt)) |")
        if let endedAt = session.endedAt {
            lines.append("| Ended | \(dateFormatter.string(from: endedAt)) |")
            let duration = endedAt.timeIntervalSince(session.startedAt)
            lines.append("| Duration | \(formatDuration(duration)) |")
        }

        // Summary section
        lines += ["", "## Summary", ""]

        if let stats = stats {
            let mainCount = agents.filter { $0.type == .main }.count
            let subagentCount = agents.filter { $0.type == .subagent }.count

            lines += [
                "| Metric | Value |",
                "|---|---|",
                "| Total Events | \(stats.totalEvents) |",
                "| Error Count | \(stats.errorCount) |",
                "| Total Agents | \(stats.agents.total) |",
                "| Main Agents | \(mainCount) |",
                "| Sub-agents | \(subagentCount) |",
                "| Input Tokens | \(Theme.formatTokens(stats.tokens.inputTokens)) |",
                "| Output Tokens | \(Theme.formatTokens(stats.tokens.outputTokens)) |",
                "| Cache Read Tokens | \(Theme.formatTokens(stats.tokens.cacheReadTokens)) |",
                "| Cache Write Tokens | \(Theme.formatTokens(stats.tokens.cacheWriteTokens)) |",
            ]

            let totalTokens = stats.tokens.inputTokens + stats.tokens.outputTokens
                + stats.tokens.cacheReadTokens + stats.tokens.cacheWriteTokens
            lines.append("")
            lines.append("**Token totals**: \(Theme.formatTokens(totalTokens)) total "
                + "(\(Theme.formatTokens(stats.tokens.inputTokens)) in, "
                + "\(Theme.formatTokens(stats.tokens.outputTokens)) out, "
                + "\(Theme.formatTokens(stats.tokens.cacheReadTokens)) cache-read, "
                + "\(Theme.formatTokens(stats.tokens.cacheWriteTokens)) cache-write)")
        } else {
            let mainCount = agents.filter { $0.type == .main }.count
            let subagentCount = agents.filter { $0.type == .subagent }.count
            lines += [
                "| Metric | Value |",
                "|---|---|",
                "| Total Events | \(events.count) |",
                "| Total Agents | \(agents.count) |",
                "| Main Agents | \(mainCount) |",
                "| Sub-agents | \(subagentCount) |",
            ]
        }

        // Agents table
        lines += [
            "",
            "## Agents (\(agents.count))",
            "",
            "| Name | Type | Subagent Type | Status |",
            "|---|---|---|---|",
        ]
        for agent in agents.sorted(by: { $0.startedAt < $1.startedAt }) {
            let subagentType = agent.subagentType ?? "—"
            lines.append("| \(agent.name) | \(agent.type.rawValue) | \(subagentType) | \(agent.status.rawValue) |")
        }

        // Top Tools
        if let stats = stats, !stats.toolsUsed.isEmpty {
            lines += ["", "## Top Tools", ""]
            let topTools = stats.toolsUsed.sorted(by: { $0.count > $1.count }).prefix(20)
            for tool in topTools {
                lines.append("- **\(tool.toolName)**: \(tool.count) uses")
            }
        }

        // Events section (capped at 500)
        let cappedEvents = Array(events.prefix(500))
        if !cappedEvents.isEmpty {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"

            lines += [
                "",
                "## Events (first \(cappedEvents.count) of \(events.count))",
                "",
            ]
            for event in cappedEvents {
                let timeStr = timeFormatter.string(from: event.createdAt)
                let detail: String
                if let toolName = event.toolName, let summary = event.summary {
                    detail = "\(toolName) — \(summary)"
                } else if let toolName = event.toolName {
                    detail = toolName
                } else if let summary = event.summary {
                    detail = summary
                } else {
                    detail = ""
                }
                if detail.isEmpty {
                    lines.append("- [\(timeStr)] \(event.eventType)")
                } else {
                    lines.append("- [\(timeStr)] \(event.eventType) — \(detail)")
                }
            }
        }

        lines += [
            "",
            "---",
            "",
            "*Exported from Podium on \(dateFormatter.string(from: Date()))*",
        ]

        return lines.joined(separator: "\n")
    }

    /// Render the same content to PDF data (US Letter, multi-page).
    static func pdfData(session: Session,
                        agents: [Agent],
                        events: [DashboardEvent],
                        stats: SessionStats?) -> Data? {
        let mdText = markdown(session: session, agents: agents, events: events, stats: stats)
        return renderMarkdownToPDF(mdText)
    }

    /// Convenience: present an NSSavePanel and write the chosen format.
    @MainActor
    static func presentSavePanel(session: Session,
                                 agents: [Agent],
                                 events: [DashboardEvent],
                                 stats: SessionStats?,
                                 format: ExportFormat) {
        let projectName = Theme.projectName(from: session.cwd)
        let shortId = String(session.id.prefix(8))
        let baseName = "\(projectName)-\(shortId)"

        let panel = NSSavePanel()
        panel.canCreateDirectories = true

        switch format {
        case .markdown:
            panel.nameFieldStringValue = "\(baseName).md"
            let mdType = UTType("net.daringfireball.markdown") ?? .plainText
            panel.allowedContentTypes = [mdType]

        case .pdf:
            panel.nameFieldStringValue = "\(baseName).pdf"
            panel.allowedContentTypes = [.pdf]
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            switch format {
            case .markdown:
                let text = markdown(session: session, agents: agents, events: events, stats: stats)
                if let data = text.data(using: .utf8) {
                    try? data.write(to: url)
                }
            case .pdf:
                if let data = pdfData(session: session, agents: agents, events: events, stats: stats) {
                    try? data.write(to: url)
                }
            }
        }
    }

    // MARK: - Export Format

    enum ExportFormat { case markdown, pdf }

    // MARK: - Private Helpers

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        } else {
            return "\(seconds)s"
        }
    }

    /// Renders a plain-text document (the Markdown string) into paginated US-Letter PDF data.
    /// Uses CoreText for multi-page layout with ~48pt margins.
    private static func renderMarkdownToPDF(_ text: String) -> Data? {
        // Page geometry
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 48
        let textWidth = pageWidth - margin * 2
        let textHeight = pageHeight - margin * 2
        let textRect = CGRect(x: margin, y: margin, width: textWidth, height: textHeight)

        // Build attributed string with light formatting
        let attributed = buildAttributedString(from: text)

        // Framesetter for pagination
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        // Measure total content height to know how many pages we need
        let constrainedSize = CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        let totalSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil, constrainedSize, nil)
        let estimatedPages = max(1, Int(ceil(totalSize.height / textHeight)) + 1)

        // Render into PDF
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return nil }

        var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageWidth, height: pageHeight))
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var charIndex = 0
        let totalChars = attributed.length

        for _ in 0..<(estimatedPages + 1) {
            guard charIndex < totalChars else { break }

            context.beginPDFPage(nil)

            // CoreText coordinate system: origin is bottom-left
            // We draw in a flipped context so text flows top-to-bottom
            let ctxBounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            context.saveGState()

            // Fill white background
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(ctxBounds)

            // Flip coordinate system so text renders top-to-bottom
            context.translateBy(x: 0, y: pageHeight)
            context.scaleBy(x: 1, y: -1)

            // Create path for this page's text area
            let path = CGMutablePath()
            path.addRect(textRect)

            let cfRange = CFRangeMake(charIndex, 0)
            let frame = CTFramesetterCreateFrame(framesetter, cfRange, path, nil)

            CTFrameDraw(frame, context)

            // Find out how many chars were drawn on this page
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            charIndex += visibleRange.length

            context.restoreGState()
            context.endPDFPage()

            if charIndex >= totalChars { break }
        }

        context.closePDF()

        return pdfData as Data
    }

    /// Build an NSAttributedString from the Markdown text with basic styling.
    private static func buildAttributedString(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let bodyFont = NSFont.systemFont(ofSize: 11)
        let boldFont = NSFont.boldSystemFont(ofSize: 11)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let h1Font = NSFont.boldSystemFont(ofSize: 18)
        let h2Font = NSFont.boldSystemFont(ofSize: 14)
        let h3Font = NSFont.boldSystemFont(ofSize: 12)
        let textColor = NSColor.black
        let secondaryColor = NSColor.darkGray

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 6

        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]
        let monoAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: secondaryColor,
            .paragraphStyle: paragraphStyle,
        ]

        let lines = markdown.components(separatedBy: "\n")

        for line in lines {
            let lineWithNewline = line + "\n"

            if line.hasPrefix("# ") {
                let text = String(line.dropFirst(2))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: h1Font,
                    .foregroundColor: textColor,
                    .paragraphStyle: headerParagraphStyle(spacing: 10),
                ]
                result.append(NSAttributedString(string: text + "\n", attributes: attrs))

            } else if line.hasPrefix("## ") {
                let text = String(line.dropFirst(3))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: h2Font,
                    .foregroundColor: textColor,
                    .paragraphStyle: headerParagraphStyle(spacing: 8),
                ]
                result.append(NSAttributedString(string: text + "\n", attributes: attrs))

            } else if line.hasPrefix("### ") {
                let text = String(line.dropFirst(4))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: h3Font,
                    .foregroundColor: textColor,
                    .paragraphStyle: headerParagraphStyle(spacing: 6),
                ]
                result.append(NSAttributedString(string: text + "\n", attributes: attrs))

            } else if line.hasPrefix("|") {
                // Table rows — use monospaced for alignment
                result.append(NSAttributedString(string: lineWithNewline, attributes: monoAttrs))

            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                // List items — render inline bold if they contain **...**
                let listLine = lineWithNewline
                result.append(renderInlineBold(listLine, baseAttrs: bodyAttrs, boldFont: boldFont))

            } else if line.hasPrefix("---") {
                // Horizontal rule — blank line with separator
                result.append(NSAttributedString(string: "\n", attributes: bodyAttrs))

            } else if line.hasPrefix("`") && line.hasSuffix("`") && line.count > 2 {
                result.append(NSAttributedString(string: lineWithNewline, attributes: monoAttrs))

            } else if line.hasPrefix("*") && line.hasSuffix("*") {
                // Italic line (e.g. footer)
                let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                let italicFont = NSFont.systemFont(ofSize: 10)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: italicFont,
                    .foregroundColor: secondaryColor,
                    .paragraphStyle: paragraphStyle,
                ]
                result.append(NSAttributedString(string: inner + "\n", attributes: attrs))

            } else {
                result.append(renderInlineBold(lineWithNewline, baseAttrs: bodyAttrs, boldFont: boldFont))
            }
        }

        return result
    }

    private static func headerParagraphStyle(spacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacing
        style.paragraphSpacing = spacing / 2
        return style
    }

    /// Render a line that may contain **bold** spans.
    private static func renderInlineBold(_ text: String,
                                         baseAttrs: [NSAttributedString.Key: Any],
                                         boldFont: NSFont) -> NSAttributedString {
        guard text.contains("**") else {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }

        let result = NSMutableAttributedString()
        var remaining = text[text.startIndex...]

        while let boldStart = remaining.range(of: "**") {
            // Append text before the opening **
            let before = String(remaining[remaining.startIndex..<boldStart.lowerBound])
            if !before.isEmpty {
                result.append(NSAttributedString(string: before, attributes: baseAttrs))
            }
            remaining = remaining[boldStart.upperBound...]

            // Find closing **
            if let boldEnd = remaining.range(of: "**") {
                let boldText = String(remaining[remaining.startIndex..<boldEnd.lowerBound])
                var boldAttrs = baseAttrs
                boldAttrs[.font] = boldFont
                result.append(NSAttributedString(string: boldText, attributes: boldAttrs))
                remaining = remaining[boldEnd.upperBound...]
            } else {
                // No closing **, treat rest as normal
                result.append(NSAttributedString(string: String(remaining), attributes: baseAttrs))
                return result
            }
        }

        // Append any tail
        if !remaining.isEmpty {
            result.append(NSAttributedString(string: String(remaining), attributes: baseAttrs))
        }

        return result
    }
}

#endif
