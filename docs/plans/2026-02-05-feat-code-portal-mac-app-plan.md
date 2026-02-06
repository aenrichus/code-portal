---
title: "feat: Code Portal — Claude Code Desktop App for Mac"
type: feat
date: 2026-02-05
deepened: 2026-02-05
reviewed: 2026-02-05
---

# Code Portal — Claude Code Desktop App for Mac

## Enhancement Summary

**Deepened on:** 2026-02-05
**Reviewed on:** 2026-02-05
**Research agents used:** architecture-strategist, performance-oracle, security-sentinel, code-simplicity-reviewer, pattern-recognition-specialist, agent-native-reviewer, SwiftTerm deep-dive, macOS app architecture research

### Key Improvements from Deepening

1. **CRITICAL FIX: Terminal view pool replaces `.id()` pattern** — The original `.id(session.id)` approach destroys and recreates terminal views on every repo switch, losing scrollback and causing 20-80ms flicker. Replaced with a view pool that caches `MonitoredTerminalView` instances and swaps them via `updateNSView`.
2. **CRITICAL FIX: Strong reference to terminal view** — The original weak reference causes silent monitoring failure for non-visible sessions when SwiftUI dismantles the wrapper.
3. **CRITICAL FIX: Decouple monitoring from view** — Output monitoring must be tied to the session lifecycle, not the view lifecycle, or background sessions cannot generate notifications.
4. **Simplified to 3 phases** — Git clone deferred to post-v1. 20 files reduced to ~11. 6 session states reduced to 3.
5. **Security hardening** — Curated environment for PTY processes (allowlist, strip DYLD_*). Empty entitlements to start. CLI path resolution via hardcoded directory search.
6. **Simplicity cuts (from plan review)** — Removed pipeline backpressure (trades correctness for unmeasured performance). Removed tiered scrollback (uniform 5,000 lines). Removed version-gated patterns (hardcode, ship update if they change). Removed orphan scan (process groups handle it). Made CLI resolution synchronous (microseconds). Simplified notifications (state-machine dedup, not timer-based coalescing).
7. **Agent-native seams (from plan review)** — Added `SessionControlling` protocol with `CallerContext` for future automation parity. Added `AsyncStream<SessionEvent>` (factory method, multi-consumer safe) for external observation. Added `sendInput(_:)` with state guard and caller tracking. JSON file persistence at hardened path (0o700/0o600). Notification `userInfo` limited to `sessionId` only. Registered `codeportal://` URL scheme with explicit no-op handler.
8. **Security hardening round 2 (from plan review)** — `sendInput` requires `CallerContext` and only works in `.running`/`.attention` state. JSON directory created with `0o700`, file with `0o600`, atomic writes, path validation on load. Notification `userInfo` stripped to `sessionId` only (no `pattern`/`repoPath` to avoid leaking sensitive data to notification database). URL scheme registered with no-op handler that logs and drops all invocations in v1. `lineBuffer` capped at 64KB to prevent OOM from binary/no-newline output.
9. **Agent-native future path** — Acknowledged `--output-format stream-json` as the long-term control plane. Designed session protocol to support both PTY and headless modes.

---

## Overview

A native macOS desktop application (Swift + SwiftUI) that provides a multi-repo interface for the Claude Code CLI. The app features a sidebar listing projects and a main content area with an embedded terminal emulator running a concurrent Claude Code PTY session per project. macOS-native notifications (dock badge, notification center, sidebar indicators) alert the user whenever a session needs attention.

**Brainstorm reference:** `docs/brainstorms/2026-02-05-code-portal-brainstorm.md`

## Problem Statement

Working with Claude Code across multiple projects requires managing separate terminal windows or tabs. There is no centralized way to monitor session states, receive notifications when Claude needs input, or quickly switch between project contexts. This friction increases with every additional project.

## Proposed Solution

Build a native SwiftUI app that embeds real PTY-backed terminal emulators (via SwiftTerm), one per project. A sidebar provides at-a-glance status for every session, and the macOS notification system surfaces attention-needed events even when the app is in the background.

## Technical Approach

### Architecture

```
CodePortalApp (@main)
  |-- @State var sessionManager = SessionManager()  // top-level, avoids re-init
  |-- NSApplicationDelegateAdaptor(AppDelegate.self) // lifecycle + notification delegate
  |
  +-- SessionControlling (protocol)            // seam for future automation + security boundary
  |     |-- addRepo(path:, caller:) / removeRepo(id:, caller:)
  |     |-- restartSession(id:, caller:)
  |     |-- sendInput(sessionId:, text:, caller:)  // state-guarded: only .running/.attention
  |     |-- listSessions() -> [SessionSnapshot]
  |     |-- sessionState(id:) -> SessionState
  |     |-- func events() -> AsyncStream<SessionEvent>  // factory method (multi-consumer safe)
  |     |-- CallerContext: .userInterface | .urlScheme(sourceApp:) | .xpc(auditToken:)
  |
  +-- SessionManager (@Observable, @MainActor, conforms to SessionControlling)
  |     |-- sessions: [TerminalSession]
  |     |-- terminalViewPool: [UUID: MonitoredTerminalView]  // STRONG refs, view cache
  |     |-- attentionCount: Int  // explicit counter, not computed
  |     |-- notification logic (inline, ~40 LOC)
  |     |-- resolveClaudePath() (synchronous, inline static func)
  |
  +-- ContentView (NavigationSplitView)
        |-- SidebarView (List with inline session rows)
        |-- SessionDetailView (NSViewRepresentable inline + restart overlay)
```

