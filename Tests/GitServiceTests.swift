import Foundation
import Testing
@testable import CodePortal

@Suite("GitService Status Parsing")
@MainActor
struct GitStatusParsingTests {

    private func makeService() -> GitService {
        GitService(repoPath: "/tmp/test-repo")
    }

    // MARK: - Status Parsing

    @Test("Parses branch name")
    func parseBranch() {
        let service = makeService()
        let raw = "# branch.oid abc123\0# branch.head main\0"
        let status = service.parseStatus(raw)
        #expect(status.branch == "main")
        #expect(status.isGitRepo == true)
    }

    @Test("Parses detached HEAD as nil branch")
    func parseDetachedHead() {
        let service = makeService()
        let raw = "# branch.oid abc123\0# branch.head (detached)\0"
        let status = service.parseStatus(raw)
        #expect(status.branch == nil)
    }

    @Test("Parses modified staged file")
    func parseStagedModified() {
        let service = makeService()
        let raw = "# branch.head main\01 M. N... 100644 100644 100644 abc123 def456 Sources/Foo.swift\0"
        let status = service.parseStatus(raw)
        #expect(status.staged.count == 1)
        #expect(status.unstaged.count == 0)
        #expect(status.staged[0].path == "Sources/Foo.swift")
        if case .modified = status.staged[0].status {} else {
            Issue.record("Expected .modified status")
        }
        #expect(status.staged[0].isStaged == true)
    }

    @Test("Parses modified unstaged file")
    func parseUnstagedModified() {
        let service = makeService()
        let raw = "# branch.head main\01 .M N... 100644 100644 100644 abc123 def456 Sources/Bar.swift\0"
        let status = service.parseStatus(raw)
        #expect(status.staged.count == 0)
        #expect(status.unstaged.count == 1)
        #expect(status.unstaged[0].path == "Sources/Bar.swift")
        #expect(status.unstaged[0].isStaged == false)
    }

    @Test("Parses partially staged file (appears in both)")
    func parsePartiallyStagedFile() {
        let service = makeService()
        let raw = "# branch.head main\01 MM N... 100644 100644 100644 abc123 def456 Sources/Both.swift\0"
        let status = service.parseStatus(raw)
        #expect(status.staged.count == 1)
        #expect(status.unstaged.count == 1)
        #expect(status.staged[0].path == "Sources/Both.swift")
        #expect(status.unstaged[0].path == "Sources/Both.swift")
        // IDs should be different
        #expect(status.staged[0].id != status.unstaged[0].id)
        #expect(status.staged[0].id == "s:Sources/Both.swift")
        #expect(status.unstaged[0].id == "u:Sources/Both.swift")
    }

    @Test("Parses added file")
    func parseAddedFile() {
        let service = makeService()
        let raw = "# branch.head main\01 A. N... 000000 100644 100644 0000000 abc123 NewFile.swift\0"
        let status = service.parseStatus(raw)
        #expect(status.staged.count == 1)
        if case .added = status.staged[0].status {} else {
            Issue.record("Expected .added status")
        }
    }

    @Test("Parses deleted file")
    func parseDeletedFile() {
        let service = makeService()
        let raw = "# branch.head main\01 D. N... 100644 000000 000000 abc123 0000000 OldFile.swift\0"
        let status = service.parseStatus(raw)
        #expect(status.staged.count == 1)
        if case .deleted = status.staged[0].status {} else {
            Issue.record("Expected .deleted status")
        }
    }

    @Test("Parses untracked file")
    func parseUntrackedFile() {
        let service = makeService()
        let raw = "# branch.head main\0? new_file.txt\0"
        let status = service.parseStatus(raw)
        #expect(status.staged.count == 0)
        #expect(status.unstaged.count == 1)
        #expect(status.unstaged[0].path == "new_file.txt")
        if case .untracked = status.unstaged[0].status {} else {
            Issue.record("Expected .untracked status")
        }
    }

