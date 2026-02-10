import SwiftUI
import AppKit
import Highlightr

/// Read-only file viewer with syntax highlighting. Used in popup windows.
struct FileViewerView: View {
    let content: FileContent
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
            viewerToolbar
            Divider()

            switch content.contentType {
            case .text(let code, let language):
                HighlightedCodeView(code: code, language: language, isDark: isDark)

            case .image(let data):
                imagePreview(data: data)

            case .binary:
                statusView(icon: "doc.questionmark", title: "Not a Text File",
                           message: "This file appears to be binary and cannot be displayed.")

            case .tooLarge:
                statusView(icon: "exclamationmark.triangle",
                           title: "File Too Large",
                           message: "This file is \(ByteCountFormatter.string(fromByteCount: content.fileSize, countStyle: .file)).")

            case .error(let message):
                statusView(icon: "exclamationmark.triangle", title: "Error", message: message)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbarIcon: String {
        if case .image = content.contentType { return "photo" }
        return "doc.text"
    }

    private var viewerToolbar: some View {
        HStack {
            Image(systemName: toolbarIcon)
                .foregroundStyle(.secondary)
            Text(content.filename)
                .font(.headline)
                .lineLimit(1)
            Text(ByteCountFormatter.string(
                fromByteCount: content.fileSize, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Status View

    private func statusView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Image Preview

    private func imagePreview(data: Data) -> some View {
        Group {
            if let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else {
                statusView(icon: "photo.badge.exclamationmark", title: "Cannot Display Image",
                           message: "The image data could not be decoded.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDark ? Color(white: 0.12) : Color(white: 0.95))
    }
}

// MARK: - HighlightedCodeView (NSViewRepresentable)

/// Wraps NSTextView to display syntax-highlighted code.
/// Uses a Coordinator to cache last-applied inputs and avoid redundant re-highlighting.
private struct HighlightedCodeView: NSViewRepresentable {
    let code: String
    let language: String?
    let isDark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        let highlightr: Highlightr? = Highlightr()
        var lastCode: String?
        var lastLanguage: String?
        var lastIsDark: Bool?

        init() {
            highlightr?.ignoreIllegals = true
        }
    }

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

        // Critical for large file performance
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
        let coordinator = context.coordinator
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Skip if nothing changed (coordinator caching)
        let themeChanged = coordinator.lastIsDark != isDark
        let contentChanged = coordinator.lastCode != code || coordinator.lastLanguage != language

        guard themeChanged || contentChanged else { return }

        // Apply theme if changed
        if themeChanged, let highlightr = coordinator.highlightr {
            let themeName = isDark ? "xcode-dark" : "xcode"
            highlightr.setTheme(to: themeName)
            // setCodeFont AFTER setTheme (setTheme resets the font)
            highlightr.theme.setCodeFont(
                NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            )
            coordinator.lastIsDark = isDark
        }

        // Re-highlight (guard above ensures something changed)
        if let highlightr = coordinator.highlightr,
           let attributed = highlightr.highlight(code, as: language) {
            textView.textStorage?.setAttributedString(attributed)
        } else {
            // Fallback: plain monospace text (Highlightr unavailable or failed)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isDark ? NSColor.white : NSColor.black,
            ]
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: code, attributes: attrs)
            )
        }
        coordinator.lastCode = code
        coordinator.lastLanguage = language

        textView.backgroundColor = coordinator.highlightr?.theme.themeBackgroundColor ?? .textBackgroundColor
    }
}
