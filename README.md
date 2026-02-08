# Code Portal

A native macOS desktop app for managing multiple [Claude Code](https://docs.anthropic.com/en/docs/claude-code) terminal sessions side by side.

Code Portal gives you a single window with a sidebar listing your repositories. Each repo runs its own Claude Code instance in a real terminal (powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)). Color-coded status indicators show you at a glance which sessions need your attention and which are still working.

Now you're thinking with portals.

## Download

**[Download Code Portal.dmg](https://github.com/aenrichus/code-portal/raw/main/build/26/Code%20Portal.dmg)** (macOS 14.0+)

Open the DMG and drag Code Portal to your Applications folder. You'll also need [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and available on your PATH.

To build from source (requires Swift 6.0+):

```
./scripts/build-app.sh
```

## Release Notes

### v1.0.1 (Build 26)

- **About window** — Added About Code Portal panel (Code Portal menu > About Code Portal) with version info and attribution.
- **Permanent window title** — Toolbar now always shows "Code Portal" instead of the selected project name.
- **DMG volume icon** — The mounted DMG now shows the Code Portal icon instead of the default disk image icon.

### v1.0 (Build 20)

Initial public release.

- **Multi-repo session management** — Run multiple Claude Code instances side by side. Add repositories to the sidebar and switch between sessions instantly.
- **Attention detection** — Color-coded sidebar indicators show session state at a glance. Orange means Claude is asking a question, requesting permission, or waiting for input. Green means Claude is actively working. Gray means the session hasn't started yet.
- **Real terminal emulation** — Full PTY-backed terminal powered by SwiftTerm with keyboard input, ANSI color rendering, scrollback, and mouse support.
- **macOS notifications** — Get notified when a background session needs attention so you can keep working in another app.
- **Session persistence** — Your repo list and working directories are saved automatically and restored on launch.
- **Configurable CLI flags** — Set global flags (Cmd+,) or per-project flags (right-click > Edit Settings) passed to Claude Code on launch. Useful for `--model`, `--verbose`, `--permission-mode`, and other CLI options. Per-project flags are appended after global flags.
- **DMG installer** — Styled drag-to-install DMG with every build.

## Next Steps

- **Code signing** — Sign and notarize the app through the Apple Developer Program so users don't see Gatekeeper warnings on first launch.
- **Filesystem viewer** — Add a file browser panel so you can see which files are in the project folder without leaving the app.
- **Icon transparency** — Fix the app and DMG icon to use a proper transparent background instead of the current composited dark fill.

## How It Works

Claude Code is an Ink (React for CLI) TUI that renders via cursor repositioning rather than newline-delimited output. Code Portal reads SwiftTerm's parsed visible buffer on a debounced timer (500ms after the last output chunk) and scans for known attention patterns: permission prompts, multi-choice questions, and the idle input prompt.

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