    @Test("Parses renamed file with original path")
    func parseRenamedFile() {
        let service = makeService()
        let raw = "# branch.head main\02 R. N... 100644 100644 100644 abc123 def456 R100 new_name.swift\0old_name.swift\0"
        let status = service.parseStatus(raw)
        #expect(status.staged.count == 1)
        #expect(status.staged[0].path == "new_name.swift")
        #expect(status.staged[0].oldPath == "old_name.swift")
        if case .renamed(let from) = status.staged[0].status {
            #expect(from == "old_name.swift")
        } else {
            Issue.record("Expected .renamed status")
        }
    }

    @Test("Parses clean repo (empty status)")
    func parseCleanRepo() {
        let service = makeService()
        let raw = "# branch.oid abc123\0# branch.head main\0"
        let status = service.parseStatus(raw)
        #expect(status.staged.isEmpty)
        #expect(status.unstaged.isEmpty)
        #expect(status.branch == "main")
    }

    @Test("Parses multiple files of different types")
    func parseMultipleFiles() {
        let service = makeService()
        let raw = [
            "# branch.head feat/test",
            "1 M. N... 100644 100644 100644 abc123 def456 Sources/Modified.swift",
            "1 A. N... 000000 100644 100644 0000000 abc123 Sources/Added.swift",
            "1 .D N... 100644 100644 000000 abc123 0000000 Sources/Deleted.swift",
            "? untracked.txt",
            ""
        ].joined(separator: "\0")
        let status = service.parseStatus(raw)
        #expect(status.branch == "feat/test")
        #expect(status.staged.count == 2)  // Modified + Added
        #expect(status.unstaged.count == 2)  // Deleted + Untracked
    }
}

@Suite("GitService Diff Parsing")
@MainActor
struct GitDiffParsingTests {

    private func makeService() -> GitService {
        GitService(repoPath: "/tmp/test-repo")
    }

    // MARK: - Diff Parsing

