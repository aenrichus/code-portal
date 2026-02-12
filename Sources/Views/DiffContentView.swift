import SwiftUI
import AppKit

/// Popup window view showing a unified diff for a single file.
/// Renders colored +/- lines with monospaced font. Binary files show a placeholder.
struct DiffContentView: View {
    let diff: FileDiff
    @AppStorage("appearance") private var appearance: String = "auto"

    private var isDark: Bool {
        switch appearance {
        case "dark": return true
        case "light": return false
        default:
            return NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(diff.path)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if diff.isBinary {
                    Text("Binary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let stats = diffStats
                    HStack(spacing: 8) {
                        Text("+\(stats.additions)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                        Text("-\(stats.deletions)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if diff.isBinary {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Binary file differs")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diff.hunks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Text("No differences")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffTextView(hunks: diff.hunks, isDark: isDark)
            }
        }
    }

    private var diffStats: (additions: Int, deletions: Int) {
        var add = 0, del = 0
        for hunk in diff.hunks {
            for line in hunk.lines {
                switch line.kind {
                case .addition: add += 1
                case .deletion: del += 1
                default: break
                }
            }
        }
        return (add, del)
    }
}

// MARK: - DiffTextView (NSViewRepresentable)

/// Renders diff hunks in an NSTextView with colored lines.
/// Follows the HighlightedCodeView pattern from FileViewerView.
private struct DiffTextView: NSViewRepresentable {
    let hunks: [DiffHunk]
    let isDark: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFontPanel = false
        textView.usesRuler = false

        textView.layoutManager?.allowsNonContiguousLayout = true

        // Horizontal scrolling for long lines
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let result = NSMutableAttributedString()

        let bgColor = isDark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.98, alpha: 1)
        let additionBg = isDark
            ? NSColor(red: 0.1, green: 0.3, blue: 0.1, alpha: 1)
            : NSColor(red: 0.85, green: 1.0, blue: 0.85, alpha: 1)
        let deletionBg = isDark
            ? NSColor(red: 0.35, green: 0.1, blue: 0.1, alpha: 1)
            : NSColor(red: 1.0, green: 0.85, blue: 0.85, alpha: 1)
        let headerColor = isDark
            ? NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1)
            : NSColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1)
        let contextColor = isDark ? NSColor.lightGray : NSColor.darkGray
        let additionFg = isDark
            ? NSColor(red: 0.6, green: 1.0, blue: 0.6, alpha: 1)
            : NSColor(red: 0.0, green: 0.4, blue: 0.0, alpha: 1)
        let deletionFg = isDark
            ? NSColor(red: 1.0, green: 0.6, blue: 0.6, alpha: 1)
            : NSColor(red: 0.6, green: 0.0, blue: 0.0, alpha: 1)

        for (hunkIndex, hunk) in hunks.enumerated() {
            if hunkIndex > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            // Hunk header
            result.append(NSAttributedString(
                string: hunk.header + "\n",
                attributes: [
                    .font: font,
                    .foregroundColor: headerColor,
                    .backgroundColor: bgColor,
                ]
            ))

            // Lines
            for line in hunk.lines {
                let (prefix, fg, lineBg): (String, NSColor, NSColor)
                switch line.kind {
                case .addition:
                    (prefix, fg, lineBg) = ("+", additionFg, additionBg)
                case .deletion:
                    (prefix, fg, lineBg) = ("-", deletionFg, deletionBg)
                case .context:
                    (prefix, fg, lineBg) = (" ", contextColor, bgColor)
                case .noNewline:
                    (prefix, fg, lineBg) = ("", contextColor, bgColor)
                }

                let lineText = line.kind == .noNewline
                    ? "\\ No newline at end of file\n"
                    : prefix + line.text + "\n"

                result.append(NSAttributedString(
                    string: lineText,
                    attributes: [
                        .font: font,
                        .foregroundColor: fg,
                        .backgroundColor: lineBg,
                    ]
                ))
            }
        }

        textView.textStorage?.setAttributedString(result)
        textView.backgroundColor = bgColor
    }
}