### Research Insights: Architecture

**View pool, NOT `.id()` (from architecture review):**
Using `.id(session.id)` on the terminal view **destroys and recreates** the `NSView` on every selection change. This loses scrollback, causes 20-80ms flicker, and breaks the "terminal state preserved" requirement. Instead, `SessionManager` owns a dictionary of `MonitoredTerminalView` instances (strong references). The `NSViewRepresentable` wrapper returns the cached view from the pool in `makeNSView`, and swaps the child view in `updateNSView`. Tab switch drops to <5ms (view reparenting only).

**Strong reference from session to view (from architecture review):**
The original weak reference causes the view to be deallocated when SwiftUI dismantles the `NSViewRepresentable` wrapper during navigation. This silently breaks monitoring for non-visible sessions. The ownership is: `SessionManager.terminalViewPool --[strong]--> MonitoredTerminalView`. The view's callbacks capture `[weak session]` to avoid cycles.

**Decouple monitoring from view (from agent-native review):**
Output monitoring must run regardless of whether the terminal view is currently displayed. The `MonitoredTerminalView.dataReceived(slice:)` override captures bytes and forwards them to the session's inline monitor logic. Since SwiftTerm's `LocalProcessTerminalView` dispatches `dataReceived` on `DispatchQueue.main` by default, the monitoring code runs on the main thread. For v1 this is acceptable; at scale, dispatch to a per-session background queue.

**@Observable at App-level (from macOS patterns research):**
`@State var sessionManager = SessionManager()` must live in the `@main` App struct, not in a child view. SwiftUI re-evaluates `@State` initializers on every view rebuild — only the App struct is immune. This prevents accidental re-initialization of the session manager.

**Per-session components:**

```
TerminalSession (@Observable, @MainActor)
  |-- id: UUID
  |-- repo: (path: String, name: String)  // inline struct, not separate type
  |-- state: SessionState (.idle, .running, .attention)  // 3 states only
  |-- eventContinuations: [AsyncStream<SessionEvent>.Continuation]  // multi-consumer
  |-- sendInput(_ text: String, caller: CallerContext)
  |     |-- guard state == .running || state == .attention
  |     |-- routes through SessionManager.terminalViewPool[id]?.send(txt:)
  |
  +-- Monitoring: inline in MonitoredTerminalView.dataReceived
        |-- line buffer (capped at 64KB) + ANSI strip (1-line regex) + pattern match
        |-- dispatches state change via Task { @MainActor in }
        |-- yields SessionEvent to all continuations on every transition
        |-- on processExit: yields .processExited, then finish() all continuations
```

### Session State Machine

```
[idle] --start()--> [running]
[running] --attentionDetected()--> [attention]
[attention] --outputResumed()--> [running]
[running | attention] --processExited()--> [idle]
[idle] --start()--> [running]  (restart)
```

### Research Insights: State Machine

**3 states, not 6 (from simplicity review):** The UI has three visual states — gray dot (idle), green dot (running), orange dot (attention). Six enum cases (notStarted, starting, running, needsAttention, exited, crashed) add transitions and edge cases for distinctions that don't affect user behavior in v1. Use associated values if needed later: `case idle(exitCode: Int32? = nil)`.

**Missing transitions in the original (from pattern analysis):** The original state machine lacked `Starting -> Crashed`, `NeedsAttention -> Exited`, and `NeedsAttention -> Crashed`. The simplified 3-state machine handles all of these: any running/attention state transitions to idle on process exit.

### Attention Detection

The attention detection logic is ~20 lines inline in `MonitoredTerminalView.dataReceived(slice:)`:

```swift
override func dataReceived(slice: ArraySlice<UInt8>) {
    super.dataReceived(slice: slice)  // MUST call super for terminal rendering

    lineBuffer.append(contentsOf: slice)
    if lineBuffer.count > 65_536 { lineBuffer.removeAll(keepingCapacity: true) }  // 64KB cap: prevents OOM from binary/no-newline output
    while let newlineRange = lineBuffer.firstRange(of: [0x0A]) {
        let line = String(decoding: lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound], as: UTF8.self)
        lineBuffer.removeSubrange(lineBuffer.startIndex...newlineRange.lowerBound)

        let stripped = line.replacing(/\e\[[0-9;]*[a-zA-Z]/, with: "")
        if stripped.contains("? (y/n)") || stripped.contains(/Allow .+\?/) ||
           stripped.hasPrefix("Error:") || stripped.hasPrefix("error:") {
            Task { @MainActor in session?.state = .attention }
        }
    }
}
```

### Research Insights: Attention Detection

**Heuristic detection is fragile (from agent-native review):** PTY pattern matching is the weakest foundation for the app's core differentiator. Claude Code's terminal output format is not a stable API. False positives occur when Claude outputs "Error:" in code blocks. False negatives occur when prompt formatting changes across versions.

