# Code Portal

A native macOS desktop app for managing multiple [Claude Code](https://docs.anthropic.com/en/docs/claude-code) terminal sessions side by side.

Code Portal gives you a single window with a sidebar listing your repositories. Each repo runs its own Claude Code instance in a real terminal (powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)). Color-coded status indicators show you at a glance which sessions need your attention and which are still working.

## Download

Grab the latest build from [build/12/Code Portal.app](build/12/).

To build from source:

```
./scripts/build-app.sh
```

The `.app` bundle will be output to `build/<number>/Code Portal.app` and revealed in Finder.

## Features

- **Multi-repo sidebar** — Add repositories and switch between Claude Code sessions instantly. Sessions persist across app restarts.
- **Attention detection** — Sidebar indicators turn orange when Claude asks a question, requests permission, or finishes a task and is waiting for your next command. They turn green when Claude is actively working.
- **Real terminal** — Full PTY-backed terminal with keyboard input, ANSI rendering, scrollback, and mouse support. Not a stripped-down text view.
- **macOS notifications** — Get notified when a background session needs attention so you can keep working in another app.
- **Session persistence** — Your repo list and working directories are saved automatically and restored on launch.

## How It Works

Claude Code is an Ink (React for CLI) TUI that renders via cursor repositioning rather than newline-delimited output. Code Portal reads SwiftTerm's parsed visible buffer on a debounced timer (500ms after the last output chunk) and scans for known attention patterns: permission prompts, multi-choice questions, and the idle input prompt.

## Requirements

- macOS 14.0+
- Swift 6.0+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and available on `PATH`

## Project Structure

```
Sources/
  CodePortalApp.swift          App entry point
  Managers/SessionManager.swift    Session lifecycle and terminal pool
  Models/TerminalSession.swift     Session state and event model
  Terminal/AttentionDetector.swift  Pure-function attention detection
  Terminal/MonitoredTerminalView.swift  SwiftTerm subclass with buffer scanning
  Views/ContentView.swift          Main split view
  Views/SidebarView.swift          Repo list with status indicators
  Views/SessionDetailView.swift    Terminal host view
Tests/
  AttentionDetectorTests.swift     60 tests for detection logic
```

## License

Private. Not yet open source.
