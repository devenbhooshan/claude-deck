# Claude Deck

A Mac app that lists your local Claude Code sessions, shows which ones are waiting on you,
lets you read each transcript live, send messages, and jump to the session's terminal.

    ./build.sh            # builds build/Claude Deck.app
    ./build.sh --install  # also copies it to /Applications

How it works:
- Running sessions and their status (`busy` / `idle` / `waiting` + `waitingFor`) come from `~/.claude/sessions/<pid>.json`.
- Transcripts are tailed from `~/.claude/projects/<cwd>/<sessionId>.jsonl`.
- Sending messages, approving/denying prompts, and "Open Terminal" drive Ghostty 1.3+ over AppleScript.
  The session's terminal is matched by Claude's terminal title (its ai-title), falling back to the working directory.
- Ended sessions from the last 7 days can be reopened with "Resume in Ghostty".

## Keyboard shortcuts

All of these are also listed in the **Sessions** menu.

| Shortcut | Action |
|---|---|
| ⌘K | Jump to a session (type to filter, ↑/↓, Return) |
| ⇧⌘Space | Bring Deck forward with the switcher open, from any app |
| ⌥⌘↩ | Allow the next permission prompt, from any app (selected session first, else the longest-waiting) |
| ⌥⌘⌫ | Deny the next permission prompt, from any app |
| ⌘J | Next session that needs you |
| ⌘1 – ⌘9 | Go to session 1–9 (sidebar order) |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next session |
| ⌘R | Rename the selected session |
| ⇧⌘T | Open the selected session's terminal |
| ⌘↩ | Send message |

## Tests

    ./test.sh

All logic lives in `Sources/ClaudeDeck/Core` (transcript parsing, Markdown, session loading,
navigation and approval targeting, terminal matching, permission-request capture, attachments,
export, and the transcript renderer). `test.sh` compiles Core with `Tests/` into a runner, measures
coverage with `llvm-cov`, and **fails unless every line of Core is covered**. It needs only the
Command Line Tools, since XCTest and Swift Testing ship with full Xcode. Tests use a temporary
folder, never your real `~/.claude`.

The rest of `Sources/ClaudeDeck` is SwiftUI views and glue (AppleScript calls into Ghostty, global
hotkeys, notifications), which isn't unit-tested.
