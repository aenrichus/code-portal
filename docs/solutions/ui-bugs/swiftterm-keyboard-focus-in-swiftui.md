---
title: "SwiftTerm Keyboard Focus in SwiftUI NSViewRepresentable"
date: 2026-02-06
category: ui-bugs
module: terminal-embedding
severity: high
tags:
  - swiftui
  - nsviewrepresentable
  - swiftterm
  - keyboard-focus
  - responder-chain
  - macos
  - app-bundle
  - path-environment
  - nvm
  - pty
symptoms:
  - "Keyboard input not reaching terminal view in SwiftUI"
  - "swift run retains stdin focus"
  - "Claude CLI fails with 'env: node: No such file or directory' when launched from Finder"
---

# SwiftTerm Keyboard Focus in SwiftUI NSViewRepresentable

## Problem

### Primary Symptom
When embedding SwiftTerm's `LocalProcessTerminalView` (an NSView subclass) in a SwiftUI macOS app via `NSViewRepresentable`, keyboard input did not reach the terminal view. Keystrokes went to the parent terminal instead of the app window.

### Secondary Symptom
When building the app as a proper `.app` bundle and launching from Finder, Claude CLI failed with `env: node: No such file or directory` because the Finder-launched environment has a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) that doesn't include nvm, homebrew, or other user tool paths.

## Investigation Steps (What Didn't Work)

### Attempt 1: Container NSView with mouseDown override
Wrapped the terminal in a `TerminalContainerView` that overrode `mouseDown` and called `window.makeFirstResponder`.

**Result**: This broke the responder chain because the container sat between SwiftUI's hosting view and the terminal, intercepting key events.

### Attempt 2: NSViewControllerRepresentable
Switched from `NSViewRepresentable` to `NSViewControllerRepresentable` with a `TerminalHostViewController`.

**Result**: Same behavior - the extra view controller layer didn't help.

### Attempt 3: Direct return from NSViewRepresentable + updateNSView focus
Returned `LocalProcessTerminalView` directly from `makeNSView` (no container). Used `DispatchQueue.main.async { window.makeFirstResponder(view) }` in `updateNSView`.

**Result**: Build succeeded but still didn't work when launched via `swift run` from terminal.

## Root Cause

**Three separate issues identified:**

### 1. swift run retains stdin
When launched from a terminal via `swift run`, the terminal process retains keyboard focus. `NSApplication.shared.activate(ignoringOtherApps: true)` is needed to steal focus, but even that isn't fully reliable from `swift run`. The real fix is to run as a proper `.app` bundle.

### 2. updateNSView timing is wrong for focus
`updateNSView` fires repeatedly during SwiftUI layout, often before the view has a window. `window.makeFirstResponder()` silently fails when `window` is nil. The reliable callback is `viewDidMoveToWindow()` on the NSView subclass itself.

### 3. Minimal PATH in Finder-launched apps
Apps launched from Finder don't inherit the shell's PATH. The Claude CLI is a `#!/usr/bin/env node` script, so `node` must be on PATH. Need to construct a robust PATH that discovers nvm, homebrew, etc.

## Working Solution

### Fix 1: viewDidMoveToWindow on MonitoredTerminalView

Override `viewDidMoveToWindow()` in the NSView subclass to handle focus when the view is added to a window:

```swift
// MonitoredTerminalView.swift
override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window = window else { return }
    window.makeFirstResponder(self)
}
```

**Why this works**: `viewDidMoveToWindow()` is called exactly once when the view is added to a window hierarchy, guaranteeing that `window` is non-nil. This is the correct lifecycle hook for focus management.

### Fix 2: Direct return from NSViewRepresentable (no container)

Return the terminal view directly without wrapping it in a container:

```swift
private struct TerminalViewWrapper: NSViewRepresentable {
    let sessionManager: SessionManager
    let sessionId: UUID

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        guard let view = sessionManager.terminalViewPool[sessionId] else {
            return LocalProcessTerminalView(frame: .zero)
        }
        return view
    }

    func updateNSView(_ terminalView: LocalProcessTerminalView, context: Context) {
        // Focus managed by viewDidMoveToWindow — do NOT call makeFirstResponder here
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {
        // No-op: view pool retains the terminal view
    }
}
```

**Why this works**: Container views interrupt the responder chain. Returning the terminal view directly ensures keyboard events flow correctly from the SwiftUI hosting view to the terminal.

