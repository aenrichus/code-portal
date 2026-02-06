import Foundation
import Testing
@testable import CodePortal

@Suite("AttentionDetector Tests")
struct AttentionDetectorTests {

    // MARK: - ANSI Stripping

    @Test("Strips basic ANSI color codes")
    func stripBasicColors() {
        let input = "\u{1B}[32mSuccess\u{1B}[0m"
        #expect(AttentionDetector.stripANSI(input) == "Success")
    }

    @Test("Strips multi-param ANSI sequences")
    func stripMultiParam() {
        let input = "\u{1B}[1;31;42mBold red on green\u{1B}[0m"
        #expect(AttentionDetector.stripANSI(input) == "Bold red on green")
    }

    @Test("Leaves plain text unchanged")
    func plainTextUnchanged() {
        let input = "No ANSI here"
        #expect(AttentionDetector.stripANSI(input) == "No ANSI here")
    }

    @Test("Strips multiple ANSI sequences in one line")
    func multipleSequences() {
        let input = "\u{1B}[33mWarn:\u{1B}[0m something \u{1B}[1mbold\u{1B}[0m"
        #expect(AttentionDetector.stripANSI(input) == "Warn: something bold")
    }

    @Test("Handles empty string")
    func emptyString() {
        #expect(AttentionDetector.stripANSI("") == "")
    }

    // MARK: - Attention Pattern Detection

    @Test("Detects y/n confirmation prompt")
    func detectYesNo() {
        #expect(AttentionDetector.isAttention("Do you want to continue? (y/n)"))
    }

    @Test("Detects (Y)es prompt")
    func detectYesCapital() {
        #expect(AttentionDetector.isAttention("Proceed? (Y)es / (N)o"))
    }

    @Test("Detects Allow permission prompt")
    func detectAllowPrompt() {
        #expect(AttentionDetector.isAttention("Allow Read /some/path?"))
    }

    @Test("Detects Allow with tool name")
    func detectAllowTool() {
        #expect(AttentionDetector.isAttention("Allow Bash(ls -la)?"))
    }

    @Test("Detects Error: prefix")
    func detectErrorCapital() {
        #expect(AttentionDetector.isAttention("Error: something went wrong"))
    }

    @Test("Detects error: prefix (lowercase)")
    func detectErrorLower() {
        #expect(AttentionDetector.isAttention("error: compilation failed"))
    }

    @Test("Does not match normal output")
    func normalOutput() {
        #expect(!AttentionDetector.isAttention("Building project..."))
        #expect(!AttentionDetector.isAttention("Compiling main.swift"))
        #expect(!AttentionDetector.isAttention("Test passed"))
        #expect(!AttentionDetector.isAttention(""))
    }

    @Test("Does not match error in the middle of a line")
    func errorMiddleLine() {
        // hasPrefix only, so "An error: foo" should NOT match
        #expect(!AttentionDetector.isAttention("An error: happened"))
        #expect(!AttentionDetector.isAttention("An Error: happened"))
    }

    @Test("Detects attention after ANSI stripping")
    func attentionWithANSI() {
        let raw = "\u{1B}[1;33mAllow Read /etc/hosts?\u{1B}[0m"
        let stripped = AttentionDetector.stripANSI(raw)
        #expect(AttentionDetector.isAttention(stripped))
    }

    // MARK: - Line Buffer Processing

    @Test("Processes single complete line")
    func singleCompleteLine() {
        var buffer = Data()
        let data = Array("Hello world\n".utf8)
        let results = AttentionDetector.processData(data[...], lineBuffer: &buffer)
        #expect(results.count == 1)
        #expect(results[0].line == "Hello world")
        #expect(results[0].isAttention == false)
        #expect(buffer.isEmpty)
    }

    @Test("Processes multiple complete lines")
    func multipleLines() {
        var buffer = Data()
        let data = Array("line1\nline2\nline3\n".utf8)
        let results = AttentionDetector.processData(data[...], lineBuffer: &buffer)
        #expect(results.count == 3)
        #expect(results[0].line == "line1")
        #expect(results[1].line == "line2")
        #expect(results[2].line == "line3")
    }

    @Test("Buffers incomplete line across calls")
    func incompleteLineBuffering() {
        var buffer = Data()

        // First chunk: incomplete line
        let chunk1 = Array("Hello ".utf8)
        let results1 = AttentionDetector.processData(chunk1[...], lineBuffer: &buffer)
        #expect(results1.isEmpty)
        #expect(!buffer.isEmpty)

        // Second chunk: completes the line
        let chunk2 = Array("world\n".utf8)
        let results2 = AttentionDetector.processData(chunk2[...], lineBuffer: &buffer)
        #expect(results2.count == 1)
        #expect(results2[0].line == "Hello world")
        #expect(buffer.isEmpty)
    }

    @Test("Detects attention pattern in buffered line")
    func attentionInBuffer() {
        var buffer = Data()
        let data = Array("Allow Read /etc/hosts?\n".utf8)
        let results = AttentionDetector.processData(data[...], lineBuffer: &buffer)
        #expect(results.count == 1)
        #expect(results[0].isAttention == true)
    }

    @Test("Strips ANSI before pattern matching")
    func ansiStrippedBeforeMatch() {
        var buffer = Data()
        let data = Array("\u{1B}[33mError: oops\u{1B}[0m\n".utf8)
        let results = AttentionDetector.processData(data[...], lineBuffer: &buffer)
        #expect(results.count == 1)
        #expect(results[0].line == "Error: oops")
        #expect(results[0].isAttention == true)
    }

    @Test("Clears buffer when 64KB cap exceeded")
    func bufferCapEnforced() {
        var buffer = Data()

        // Fill buffer near the cap with no newlines
        let bigChunk = Array(repeating: UInt8(0x41), count: 65_000)  // 65K of 'A'
        let results1 = AttentionDetector.processData(bigChunk[...], lineBuffer: &buffer)
        #expect(results1.isEmpty)  // No newlines, no results
        #expect(buffer.count == 65_000)

        // Push over the cap
        let overflow = Array(repeating: UInt8(0x42), count: 600)  // push past 65,536
        let results2 = AttentionDetector.processData(overflow[...], lineBuffer: &buffer)
        #expect(results2.isEmpty)
        #expect(buffer.isEmpty)  // Buffer was cleared
    }

    @Test("Handles partial line after newline")
    func partialAfterNewline() {
        var buffer = Data()
        let data = Array("complete\nincomplete".utf8)
        let results = AttentionDetector.processData(data[...], lineBuffer: &buffer)
        #expect(results.count == 1)
        #expect(results[0].line == "complete")
        // "incomplete" should remain in buffer
        #expect(String(decoding: buffer, as: UTF8.self) == "incomplete")
    }
}
