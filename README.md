# Claude Deck

A Mac app that lists your local Claude Code sessions, shows which ones are waiting on you,
lets you read each transcript live, send messages, and jump to the session's terminal.

## Why Claude Deck

- **You stay terminal-first.** Deck sits on top of the Claude Code sessions you already run in
  Ghostty, with no change in how you start or use them.
- **Fast keyboard approvals from any app.** ⌥⌘↩ approves the next waiting prompt while you're
  working in another session, with a check that it's the prompt you meant. Plus the menu bar,
  notifications with Allow / Deny, and a Dock badge.
- **Everything stays local.** It reads files on your Mac and talks to nothing on the network.
- **It's yours to shape.** Your skills, project commands, plan usage and shortcuts are all built
  around how you work, and you can change anything in an afternoon.

## Install

    ./build.sh            # builds build/Claude Deck.app
    ./build.sh --install  # also copies it to /Applications

## How it works

- Running sessions and their status (`busy` / `idle` / `waiting` + `waitingFor`) come from `~/.claude/sessions/<pid>.json`.
- Transcripts are tailed from `~/.claude/projects/<cwd>/<sessionId>.jsonl`.
- Sending messages, approving/denying prompts, and "Open Terminal" drive Ghostty 1.3+ over AppleScript.
  A session's terminal must be in the session's folder and show a Claude title; its title picks between several.
- Ended sessions from the last 7 days can be reopened with "Resume in Ghostty".
- **New session** (toolbar +, ⌘N) opens a Ghostty window in a folder and starts `claude`.
- File edits show as diffs: Edit / MultiEdit / Write rows show `+added −removed`, expand to a
  red/green line diff, and edit permission prompts show the diff you're approving.
- Plan usage at a glance: session % in the menu bar, and session / week bars in the sidebar and
  menu bar panel (refreshed every 5 minutes; click for details).
  Clicking a skill puts its `/command` in the message box.
- Typing `/` lists every command (custom, skills, built-ins). Built-ins are handled by kind: most
  are sent as typed (their output appears in the transcript); ones that open a menu (`/model`,
  `/mcp`, `/config`…) bring the terminal forward; `/usage` (or ⇧⌘U) shows your plan limits in Deck.

## Activity: PRs, tickets and screenshots

Each session shows what it's **working on** (the ticket and PR, with live status) above the
conversation, and an **Activity** tab (⌥⌘A) with everything it did: PRs opened, reviewed, merged or
commented on, Linear tickets created, updated or looked at, and screenshots it reviewed. **Activity
History** (⇧⌘H) lists the same across every session, searchable, with a one-click **Today's
Digest** (a standup note).

- Found in the transcripts Deck already reads: `gh pr …` commands that actually ran (not ones a
  script merely mentions), `gh api` review posts, Linear tool calls, Claude Code's PR links, your
  Linear links, and screenshot tools. Labels say exactly what happened ("Looked at", "Reviewed").
- Indexed in the background and saved in `~/Library/Application Support/ClaudeDeck/activity`, so
  only new lines are read and history outlives Claude Code's transcript cleanup.
- PR titles and status (Open, Merged, Closed, Draft) come from `gh pr view`.
- **AI summaries** (on by default; toggle in History or the Sessions menu): one-line summaries,
  session recaps and the digest are written by Claude Haiku through your own `claude` login, as
  headless, tool-less, unsaved runs, in batches, only when you're not typing, at most 150 small
  calls a day. Off, the summary is Claude's own sentence from right after the action.

## Search: ⌘K

One palette for everything. Type a session's name to jump to it, or anything else to search your
own messages, PR and ticket titles, commits, branches and session names (instant, on your Mac,
typo-tolerant). With nothing typed it shows your sessions and recent activity. **⌘↩** (or the
*Ask Claude* row) asks a question in plain words, e.g. *"on which session did I start the AppSumo
integration?"*: Claude Haiku turns it into a search (fixing typos, adding related words, first vs
latest), Deck searches locally, and Haiku answers with the session and moment. ↩ on any match opens
the session right there, even in a long or old transcript ("Back to Latest" returns to the live end).

## Safety

- Messages are *typed* (Ghostty's `text:` action), not pasted, so Claude treats them as yours.
- Deck never types while Claude shows a prompt, and only answers the exact prompt you saw
  (re-checked from the session's record right before pressing a key).
- Before every action, the target terminal is re-checked (same folder, Claude title).
- One-click Allow (and ⌥⌘↩) only when Deck knows the exact request and the dialog is the standard
  Yes / Always / No; everything else is answered in the terminal.
- Transcript links open only http(s) and mailto. Session ids are validated and folders quoted
  before anything reaches a shell. Captured requests are deleted once their prompt is gone, and
  staged images and files after a day.

## Keyboard shortcuts

All of these are also listed in the **Sessions** menu.

| Shortcut | Action |
|---|---|
| ⌘K | Jump to a session, search everything, or ask (⌘↩) |
| ⇧⌘Space | Bring Deck forward with the switcher open, from any app |
| ⌥⌘↩ | Allow the next permission prompt, from any app (selected session first, else the longest-waiting) |
| ⌥⌘⌫ | Deny the next permission prompt, from any app |
| ⇧⌘D | Show / hide the floating dock: an always-on-top pill with a spinner per working session and one-click Allow / Deny for waiting prompts (over any app, even full-screen video); hover to expand or hide |
| ⌘J | Next session that needs you |
| ⌘1 – ⌘9 | Go to running session 1–9 (the number shown next to it; numbers never change while it runs) |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next session |
| ⌘R | Rename the selected session |
| ⌥⌘R | Restart the selected session (quits and resumes Claude in the same terminal, so new skills, MCP servers and settings load; it keeps its number) |
| ⇧⌘T | Open the selected session's terminal |
| ⌥⌘A | Switch the open session between Conversation and Activity |
| ⇧⌘H | Activity History: every PR, ticket, push and screenshot across sessions |
| ⌘. | Stop Claude's current step (also the Stop button on the "Working…" pill) |
| ↩ | Send message |
| ⇧↩ / ⌘↩ | New line in the message |

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