### Fix 3: NSApp.activate on launch

Force the application to take focus when launched:

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.activate(ignoringOtherApps: true)
}
```

**Why this works**: This ensures the app steals focus from other applications on launch, which is particularly important when testing.

### Fix 4: Robust PATH construction

Build a complete PATH that includes nvm, homebrew, and system directories:

```swift
private func buildRobustPath() -> String {
    let home = NSHomeDirectory()
    var components = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":").map(String.init)

    // Add Claude CLI's directory
    let claudeDir = (resolveClaudePath() as NSString).deletingLastPathComponent
    if !components.contains(claudeDir) { components.insert(claudeDir, at: 0) }

    // Discover nvm node versions
    let nvmBase = "\(home)/.nvm/versions/node"
    if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
        let sorted = versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        for v in sorted {
            let bin = "\(nvmBase)/\(v)/bin"
            if FileManager.default.isExecutableFile(atPath: "\(bin)/node") {
                if !components.contains(bin) { components.insert(bin, at: 0) }
                break
            }
        }
    }

    // Add homebrew, local bin, system essentials
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] {
        if FileManager.default.fileExists(atPath: dir) && !components.contains(dir) {
            components.append(dir)
        }
    }
    return components.joined(separator: ":")
}
```

**Why this works**: This proactively discovers common tool installation locations and constructs a complete PATH that works even when launched from Finder. It prioritizes the most recent nvm node version and includes the Claude CLI's own directory.

### Fix 5: Build as .app bundle (not swift run)

Created `scripts/build-app.sh` that produces a proper `.app` bundle with Info.plist, bundle identifier, and CFBundleExecutable.

**Why this works**: A proper `.app` bundle launched from Finder or directly behaves like a real macOS application. `swift run` keeps the terminal process attached, which interferes with keyboard focus management.

## Technical Details

### AppKit Responder Chain
In AppKit, keyboard events flow through the responder chain:
1. NSWindow receives key event
2. First responder (if set) gets the event
3. If not handled, event bubbles up the view hierarchy

SwiftUI's NSHostingView manages this automatically, but only if:
- The NSView is returned directly (no containers)
- Focus is set after the view has a window reference

### SwiftUI Lifecycle Timing
`updateNSView` is called:
- During initial layout (view may not have window yet)
- On every state change
- Multiple times per SwiftUI update cycle

`viewDidMoveToWindow` is called:
- Exactly once when added to window hierarchy
- Window property is guaranteed non-nil in the body

### macOS PATH Inheritance
- Terminal-launched apps: Inherit full shell PATH
- Finder-launched apps: Get minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)
- PTY child processes: Inherit from parent process environment

## Prevention Guidelines

### For Future Terminal Embedding
1. **Never use `swift run` for testing GUI macOS apps** that need keyboard input - always build a `.app` bundle
2. **Use `viewDidMoveToWindow()` for focus management**, not `updateNSView`
3. **Never wrap terminal/text-input NSView in a container** - return it directly from `makeNSView`
4. **Always construct PATH explicitly for PTY child processes** in macOS apps (don't rely on inherited env)

### For NSViewRepresentable in General
1. Use lifecycle methods on the NSView subclass for timing-sensitive operations
2. Keep `updateNSView` minimal and idempotent
3. Avoid container views unless absolutely necessary
4. Test as a real `.app` bundle, not via `swift run`

## Related Files

- `/Users/superuser/projects/code-portal/CodePortal/Views/MonitoredTerminalView.swift` - Terminal view with focus management
- `/Users/superuser/projects/code-portal/CodePortal/Views/ContentView.swift` - SwiftUI wrapper implementation
- `/Users/superuser/projects/code-portal/CodePortal/Managers/SessionManager.swift` - PATH construction logic
- `/Users/superuser/projects/code-portal/scripts/build-app.sh` - App bundle build script

## References

- [Apple Documentation: NSView.viewDidMoveToWindow()](https://developer.apple.com/documentation/appkit/nsview/1483490-viewdidmovetowindow)
- [Apple Documentation: NSResponder](https://developer.apple.com/documentation/appkit/nsresponder)
- [SwiftUI NSViewRepresentable Protocol](https://developer.apple.com/documentation/swiftui/nsviewrepresentable)
- [SwiftTerm LocalProcessTerminalView](https://github.com/migueldeicaza/SwiftTerm)