    @Test("Parses simple modification")
    func parseSimpleModification() {
        let service = makeService()
        let raw = """
        diff --git a/hello.swift b/hello.swift
        index abc123..def456 100644
        --- a/hello.swift
        +++ b/hello.swift
        @@ -1,3 +1,3 @@
         import Foundation
        -let greeting = "hello"
        +let greeting = "world"
         print(greeting)
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 1)
        #expect(diffs[0].path == "hello.swift")
        #expect(diffs[0].isBinary == false)
        #expect(diffs[0].hunks.count == 1)

        let hunk = diffs[0].hunks[0]
        #expect(hunk.lines.count == 4)
        #expect(hunk.lines[0].kind == .context)
        #expect(hunk.lines[0].text == "import Foundation")
        #expect(hunk.lines[1].kind == .deletion)
        #expect(hunk.lines[1].text == "let greeting = \"hello\"")
        #expect(hunk.lines[2].kind == .addition)
        #expect(hunk.lines[2].text == "let greeting = \"world\"")
        #expect(hunk.lines[3].kind == .context)
    }

    @Test("Parses added file")
    func parseAddedFile() {
        let service = makeService()
        let raw = """
        diff --git a/new.swift b/new.swift
        new file mode 100644
        index 0000000..abc123
        --- /dev/null
        +++ b/new.swift
        @@ -0,0 +1,2 @@
        +import Foundation
        +print("new")
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 1)
        #expect(diffs[0].path == "new.swift")
        #expect(diffs[0].hunks.count == 1)
        #expect(diffs[0].hunks[0].lines.count == 2)
        #expect(diffs[0].hunks[0].lines[0].kind == .addition)
        #expect(diffs[0].hunks[0].lines[1].kind == .addition)
    }

    @Test("Parses deleted file")
    func parseDeletedFile() {
        let service = makeService()
        let raw = """
        diff --git a/old.swift b/old.swift
        deleted file mode 100644
        index abc123..0000000
        --- a/old.swift
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -import Foundation
        -print("old")
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 1)
        #expect(diffs[0].path == "old.swift")
        #expect(diffs[0].hunks.count == 1)
        #expect(diffs[0].hunks[0].lines.count == 2)
        #expect(diffs[0].hunks[0].lines[0].kind == .deletion)
    }

    @Test("Parses binary file")
    func parseBinaryFile() {
        let service = makeService()
        let raw = """
        diff --git a/image.png b/image.png
        index abc123..def456 100644
        Binary files a/image.png and b/image.png differ
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 1)
        #expect(diffs[0].isBinary == true)
        #expect(diffs[0].hunks.isEmpty)
    }

    @Test("Parses renamed file")
    func parseRenamedFile() {
        let service = makeService()
        let raw = """
        diff --git a/old_name.swift b/new_name.swift
        similarity index 90%
        rename from old_name.swift
        rename to new_name.swift
        index abc123..def456 100644
        --- a/old_name.swift
        +++ b/new_name.swift
        @@ -1,3 +1,3 @@
         import Foundation
        -let name = "old"
        +let name = "new"
         print(name)
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 1)
        #expect(diffs[0].path == "new_name.swift")
        #expect(diffs[0].hunks.count == 1)
    }

    @Test("Parses multi-hunk diff")
    func parseMultiHunkDiff() {
        let service = makeService()
        let raw = """
        diff --git a/file.swift b/file.swift
        index abc123..def456 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,3 @@
         line1
        -line2
        +line2_modified
         line3
        @@ -10,3 +10,3 @@
         line10
        -line11
        +line11_modified
         line12
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 1)
        #expect(diffs[0].hunks.count == 2)
        #expect(diffs[0].hunks[0].lines.count == 4)
        #expect(diffs[0].hunks[1].lines.count == 4)
    }

    @Test("Parses multiple files in one diff")
    func parseMultipleFiles() {
        let service = makeService()
        let raw = """
        diff --git a/file1.swift b/file1.swift
        index abc123..def456 100644
        --- a/file1.swift
        +++ b/file1.swift
        @@ -1,2 +1,2 @@
        -old1
        +new1
         context1
        diff --git a/file2.swift b/file2.swift
        index abc123..def456 100644
        --- a/file2.swift
        +++ b/file2.swift
        @@ -1,2 +1,2 @@
        -old2
        +new2
         context2
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 2)
        #expect(diffs[0].path == "file1.swift")
        #expect(diffs[1].path == "file2.swift")
    }

    @Test("Parses no-newline-at-EOF marker")
    func parseNoNewlineAtEOF() {
        let service = makeService()
        let raw = """
        diff --git a/file.swift b/file.swift
        index abc123..def456 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,2 @@
         line1
        -line2
        +line2_modified
        \\ No newline at end of file
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 1)
        let lines = diffs[0].hunks[0].lines
        #expect(lines.count == 4)
        #expect(lines[3].kind == .noNewline)
    }

    @Test("Raw text preserved for patch extraction")
    func rawTextPreserved() {
        let service = makeService()
        let raw = """
        diff --git a/file.swift b/file.swift
        index abc123..def456 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,3 +1,3 @@
         context line
        -deleted line
        +added line
         another context
        """
        let diffs = service.parseDiff(raw)
        let lines = diffs[0].hunks[0].lines
        #expect(lines[0].rawText == " context line")
        #expect(lines[1].rawText == "-deleted line")
        #expect(lines[2].rawText == "+added line")
        #expect(lines[3].rawText == " another context")
    }

    @Test("Empty diff produces no files")
    func parseEmptyDiff() {
        let service = makeService()
        let diffs = service.parseDiff("")
        #expect(diffs.isEmpty)
    }

    @Test("Hunk header with omitted count defaults to 1")
    func hunkHeaderOmittedCount() {
        let service = makeService()
        let raw = """
        diff --git a/one.txt b/one.txt
        index abc123..def456 100644
        --- a/one.txt
        +++ b/one.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let diffs = service.parseDiff(raw)
        #expect(diffs.count == 1)
        #expect(diffs[0].hunks.count == 1)
        #expect(diffs[0].hunks[0].lines.count == 2)
    }
}
