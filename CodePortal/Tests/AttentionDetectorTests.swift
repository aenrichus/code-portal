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

    // MARK: - Attention Pattern Detection (Real Claude Code patterns)

    @Test("Detects 'Enter to select' multi-choice prompt")
    func detectEnterToSelect() {
        #expect(AttentionDetector.isAttention("Enter to select · Tab/Arrow keys to navigate · Esc to cancel"))
    }

    @Test("Detects Allow permission prompt")
    func detectAllowPrompt() {
        #expect(AttentionDetector.isAttention("Allow Read /some/path?"))
    }

    @Test("Detects Allow with tool name")
    func detectAllowTool() {
        #expect(AttentionDetector.isAttention("Allow Bash(ls -la)?"))
    }

    @Test("Detects Allow case-insensitive")
    func detectAllowCaseInsensitive() {
        #expect(AttentionDetector.isAttention("allow read /etc/hosts?"))
        #expect(AttentionDetector.isAttention("ALLOW Read /etc/hosts?"))
    }

    @Test("Detects Yes/No button row from permission prompt")
    func detectYesNoButtonRow() {
        #expect(AttentionDetector.isAttention("Yes  No  Always"))
        #expect(AttentionDetector.isAttention("  Yes  No"))
    }

    @Test("Detects y/n confirmation prompt")
    func detectYesNo() {
        #expect(AttentionDetector.isAttention("Do you want to continue? (y/n)"))
    }

    @Test("Detects (Y)es prompt")
    func detectYesCapital() {
        #expect(AttentionDetector.isAttention("Proceed? (Y)es / (N)o"))
    }

    @Test("Detects 'Do you want to' prompts")
    func detectDoYouWant() {
        #expect(AttentionDetector.isAttention("Do you want to proceed?"))
        #expect(AttentionDetector.isAttention("do you want to continue?"))
    }

    @Test("Does not match normal output")
    func normalOutput() {
        #expect(!AttentionDetector.isAttention("Building project..."))
        #expect(!AttentionDetector.isAttention("Compiling main.swift"))
        #expect(!AttentionDetector.isAttention("Test passed"))
        #expect(!AttentionDetector.isAttention(""))
        #expect(!AttentionDetector.isAttention("⏺ I'll read the README file for you."))
        #expect(!AttentionDetector.isAttention("Thinking on (tab to toggle)"))
    }

    @Test("Does not match partial Allow without question mark")
    func allowWithoutQuestion() {
        #expect(!AttentionDetector.isAttention("Allow"))
        #expect(!AttentionDetector.isAttention("Allowing access to"))
    }

    @Test("Detects attention after ANSI stripping")
    func attentionWithANSI() {
        let raw = "\u{1B}[1;33mAllow Read /etc/hosts?\u{1B}[0m"
        let stripped = AttentionDetector.stripANSI(raw)
        #expect(AttentionDetector.isAttention(stripped))
    }

    // MARK: - Buffer Scanning (simulating real terminal buffer content)

    @Test("scanBuffer detects multi-choice question")
    func scanBufferMultiChoice() {
        // Real Claude Code terminal buffer when asking a multi-choice question
        let lines = [
            "",
            " ▐▛███▜▌   Claude Code v2.0.36",
            "▝▜█████▛▘  Sonnet 4.5 · Claude Max",
            "  ▘▘ ▝▝    /Users/dev/project",
            "",
            "> read the readme and ask questions",
            "",
            "⏺ I've read the README. Here are some questions:",
            "",
            "────────────────────────────────────────",
            "←  ☐ LLM Provider  ☐ Project State  ✔ Submit  →",
            "",
            "Which LLM providers should this support?",
            "",
            "❯ 1. [ ] OpenAI (GPT-4)",
            "     Use OpenAI's API",
            "  2. [ ] Anthropic (Claude)",
            "     Use Anthropic's API",
            "",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
            "",
        ]
        let result = AttentionDetector.scanBuffer(lines)
        #expect(result != nil)
        #expect(result!.contains("Enter to select"))
    }

    @Test("scanBuffer returns nil when Claude is working")
    func scanBufferWorking() {
        let lines = [
            "",
            " ▐▛███▜▌   Claude Code v2.0.36",
            "▝▜█████▛▘  Sonnet 4.5 · Claude Max",
            "",
            "────────────────────────────────────────",
            "> build the project",
            "────────────────────────────────────────",
            "                                        Thinking on (tab to toggle)",
            "",
        ]
        let result = AttentionDetector.scanBuffer(lines)
        #expect(result == nil)
    }

    @Test("scanBuffer returns nil for empty/blank lines")
    func scanBufferEmptyLines() {
        let result = AttentionDetector.scanBuffer(["", "", "", ""])
        #expect(result == nil)
    }

    @Test("scanBuffer returns nil for empty array")
    func scanBufferEmptyArray() {
        let result = AttentionDetector.scanBuffer([])
        #expect(result == nil)
    }

    @Test("scanBuffer detects permission prompt with Yes/No buttons")
    func scanBufferPermissionPrompt() {
        let lines = [
            "⏺ Allow Read /etc/hosts?",
            "",
            "  Yes  No  Always",
        ]
        let result = AttentionDetector.scanBuffer(lines)
        #expect(result != nil)
    }

    // MARK: - Waiting for Input Detection

    @Test("isWaitingForInput detects idle prompt after task completion")
    func waitingForInputAfterTask() {
        let lines = [
            "⏺ Done! The project has been built.",
            "",
            "────────────────────────────────────────",
            "> Try \"write a test for <filepath>\"",
            "────────────────────────────────────────",
            "  ? for shortcuts",
            "",
        ]
        #expect(AttentionDetector.isWaitingForInput(lines))
    }

    @Test("isWaitingForInput detects bare > prompt")
    func waitingForInputBarePrompt() {
        let lines = [
            "some output",
            "────────────────────────────────────────",
            ">",
            "────────────────────────────────────────",
        ]
        #expect(AttentionDetector.isWaitingForInput(lines))
    }

    @Test("isWaitingForInput returns false when no prompt present")
    func notWaitingWhenNoPrompt() {
        let lines = [
            "⏺ Building the project...",
            "  Compiling main.swift",
            "",
        ]
        #expect(!AttentionDetector.isWaitingForInput(lines))
    }

    @Test("isWaitingForInput returns false for prompt without horizontal rule")
    func notWaitingWithoutRule() {
        // ">" without a horizontal rule above could be something else
        let lines = [
            "some text",
            "> Try \"write a test\"",
            "more text",
        ]
        #expect(!AttentionDetector.isWaitingForInput(lines))
    }

    // MARK: - Legacy Line Buffer Processing

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

    @Test("Buffers incomplete line across calls")
    func incompleteLineBuffering() {
        var buffer = Data()

        let chunk1 = Array("Hello ".utf8)
        let results1 = AttentionDetector.processData(chunk1[...], lineBuffer: &buffer)
        #expect(results1.isEmpty)
        #expect(!buffer.isEmpty)

        let chunk2 = Array("world\n".utf8)
        let results2 = AttentionDetector.processData(chunk2[...], lineBuffer: &buffer)
        #expect(results2.count == 1)
        #expect(results2[0].line == "Hello world")
        #expect(buffer.isEmpty)
    }

    @Test("Clears buffer when 64KB cap exceeded")
    func bufferCapEnforced() {
        var buffer = Data()

        let bigChunk = Array(repeating: UInt8(0x41), count: 65_000)
        let results1 = AttentionDetector.processData(bigChunk[...], lineBuffer: &buffer)
        #expect(results1.isEmpty)
        #expect(buffer.count == 65_000)

        let overflow = Array(repeating: UInt8(0x42), count: 600)
        let results2 = AttentionDetector.processData(overflow[...], lineBuffer: &buffer)
        #expect(results2.isEmpty)
        #expect(buffer.isEmpty)
    }
}
