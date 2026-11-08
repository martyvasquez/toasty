# Toasty — To Do

Features discussed but not built yet. Remove items as they ship. The
principles in `BUILD_PLAN.md` §1 still apply: Toasty renders and collects
input; Claude Code (via its own features) decides what Claude does.

## Messaging between tabs

Built so far: Fork (from any reply), tab names = Claude Code session names,
incoming "Message from @name" rows, the @ menu.

### Next

- **Clickable sender.** Clicking "Message from @Fuji research" jumps to that
  tab (when it's open), like the "Forked from" line does.
- **"Sent to" rows.** When Claude sends a message, the sender's transcript
  shows a generic `SendMessage` tool line. Show "Sent to @name" in the same
  quiet style as incoming messages, expandable to the text.
- **Hand-off.** Fork, then run `/compact` in the new tab, so it starts from
  Claude Code's own summary of the conversation. Cheap now that Fork exists.
- **Background-tab alerts.** A tab that receives a message while you're
  elsewhere should get the same dot/notification as "reply finished". Check
  what already happens when the message's turn ends before adding anything.

### Gaps to look into

- **Held messages.** When tabs use different permission-mode classes
  (bypass vs prompting), Claude Code holds incoming messages for approval.
  Toasty can't show that prompt, so they expire silently after
  `dialogExpiry` (5 min). First find out whether the SDK reports held
  messages at all; if it doesn't, document the limitation instead.
- **"Waiting to be delivered."** A message to a busy tab waits for its next
  tool call. Claude Code shows this state in the terminal (v2.1.309+);
  Toasty shows nothing.
- **Idle notices.** Claude can ask another tab to report when it finishes
  (`SendMessage` with `notify_when_idle`). Toasty likely hides the notice as
  internal context; check and render it.

### Ideas (not committed)

- **Fork from your own prompt** ("edit and retry"): go back to before a
  prompt and try something else.
- **Files in the @ menu**, like the CLI's `@` file mentions.
- **@ in the middle of text.** The menu only opens for an `@` at the end of
  the draft.
- **Side-by-side tabs** for watching two tabs talk (e.g. a debate). Only if
  that turns out to be something you actually do.
- **Send to tab / broadcast / gathered replies**, user-driven ways to move
  text between tabs. Mostly covered by @ messaging now; probably drop.

## Dictation

Shipped on `main`; documented in `docs/DICTATION.md`.

### Next

- **Key-press clock check** with real Right Option presses (needs the
  user: compare `lastPressHandledAfterMs` in `dictationState`).
- **Notarize** the release (needs the `toasty-notary` keychain profile),
  then launch-test the Release build.
- **Large repos:** spoken-path matching scans every file and folder per
  dictation; index by last segment if a monorepo feels slow.
- **About panel (pre-existing):** the dark-mode icon is a placeholder in the
  Debug build; the first credit line wraps ("SDK." alone).

### Later / ideas

- **Casing commands** ("snake case foo bar", "camel case …"): need an end
  delimiter; rarely needed in prompts (plan §10.2, deferred).
- **Spoken numbers in names**: "Swift Six" → "Swift 6".
- **Growing release tail** (up to 600 ms while still speaking; Hex).
- **Closed-lid rule**: skip the built-in mic while a MacBook's lid is closed (Hex).
- **Live text while speaking** (Parakeet v2 can't stream; re-run on the
  growing buffer, or a streaming model after a license review).

## Notifications (sidebar)

Built: the "Notifications" section at the bottom of the workspaces sidebar
(`Notifications/NotificationsSection.swift`, `Activity.notices`). A to-do
list derived from live state, not a log: waiting rows (permission,
question, plan) leave when answered; finished/stopped rows leave when the
tab is seen or dismissed.

### Ideas (not committed)

- **Slimmer workspace rows.** The status subtitle on workspace rows now
  partly repeats the list; rows could drop to the status icon only.
- **Keyboard shortcuts (undecided).** Maybe ⌘1–9 go to notifications
  instead of tabs. Caution: the list reorders and shrinks, so a number
  doesn't keep pointing at the same item. Alternatives: ⌃⌘U cycles through
  the list in order, or one key focuses the list for arrows + Return.
  Decide after living with the list.
- **Crash rows.** "Claude Code stopped unexpectedly" (agent exit) doesn't
  notify today, so it never gets a row.

## Git worktrees (next sprint)

Right-click a workspace → "New Worktree…" (branch name; new branch from
HEAD by default) → `git worktree add` → a workspace nested under its parent
with a fresh Claude tab. A worktree is a `Workspace` with a parent link;
tabs, terminal, Changes and sessions already work off the folder, and
`refreshBranch()` already reads a worktree's `.git` file.

Agreed (2026-11-08):
- Location: Claude Code's convention, `<repo>/.claude/worktrees/<name>`
  (needs to be gitignored).
- Worktrees made outside Toasty (`git worktree list`) show up automatically.
- Notification rows gain the worktree name.

Open:
- Removing: confirm; git refuses with uncommitted changes; delete the
  branch or not. Merging stays with the user/Claude (no button).
- Ignored files (`node_modules`, `.env`): check Claude Code's
  `.worktreeinclude` and `WorktreeCreate` hooks; Toasty running git itself
  would bypass hooks.
- Collapsed parent shows the strongest status of its worktrees.

## Reference

- Cross-session messaging docs:
  https://code.claude.com/docs/en/cross-session-messaging
- A peer message reaches Toasty as a user message whose `origin` is
  `{kind: "peer", name, body}`: live via `--replay-user-messages` (on in the
  bridge), and in transcripts as an `isMeta` user entry.
- Claude Code's own title for a session is written to the transcript as an
  `ai-title` entry (not sent on the stream); `/rename` changes a running
  session's address immediately, the SDK's `renameSession` only on its next
  start.
