import SwiftUI
import AppKit

/// Right sidebar file tree showing the selected project's directory structure.
/// Uses recursive DisclosureGroup for lazy-loaded collapsible folders.
struct FileTreeView: View {
    let rootURL: URL
    var onFileOpen: ((URL) -> Void)?
    @State private var rootNode: FileNode?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Files")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Tree
            if let root = rootNode, let children = root.children, !children.isEmpty {
                List {
                    ForEach(children) { node in
                        FileNodeRow(node: node, onFileOpen: onFileOpen)
                    }
                }
                .listStyle(.sidebar)
            } else if rootNode != nil {
                VStack {
                    Spacer()
                    Text("Empty directory")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .onAppear { loadRoot() }
        .onChange(of: rootURL) { _, _ in loadRoot() }
    }

    private func loadRoot() {
        let node = FileNode(url: rootURL, isDirectory: true)
        node.loadChildrenIfNeeded()
        rootNode = node
    }
}

// MARK: - FileNodeRow (recursive)

/// A single row in the file tree. Directories use DisclosureGroup for expand/collapse.
private struct FileNodeRow: View {
    @Bindable var node: FileNode
    var onFileOpen: ((URL) -> Void)?

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                if let children = node.children {
                    ForEach(children) { child in
                        FileNodeRow(node: child, onFileOpen: onFileOpen)
                    }
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .onChange(of: node.isExpanded) { _, isExpanded in
                if isExpanded { node.loadChildrenIfNeeded() }
            }
            .contextMenu { directoryContextMenu(for: node) }
        } else {
            Label(node.name, systemImage: fileIcon(for: node.name))
                .lineLimit(1)
                .truncationMode(.middle)
                .onTapGesture(count: 2) {
                    onFileOpen?(node.url)
                }
                .contextMenu { fileContextMenu(for: node) }
        }
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func directoryContextMenu(for node: FileNode) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
    }

    @ViewBuilder
    private func fileContextMenu(for node: FileNode) -> some View {
        Button("View File") {
            onFileOpen?(node.url)
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        Divider()
        Button("Open in Default Editor") {
            NSWorkspace.shared.open(node.url)
        }
    }

    // MARK: - File Icon

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "doc.text"
        case "json", "yaml", "yml", "toml": return "doc.text"
        case "md", "txt": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "sh", "zsh", "bash": return "terminal"
        default: return "doc"
        }
    }
}
