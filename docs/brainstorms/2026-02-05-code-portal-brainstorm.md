---
date: 2026-02-05
topic: code-portal
---

# Code Portal — Claude Code Desktop App for Mac

## What We're Building

A native macOS desktop app (Swift + SwiftUI) that provides a multi-repo interface for Claude Code CLI. The app features a sidebar listing repos and a main content area with an embedded terminal emulator running a Claude Code session per repo. Users can work across multiple projects simultaneously without managing separate terminal windows.

The app provides macOS-native notifications (dock badge, notification center, sidebar indicators) whenever a Claude Code session needs attention — input prompts, permission requests, errors, or task completion.

Repos are added manually via a file picker or cloned directly from GitHub within the app.

## Why This Approach

**Chosen: SwiftUI + PTY Shell (Approach A)**

Three approaches were considered:

1. **SwiftUI + PTY Shell** (chosen) — Embed real PTY sessions with a terminal emulator view. Simplest path, preserves the raw CLI experience, and leverages SwiftTerm for terminal rendering.
2. **SwiftUI + JSON streaming** — Use Claude Code's `--output-format stream-json` for structured events. Richer UI potential but loses the raw terminal feel and complicates interactive input.
3. **Hybrid PTY + JSON sidecar** — Both terminal and structured events. Most capable but unnecessarily complex for v1.

Approach A was chosen because:
- It delivers both core goals (native Mac UX + multi-repo management) with the least complexity
- PTY gives the authentic Claude Code experience with no abstraction leaks
- Terminal emulation is a solved problem via SwiftTerm
- Notification detection can start with output pattern matching and evolve later
- YAGNI: structured JSON parsing can be added later if heuristic parsing proves insufficient

## Key Decisions

- **Tech stack**: Swift + SwiftUI, fully native macOS app
- **Terminal**: Real PTY sessions using SwiftTerm (or similar) for terminal emulation
- **Architecture**: Each repo gets its own `Process` + PTY pair running `claude` in the repo directory
- **Notifications**: Monitor PTY output for attention-needed patterns (prompts, idle, errors); surface via `UNUserNotificationCenter` + dock badge + sidebar indicators
- **Repo management**: Manual addition via file picker + GitHub clone support (via `git clone`)
- **Multi-session**: All sessions run concurrently; sidebar shows status per repo
- **Terminal first, polish later**: Start with raw terminal emulator, consider chat-style refinements in future versions

## Open Questions

- Which terminal emulation library to use? SwiftTerm is the leading option but needs evaluation
- Exact patterns to detect "needs attention" states from Claude Code output — may need experimentation
- Should the app persist session state across restarts, or start fresh each launch?
- GitHub clone: authenticate via `gh` CLI, SSH keys, or personal access tokens?
- Window management: single window with sidebar, or support detaching repos into separate windows?

## Next Steps

-> `/workflows:plan` for implementation details
