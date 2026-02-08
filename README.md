# Code Portal

A native macOS desktop app for managing multiple [Claude Code](https://docs.anthropic.com/en/docs/claude-code) terminal sessions side by side.

Code Portal gives you a single window with a sidebar listing your repositories. Each repo runs its own Claude Code instance in a real terminal (powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)). Color-coded status indicators show you at a glance which sessions need your attention and which are still working.

Now you're thinking with portals.

## Download

Grab the latest DMG from [build/20/Code Portal.dmg](build/20/).

To build from source:

```
./scripts/build-app.sh
```

The build script produces both a `.app` bundle and a styled `.dmg` installer in `build/<number>/`.

## Features

- **Multi-repo sidebar** — Add repositories and switch between Claude Code sessions instantly. Sessions persist across app restarts.
- **Attention detection** — Sidebar indicators turn orange when Claude asks a question, requests permission, or finishes a task and is waiting for your next command. They turn green when Claude is actively working.
- **Real terminal** — Full PTY-backed terminal with keyboard input, ANSI rendering, scrollback, and mouse support. Not a stripped-down text view.
- **macOS notifications** — Get notified when a background session needs attention so you can keep working in another app.
- **Session persistence** — Your repo list and working directories are saved automatically and restored on launch.
- **Configurable CLI flags** — Set global or per-project flags passed to Claude Code on launch. Useful for `--model`, `--verbose`, `--permission-mode`, and other CLI options.

## CLI Flags

You can pass custom flags to the Claude Code CLI on a global or per-project basis.

**Global flags** apply to all projects. Open Settings (Cmd+,) and enter flags in the text field. Click Save to persist.

**Per-project flags** are appended after global flags and override them when there's a conflict. Right-click a project in the sidebar and choose "Edit Settings..." to configure. If the project has an active session, you'll be asked whether to restart it with the new flags.

Flags take effect on the next session start or restart. Examples:

```
--model opus
--verbose
--permission-mode bypassPermissions
--model sonnet --verbose
```

## How It Works

Claude Code is an Ink (React for CLI) TUI that renders via cursor repositioning rather than newline-delimited output. Code Portal reads SwiftTerm's parsed visible buffer on a debounced timer (500ms after the last output chunk) and scans for known attention patterns: permission prompts, multi-choice questions, and the idle input prompt.

## Requirements

- macOS 14.0+
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and available on `PATH`

Building from source also requires Swift 6.0+.

## Project Structure

```
Sources/
  CodePortalApp.swift          App entry point
  Managers/SessionManager.swift    Session lifecycle and terminal pool
  Models/TerminalSession.swift     Session state and event model
  Terminal/AttentionDetector.swift  Pure-function attention detection
  Terminal/MonitoredTerminalView.swift  SwiftTerm subclass with buffer scanning
  Views/ContentView.swift          Main split view
  Views/SettingsView.swift         Global settings (Cmd+,)
  Views/SidebarView.swift          Repo list with status indicators
  Views/SessionDetailView.swift    Terminal host view
Tests/
  AttentionDetectorTests.swift     60 tests for detection logic
```

## License

MIT License. See [LICENSE](LICENSE) for details.
