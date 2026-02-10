import Foundation

/// Recursive file tree model with lazy child loading.
/// Children are enumerated only when a folder is first expanded.
@Observable
@MainActor
final class FileNode: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?       // nil = not yet loaded, [] = empty dir
    var isExpanded: Bool = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
    }

    /// Lazy-load children on first expansion.
    /// Directories sort before files. Hidden files (dot-prefixed) are skipped.
    func loadChildrenIfNeeded() {
        guard isDirectory, children == nil else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            children = []
            return
        }

        // Build (url, isDir) pairs, then sort: directories first, then alphabetical
        let entries: [(URL, Bool)] = urls.map { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (url, isDir)
        }

        children = entries
            .sorted { lhs, rhs in
                // Directories before files
                if lhs.1 != rhs.1 { return lhs.1 }
                // Alphabetical within same type
                return lhs.0.lastPathComponent.localizedStandardCompare(rhs.0.lastPathComponent) == .orderedAscending
            }
            .map { FileNode(url: $0.0, isDirectory: $0.1) }
    }
}