**Mitigation strategy (Phase 1 spike):**
- Phase 1 spike catalogs exact byte sequences for current Claude Code version
- Hardcode patterns in v1. If Claude Code changes output format, ship an app update.
- Log near-matches for false negative debugging

**Long-term path: `--output-format stream-json` (from agent-native review):**
Claude Code provides structured JSON events that make detection trivial: `tool_use` blocks for permission prompts, `result` messages with `subtype: "success"/"error_*"` for completion. The `SessionControlling` protocol and `AsyncStream<SessionEvent>` are designed so that adding a JSON event parser alongside the PTY monitor requires no changes to `SessionManager` or the notification logic. The 3-state `SessionState` enum works identically regardless of detection source.

**No pipeline backpressure in v1 (from plan review):** The ANSI strip regex (`/\e\[[0-9;]*[a-zA-Z]/`) is a single-pass DFA scan. The pattern checks are simple `contains`/`hasPrefix` string operations. Process every line — sampling risks missing attention events during high output, trading correctness (the app's core feature) for unmeasured performance gains. If profiling shows a real problem, add sampling post-v1 with actual measurements.

### Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Terminal library | SwiftTerm 1.10.x | Only mature Swift terminal emulator. `LocalProcessTerminalView` handles PTY internally. |
| SwiftUI bridge | NSViewRepresentable + view pool | Pool caches views per session. No `.id()` — swap child view in `updateNSView`. |
| Output monitoring | Inline in `dataReceived(slice:)` override | ~20 lines. ANSI strip is a 1-line regex. No separate pipeline classes needed. |
| State management | `@Observable` (Swift 5.9+), `@MainActor` | Property-level tracking. Store in App struct to avoid re-init. |
| Threading | `Task { @MainActor in }` for state mutations | SwiftTerm dispatches `dataReceived` on main thread by default. Never use `DispatchQueue.main.async` (mixing GCD + Swift concurrency causes ordering bugs). |
| View lifecycle | Strong refs in `SessionManager.terminalViewPool` | Views persist across navigation. Callbacks use `[weak session]`. |
| Notifications | Inline in SessionManager (~40 LOC) | UNUserNotificationCenter + `dockTile.badgeLabel`. Suppress when focused + one per state transition (state machine deduplicates). Structured `userInfo` in payloads. |
| App Sandbox | Disabled | Required for PTY. Distribute outside Mac App Store. |
| Hardened Runtime | Enabled with zero entitlement opt-outs to start | `forkpty()` does NOT require opt-outs. Add only if Phase 1 spike proves otherwise. |
| Distribution | Developer ID + notarization | Sign, notarize via `notarytool`. |
| Min deployment | macOS 14 (Sonoma) | Required for `@Observable`. |
| Swift version | Swift 6 strict concurrency | Catches thread safety at compile time. |
| Session start | Lazy (on first selection) | Avoids spawning 10+ processes on launch. Show "Starting session..." indicator. |
| Session persistence | Ephemeral (repo list persisted, sessions are not) | PTY state cannot be serialized. |
| Claude CLI discovery | Hardcoded directory search + `FileManager.isExecutableFile` | Synchronous. Search: `/usr/local/bin/claude`, `~/.npm/bin/claude`, `/opt/homebrew/bin/claude`, then fall back to `which`. Cache in `UserDefaults`. Takes microseconds. |
| Environment | Curated allowlist for PTY processes | Strip all `DYLD_*` variables. Pass `PATH`, `HOME`, `USER`, `SHELL`, `TERM`, `LANG`, API key vars. Never inherit full environment. |
| Scrollback | 5,000 lines uniform | ~20 MB per session (120-col terminal, 32 bytes per SwiftTerm CharData). No tiering in v1 — measure first. |
| Process cleanup | SIGTERM all, wait 3s once, SIGKILL survivors | SIGTERM is non-blocking signal delivery. Simple `for` loop + one shared wait. |
| Notification dedup | State-machine based | Session already in `.attention` prevents duplicate notifications. Suppress when app focused + selected session. `threadIdentifier` for per-session grouping. |
| Session control | `SessionControlling` protocol | All operations behind a protocol seam. SwiftUI views call through protocol. Future XPC/URL scheme/AppleScript calls same interface. |
| Event stream | `func events() -> AsyncStream<SessionEvent>` | Factory method (multi-consumer safe). Emits `.stateChanged`, `.attentionDetected(pattern:)`, `.processExited(code:)`. Continuation `finish()`-ed on session removal. Buffering: `.bufferingNewest(100)`. |
| Programmatic input | `sendInput(_: String, caller: CallerContext)` | State-guarded: only works in `.running`/`.attention`. Routes through `SessionManager.terminalViewPool` lookup. `CallerContext` enables per-caller authorization. |
| Repo persistence | JSON file at `~/Library/Application Support/CodePortal/repos.json` | Directory: `0o700`. File: `0o600`. Atomic writes via `Data.write(to:options:.atomic)`. Validate paths on load (resolve symlinks, reject `..`). |
| URL scheme | `codeportal://` registered in Info.plist | No-op handler in v1 (logs and drops all invocations). Handlers with user confirmation in v1.1. |
| Notification userInfo | `sessionId` only | No `pattern` or `repoPath` in `userInfo` — prevents leaking sensitive data to notification database (world-readable on macOS 14). |
| Line buffer | 64KB cap | Prevents OOM from binary/no-newline output. Discards buffer contents when exceeded. |

### Project Structure (~11 files)

```
CodePortal/
  CodePortal/
    CodePortalApp.swift                    -- @main, @State sessionManager, AppDelegate adaptor, codeportal:// URL scheme registration
    Models/
      TerminalSession.swift                -- @Observable @MainActor, SessionState enum, SessionEvent enum, repo struct, sendInput(), eventContinuation
    Protocols/
      SessionControlling.swift             -- Protocol for all session operations (addRepo, removeRepo, restartSession, sendInput, listSessions, events)
    Managers/
      SessionManager.swift                 -- @Observable @MainActor, conforms to SessionControlling, sessions + view pool + notifications + claudePath()
    Views/
      ContentView.swift                    -- NavigationSplitView, includes empty state
      SidebarView.swift                    -- List + toolbar, includes inline session row
      SessionDetailView.swift              -- NSViewRepresentable (inline) + restart overlay + status bar
    Terminal/
      MonitoredTerminalView.swift          -- LocalProcessTerminalView subclass, line buffer + ANSI strip + pattern match
    Resources/
      Assets.xcassets                      -- App icon, accent color
      CodePortal.entitlements              -- Hardened Runtime (empty opt-outs)
  CodePortalTests/
    MonitoredTerminalViewTests.swift       -- Pattern matching + ANSI stripping tests
    SessionManagerTests.swift              -- Session lifecycle + protocol conformance tests
  CodePortal.xcodeproj
```

### Research Insights: File Structure

**11 files, not 20 (from simplicity + plan review):** `Repository` (3 fields), `SessionState` (3 cases), `ANSIStripper` (1-line regex), `ClaudePathResolver` (1 function), `NotificationManager` (3 methods), `SessionRowView` (~20 lines), `SessionStatusBar` (~15 lines), `EmptyStateView` (~10 lines) are all inlined into their natural parent files. The `NSViewRepresentable` wrapper (~30 lines) is inlined into `SessionDetailView` since it has a single consumer. The `SessionControlling` protocol gets its own file as a true cross-cutting concern. `SessionEvent` enum lives alongside `TerminalSession` in the models file.

**Git clone removed from v1 (from simplicity review):** Users already have `git clone` in their terminal. The clone feature adds ~400 LOC (operation class, sheet view, progress parsing, tests, error handling) for something achievable in 5 seconds. Deferred to post-v1.

### Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| SwiftTerm | ~> 1.10 | Terminal emulation + PTY management |
| *(no others)* | | All other functionality uses Apple frameworks |

### Implementation Phases

#### Phase 1: Working Terminal Prototype (2-3 days)

**Goal:** Prove PTY + SwiftUI bridge works. Catalog attention patterns. Validate entitlements.

**Tasks:**

- [x] Create Xcode project (macOS app, SwiftUI lifecycle, Swift 6) — `CodePortal/Package.swift` (SPM-based)
- [x] Configure Hardened Runtime with zero entitlement opt-outs — `Sources/Resources/CodePortal.entitlements`
- [x] Disable App Sandbox — via Info.plist
- [x] Add SwiftTerm 1.10.x via Swift Package Manager
- [x] Implement `MonitoredTerminalView` subclass with `dataReceived` override, inline line buffer + ANSI strip + pattern match — `Sources/Terminal/MonitoredTerminalView.swift`
- [x] Implement NSViewRepresentable wrapper (inline in `SessionDetailView.swift` with view pool pattern from start)
- [x] Implement Claude CLI resolution: synchronous hardcoded directory search, cached in instance var — inline in `SessionManager.swift`
- [x] Define `SessionControlling` protocol with core operations + `CallerContext` enum (`.userInterface`, `.urlScheme(sourceApp:)`, `.xpc(auditToken:)`) — `Sources/Protocols/SessionControlling.swift`
- [x] Define `SessionEvent` enum (`.stateChanged`, `.attentionDetected`, `.processExited`) — inline in `Sources/Protocols/SessionControlling.swift`
- [x] Create minimal `CodePortalApp` with single WindowGroup showing terminal — `Sources/CodePortalApp.swift`
- [ ] Validate that Hardened Runtime + notarization works with `forkpty()` (no opt-outs expected)
- [ ] Validate terminal resize (SIGWINCH) with window resizing
- [x] Validate first responder / keyboard focus works in terminal view
- [ ] **Spike: catalog attention patterns.** Run Claude Code in the embedded terminal. Trigger permission prompts, errors, task completion. Capture raw bytes with/without ANSI. Document exact patterns.
- [x] **Spike: also test `claude --output-format stream-json`** in a separate process to compare structured events vs PTY scraping. Document findings for future hybrid mode.

**Success criteria:** Launch app, interact with Claude Code in embedded terminal, have documented attention patterns, entitlements validated.

#### Phase 2: Multi-Repo + Attention + Notifications (5-6 days)

**Goal:** Full sidebar, concurrent sessions, attention detection, notifications.

**Tasks:**

- [x] Implement `TerminalSession` with 3-state machine, inline repo struct, `AsyncStream<SessionEvent>` factory method (multi-consumer via `eventContinuations` array), `sendInput(_:caller:)` method (state-guarded) — `Models/TerminalSession.swift`
- [x] Implement `SessionManager` conforming to `SessionControlling`: session lifecycle, terminal view pool (strong refs), notification logic, CLI resolution — `Managers/SessionManager.swift`
- [x] Implement `ContentView` with NavigationSplitView — `Views/ContentView.swift`
- [x] Implement `SidebarView` with List, inline session rows (status dot + name), "Add" toolbar button, NSOpenPanel — `Views/SidebarView.swift`
- [x] Implement `SessionDetailView` with inline NSViewRepresentable (from view pool), restart overlay, status label — `Views/SessionDetailView.swift`
- [x] Wire view pool: `makeNSView` returns container; `updateNSView` swaps child view from `SessionManager.terminalViewPool`
- [x] Wire attention detection from `MonitoredTerminalView.dataReceived` to `TerminalSession.state`, emitting `SessionEvent` on each transition
- [x] Implement notification dispatch: UNUserNotificationCenter authorization, post with repo name + `userInfo` containing `sessionId` only (no `pattern`/`repoPath` — prevents leaking sensitive data to notification database), suppress when app focused + session selected
- [x] Implement dock badge: update `attentionCount` on state change (explicit counter, not computed), set `dockTile.badgeLabel`, clear on app activate
- [x] Handle notification tap: `UNUserNotificationCenterDelegate.didReceive` -> activate window, navigate to session
- [x] Set UNUserNotificationCenter delegate in AppDelegate (must be set before `applicationDidFinishLaunching`)
- [x] Use `threadIdentifier` for notification grouping per session
- [x] Implement lazy session start (PTY spawns on first selection, show "Starting..." indicator)
- [x] Construct curated environment for PTY processes: allowlist `PATH`, `HOME`, `USER`, `SHELL`, `TERM`, `LANG`, `ANTHROPIC_API_KEY`; strip all `DYLD_*`
- [x] Persist repo list as JSON file at `~/Library/Application Support/CodePortal/repos.json` with schema: `[{ "path": "...", "name": "...", "addedAt": "..." }]`. Create directory with `0o700`, write file with `0o600` via `Data.write(to:options:.atomic)`. Validate paths on load (resolve symlinks, reject `..`).
- [x] Implement repo removal with confirmation and PTY cleanup
- [x] Implement graceful app quit: SIGTERM all sessions in loop, wait 3s, SIGKILL survivors, confirmation dialog if sessions active
- [x] Implement session restart button (overlaid on terminal when process exited)
- [x] Set scrollback: 5,000 lines uniform
- [x] Register `codeportal://` URL scheme in Info.plist with explicit no-op handler in `AppDelegate` that logs and drops all invocations (prevents silent failure, makes future handler addition obvious)
- [x] Wire `SessionManager` notification logic to subscribe to `AsyncStream<SessionEvent>` from each session
- [x] Write unit tests for pattern matching (extracted to `AttentionDetector`) — `CodePortalTests/AttentionDetectorTests.swift`
- [x] Write unit tests for session lifecycle + `SessionControlling` protocol conformance — `CodePortalTests/SessionLifecycleTests.swift`
- [ ] Test: add 5+ repos, switch between them, verify terminal state preserved (no flicker, no scrollback loss)
- [ ] Test: attention detection end-to-end (trigger permission prompt, verify sidebar + notification + badge)
- [ ] Test: respond to prompt, verify attention clears
- [x] Implement lineBuffer 64KB cap in `MonitoredTerminalView.dataReceived` (discard buffer contents when exceeded — prevents OOM from binary/no-newline output)
- [x] Ensure all `eventContinuations` are `finish()`-ed on session removal (prevents leaked AsyncStream consumers)
- [x] Test: `sendInput(_:caller:)` sends text to PTY, verify state guard rejects input in `.idle` state
- [ ] Test: remove repo while session running
- [ ] Test: quit and relaunch, verify repo list persisted from JSON file

**Success criteria:** Multi-repo sidebar with concurrent sessions, reliable attention detection and notifications, instant switching via view pool, repo persistence.

#### Phase 3: Polish + Hardening (1-2 days)

**Goal:** Keyboard shortcuts, process safety, edge cases.

**Tasks:**

- [x] Keyboard shortcuts: Cmd+N (add), Cmd+W (remove with confirmation), Cmd+]/[ (next/prev repo)
- [x] Claude CLI validation on launch: show helpful error if not found
- [ ] Process group via SwiftTerm's `POSIX_SPAWN_SETSID` (already default): validate SIGHUP on PTY close kills child
- [x] Window title: show selected repo name
- [ ] App icon (placeholder or design)
- [ ] Test: 10+ concurrent repos (memory via Instruments, target <20 MB SwiftTerm buffers per session — 120-col × 5K lines × 32 bytes/CharData)
- [ ] Test: tab switch latency (target <16ms via `os_signpost`)
- [ ] Test: terminal resize with sidebar collapse/expand
- [ ] Test: copy/paste (Cmd+C copies selection, Cmd+V pastes, Ctrl+C sends SIGINT)
- [ ] Test: focus management (sidebar vs terminal, keyboard navigation)

**Success criteria:** Polished for daily use. No orphaned processes. Keyboard-driven workflow works.

**Deferred from Phase 3 (YAGNI, from plan review):**
- Pipeline backpressure / throughput sampling — process every line, profile first
- On-launch orphan scan — `POSIX_SPAWN_SETSID` + SIGHUP handles this
- Memory pressure observer — no tiered scrollback means nothing to trim
- Tiered scrollback — uniform 5,000 lines, measure before optimizing

**Total estimated effort: 8-11 days across 3 phases.**

## Alternative Approaches Considered

1. **SwiftUI + JSON streaming mode** — Use Claude Code's `--output-format stream-json` for structured events. Would make notification detection trivial and enable a richer chat UI. Rejected for v1 because it loses the raw terminal experience and complicates interactive input (permission prompts, stdin). Identified as the long-term control plane.

2. **Hybrid PTY + JSON sidecar** — Run both a PTY and a JSON event stream. Best of both worlds but adds significant complexity. Deferred as a future evolution. Architecture designed to support this: `SessionState` enum and notification logic work identically regardless of detection source.

3. **Tauri + web frontend** — Lighter than Electron, but still a web runtime. Would sacrifice native macOS integration (dock badges, notification center) and add a JavaScript/HTML layer. Rejected in favor of fully native.

4. **Electron** — Proven but heavy. Loses native feel. Not aligned with the goal of a first-class macOS experience.

## Acceptance Criteria

### Functional Requirements

- [ ] Can add local directories as projects via folder picker
- [ ] Each project gets an independent, concurrent Claude Code PTY session
- [ ] Sidebar shows all projects with real-time status indicators (idle/running/attention)
- [ ] Can switch between projects; terminal state preserved (no flicker, no scrollback loss)
- [ ] Detects when Claude Code needs attention (permission prompts, errors)
- [ ] Fires macOS system notifications for attention events (suppress when focused, one per state transition)
- [ ] Dock badge shows count of sessions needing attention
- [ ] Sidebar shows attention indicators per project (orange dot)
- [ ] Can restart exited sessions
- [ ] Can remove projects (kills session, removes from sidebar, does not delete files)
- [ ] Project list persists across app restarts (JSON file at documented path)
- [ ] Graceful shutdown: confirms before quitting with active sessions, SIGTERM + SIGKILL
- [ ] Claude CLI auto-discovered via synchronous directory search + cache
- [ ] `SessionControlling` protocol defines all session operations
- [ ] `AsyncStream<SessionEvent>` emits on every state transition
- [ ] `sendInput(_:caller:)` can write to PTY programmatically (state-guarded, requires `CallerContext`)
- [ ] `codeportal://` URL scheme registered

### Non-Functional Requirements

- [ ] macOS 14 (Sonoma) minimum deployment target
- [ ] App first frame in <500ms, fully interactive in <1500ms
- [ ] Switching between repos <16ms (one frame at 60fps)
- [ ] Pattern matching does not cause visible lag (process every line; profile if issues arise)
- [ ] Supports 10+ concurrent projects without degradation
- [ ] No orphaned `claude` processes after app quit/crash
- [ ] Signed with Developer ID + notarized
- [ ] Curated PTY environment (no DYLD_* leakage)

### Quality Gates

- [ ] Unit tests for: pattern matching, ANSI stripping, session lifecycle
- [ ] Manual testing across all 3 phases
- [ ] No memory leaks from terminal view lifecycle (Instruments Allocations)
- [ ] Hardened Runtime + notarization verified
- [ ] Tab switch latency measured via `os_signpost`

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Attention pattern matching unreliable | Medium | High | Phase 1 spike validates patterns + tests `stream-json` as alternative. Hardcoded patterns in v1; ship app update if they change. |
| Terminal view lifecycle issues with NavigationSplitView | Medium | High | View pool with strong refs (validated by architecture review). No `.id()`. |
| Thread safety with concurrent PTY callbacks | Medium | High | `@MainActor` on all `@Observable` types. Swift 6 strict concurrency. `Task { @MainActor in }` only (no GCD). |
| Orphaned processes on crash | Low | Medium | SwiftTerm uses `POSIX_SPAWN_SETSID` (session leader). SIGHUP on PTY close. Process groups handle cleanup. |
| Claude Code output format changes | Medium | Medium | Hardcoded patterns + app update. Loosely coupled design. Long-term: `stream-json` sidecar. |
| Hardened Runtime blocks PTY | Low | High | Spike in Phase 1. `forkpty()` does NOT require opt-outs per security review. |
| Memory pressure with 10+ sessions | Low | Medium | Uniform 5K scrollback (~20 MB/session, ~200 MB for 10 sessions). Profile in Phase 3. Add tiering only if measured. |
| @Observable re-initialization bug | Medium | Low | Store in `@main` App struct. Keep `init()` lightweight. Add `@ObservationIgnored` only if Instruments shows unnecessary re-evaluations. |
| NSViewRepresentable memory leaks (known SwiftUI bug) | Medium | Medium | Use `NSApplicationDelegateAdaptor`. Profile with Instruments. Implement `dismantleNSView` cleanup. |
| Notification content leaks sensitive info | Low | Medium | Never include raw terminal output in notifications. Use generic messages: "Session needs attention". `userInfo` contains `sessionId` only (no paths/patterns). |
| URL scheme injection from browser | Medium | High | `codeportal://` URLs can be triggered by any website. No-op handler in v1 that logs and drops. Handlers with user confirmation in v1.1. `CallerContext.urlScheme(sourceApp:)` for audit trail. |
| lineBuffer OOM from binary output | Low | High | 64KB cap with `removeAll(keepingCapacity: true)` when exceeded. Prevents unbounded growth from binary/no-newline output. |

## Security Considerations

### Research Insights: Security

**Hardened Runtime entitlements (from security review):** `forkpty()` does NOT require `com.apple.security.cs.allow-unsigned-executable-memory` or any other opt-out. Start with an empty entitlements plist. Only add opt-outs if Phase 1 proves otherwise. Never enable `com.apple.security.cs.allow-dyld-environment-variables`.

**CLI path resolution (from security review):** The original `which claude` via login shell executes arbitrary shell config (`.zshrc`). Replace with:
1. Hardcoded directory search: `/usr/local/bin/claude`, `~/.npm/bin/claude`, `/opt/homebrew/bin/claude`
2. `FileManager.default.isExecutableFile(atPath:)` validation
3. Fall back to `which` only if hardcoded paths fail
4. Cache resolved path in `UserDefaults`

**Curated PTY environment (from security review):** Never pass full `ProcessInfo.processInfo.environment` to PTY processes. Build an explicit allowlist:
- `PATH`, `HOME`, `USER`, `SHELL`, `TERM=xterm-256color`, `LANG`
- `ANTHROPIC_API_KEY` (or however Claude authenticates)
- Unconditionally strip ALL `DYLD_*` variables (prevents dynamic library injection)

**Terminal escape injection (from security review):** An attacker could craft Claude output containing malicious terminal escape sequences that affect the app. The monitoring pipeline strips ANSI for pattern matching, but the terminal view renders raw escapes. SwiftTerm handles standard VT100 sequences safely, but this surface should be monitored.

**Notification content (from security review):** System notifications appear in Notification Center and may be visible on lock screen. Never include raw terminal output. Use generic messages: "Code Portal: [repo-name] needs attention".

**No shell fallback on process exit:** When `claude` exits, the terminal shows "Session ended" with a restart button. It does NOT fall back to a shell, preventing arbitrary command execution.

### Security Hardening Round 2 (from plan review)

**URL scheme browser injection (CRITICAL):** Any website can open `codeportal://send-input?id=...&text=rm+-rf+/` via `<a href>` or `window.open()`. Mitigation: register the scheme in Info.plist but implement a no-op handler in v1 that logs source app (`NSAppleEventDescriptor.attributeDescriptor(forKeyword: keyAddressAttr)`) and drops the invocation. When handlers are added in v1.1, require user confirmation dialog for all operations. `CallerContext.urlScheme(sourceApp:)` provides audit trail.

**sendInput unauthenticated PTY write (CRITICAL):** `sendInput(_:)` without caller tracking allows any code path to inject arbitrary text into a running PTY session. Mitigation: require `CallerContext` parameter. State guard: only `.running`/`.attention`. In v1, only `.userInterface` is accepted. Future URL scheme/XPC callers get their own context variants for authorization decisions.

**JSON file permissions (HIGH):** `~/Library/Application Support/CodePortal/repos.json` defaults to world-readable on most macOS configurations. Contains repo paths that may reveal project names and locations. Mitigation: create directory with `0o700` permissions, write file with `0o600`, use `Data.write(to:options:.atomic)` for crash safety. Validate paths on load: resolve symlinks, reject paths containing `..`.

**Notification userInfo data leakage (MEDIUM):** macOS 14 stores delivered notifications in a SQLite database that is readable by other processes. If `userInfo` contains `pattern` (matched text) or `repoPath` (project location), this data is exposed. Mitigation: `userInfo` contains `sessionId` (UUID) only. The app looks up session details internally when handling notification taps.

## Dependencies & Prerequisites

- **Claude Code CLI** installed and configured (API key set)
- **Xcode 16+** for building (Swift 6, macOS 14 SDK)
- **Apple Developer account** (for code signing + notarization)

## Future Considerations

These are explicitly deferred from v1:

**Near-term (v1.1):**
- **Git clone** via URL input sheet with progress display
- **`--output-format stream-json` sidecar** for reliable attention detection (connects to existing `SessionControlling` protocol + `AsyncStream<SessionEvent>`)
- **Headless sessions** for background task dispatch without terminal view (new `HeadlessSession` conforming to `SessionControlling`)
- **Per-repo Claude arguments** (`--model`, `--allowedTools`)
- **`SessionEvent.outputReceived` or `getRecentOutput(sessionId:lines:)`** — Required for headless sessions and external consumers. Not in v1 because terminal view owns the scrollback buffer; adding output access requires either duplicating the buffer or exposing SwiftTerm internals.
- **`codeportal://` URL scheme handlers**: `add-repo?path=...`, `focus-session?name=...`, `restart-session?id=...`, `send-input?id=...&text=...` (all with user confirmation dialog)
- **Pipeline backpressure** — add only if profiling shows regex cost is measurable
- **Tiered scrollback** — add only if memory profiling shows need
- **On-launch orphan scan** — add if users report stale processes

**Medium-term (v1.2):**
- **Local HTTP API or Unix domain socket** for external agent control (backed by `SessionControlling`)
- **AppleScript / JXA scripting dictionary** (backed by `SessionControlling`)
- **Notification coalescing** (timer-based) — add if users report notification fatigue

**Long-term:**
- **Chat-style UI** overlay on terminal (parse output into messages)
- **Multi-window support** (detach repos into separate windows)
- **Global hotkey** to show/hide the app
- **Notification preferences** (per-repo mute, types)
- **Terminal appearance preferences** (font, colors, scrollback)
- **Session resume** via `claude --resume <session-id>`
- **Agent SDK** as the control plane (`query()`, `canUseTool` callback, `permissionMode`)
- **Dashboard view** showing all session summaries simultaneously
- **Inter-agent coordination** (sessions querying each other, via shared `SessionEvent` streams)
- **Sidebar grouping** and drag-to-reorder
- **Homebrew cask** distribution formula

## References & Research

### Internal References

- Brainstorm: `docs/brainstorms/2026-02-05-code-portal-brainstorm.md`
- Reference Swift app: `/Users/superuser/projects/LidSleepToggle/LidSleepToggle/LidSleepToggleApp.swift`

### External References

- SwiftTerm: https://github.com/migueldeicaza/SwiftTerm (v1.10.x)
- SwiftTerm API: `LocalProcessTerminalView`, `processDelegate`, `dataReceived(slice:)`
- Apple: UNUserNotificationCenter — https://developer.apple.com/documentation/usernotifications
- Apple: NavigationSplitView — https://developer.apple.com/documentation/swiftui/navigationsplitview
- Apple: NSOpenPanel — https://developer.apple.com/documentation/appkit/nsopenpanel
- Apple: Hardened Runtime — https://developer.apple.com/documentation/security/hardened-runtime
- Apple Developer Forums thread 685544: App Sandbox + PTY incompatibility
- Apple Developer Forums thread 738911: `waitUntilExit()` deadlock with pipes
- iTerm2 architecture: https://github.com/gnachman/iTerm2 (persistent view per session pattern)
- @Observable migration: https://developer.apple.com/documentation/SwiftUI/Migrating-from-the-observable-object-protocol-to-the-observable-macro
- kqueue process monitoring: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kqueue.2.html
- Claude Code `stream-json`: `claude --output-format stream-json` for structured events

### Critical Warnings (from research)

| Topic | Warning |
|-------|---------|
| Sandbox | Must be disabled for PTY apps. Cannot ship on Mac App Store. |
| Entitlements | Start with ZERO opt-outs. `forkpty()` does not require them. |
| `delegate` vs `processDelegate` | Never set `LocalProcessTerminalView.delegate` directly. Use `processDelegate`. |
| `dataReceived` override | Always call `super.dataReceived(slice:)` or terminal display breaks. |
| `waitUntilExit()` | Never use with pipes. Use `terminationHandler` instead. |
| Thread safety | Use `Task { @MainActor in }` only. Never mix GCD dispatch with Swift concurrency. |
| `updateNSView` | Never restart processes or recreate views. Use for child view swapping only. |
| PTY limits | macOS default: 127 PTYs (`kern.tty.ptmx_max`). |
| `@State` re-init | `@State var x = MyClass()` re-calls `init()` on every view rebuild. Store `@Observable` state in `@main` App struct only. |
| Environment | Strip `DYLD_*` from PTY environment. Use allowlist. |
| Notifications | Never include raw terminal output. Use generic messages. |
| Process cleanup | SIGTERM all in loop, single 3s wait, then SIGKILL. Signal delivery is non-blocking. |
| SwiftTerm `POSIX_SPAWN_SETSID` | Child becomes session leader. PTY close sends SIGHUP. Does NOT auto-kill in `deinit`. |
| NSViewRepresentable leaks | Known SwiftUI framework bug. Use `dismantleNSView` for cleanup. Profile with Instruments. |
| lineBuffer cap | Must cap at 64KB in `dataReceived`. Binary output or no-newline streams cause unbounded growth → OOM. |
| CallerContext | All mutating `SessionControlling` methods require `CallerContext`. In v1, only `.userInterface` accepted. |
| JSON file permissions | Directory `0o700`, file `0o600`, atomic writes. Default macOS permissions are world-readable. |
| URL scheme handler | Must be explicit no-op (log + drop), not absent. Absent handler silently succeeds with no feedback. |
| Notification userInfo | `sessionId` only. No `pattern`/`repoPath` — notification database is world-readable on macOS 14. |
| AsyncStream continuations | Must `finish()` all continuations on session removal. Leaked continuations prevent consumer tasks from completing. |
