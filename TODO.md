# Toasty — To Do

Features discussed but not built yet. Remove items as they ship. The
principles in `BUILD_PLAN.md` §1 still apply: Toasty renders and collects
input; Claude Code (via its own features) decides what Claude does.

## Claude Code / SDK version drift (soon)

Toasty runs the installed `claude` (terminal tabs and the bridge's
`pathToClaudeCodeExecutable`), so Claude Code updates reach Toasty on their
own. The Agent SDK is vendored and pinned
(`Resources/Bridge/claude-agent-sdk-VERSION.txt`: 0.3.319, built for
Claude Code 2.1.319). Both ship almost daily (19 releases Oct 14 - Nov 6),
so a build falls behind within days.

Decided 2026-11-09: the SDK updates itself to match the installed `claude`;
a daily cloud routine ("Toasty SDK changelog watch") reads the SDK
changelog and emails only when something breaks Toasty or is worth
adopting. Its instructions hold a USES / CONSIDERING list; update it when
Toasty starts using a new SDK option, message or hook.

### Built: SDK auto-update (2026-11-09)

`Claude/ClaudeSDK.swift`: when a conversation tab starts it gets the best
SDK on disk; a background check downloads the newest SDK built for a Claude
Code <= the installed `claude` (npm checksum, `manifest.json`, bridge
`selftest`) into `~/Library/Application Support/<app>/SDK/` for the next
tab. A downloaded SDK that dies before Claude Code answers: the tab restarts
once on the next one and the transcript says so; that version is marked
bad. About shows the versions. Debug: `mctl '{"cmd":"sdk"}'` (actions
`refresh`, `installBroken`, `reset`); `TEST_RUNNER_TOASTY_NETWORK_TESTS=1`
runs the real-download test.

Follow-ups:
- **Fallback in the sidebar?** Shown in the tab's transcript today; a
  Notifications row would need a notice not tied to a conversation.
- **Release line change.** Auto-update only follows the bundled SDK's line
  (0.3.x for Claude Code 2.1.x). If Claude Code moves to 2.2, nothing
  downloads until the bundled SDK is updated (the changelog routine should
  flag that release).

### Also

- **Transcript files** are read directly (`ClaudeConversation.swift`,
  peer `isMeta` entries, session titles) and aren't covered by the SDK
  changelog. Move to `getSessionMessages` / `listSessions` where possible.

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
- **Notification shortcut (trial).** ⌘1–9 open the nth row of the
  Notifications list (2026-11-08); workspaces and tabs have no number
  keys (⌥⌘↑/↓ and ⌥⌘←/→ instead; ⌥1–9 removed 2026-11-09). Watch for: the list reorders, so a
  number doesn't keep pointing at the same item. If that bites, fall back
  to ⌘1–9 = workspaces and an easier "next needing me" key.
- **Crash rows.** "Claude Code stopped unexpectedly" (agent exit) doesn't
  notify today, so it never gets a row.

## Git worktrees

Built 2026-11-08 (`Workspaces/Worktrees.swift`): New Worktree… (workspace
context menu, ⇧⌘N) → `~/Toasty Worktrees/<repo>/<branch>`, ignored files
copied (folders skipped, `.worktreeinclude` adds more), nested under the
parent, worktrees made outside Toasty discovered; Remove Worktree… deletes
the folder and branch after one confirmation that says what will be lost.

Later:
- "Install Dependencies" button for a worktree: detect the package manager
  from the lockfile (npm/pnpm/yarn/bun, uv/poetry, bundler, SwiftPM) and run
  the install in the worktree's terminal tab so the output is visible.

## Preview browser (experimental)

Built 2026-11-10 (`Toasty/Preview/`), off by default in Settings ▸ Preview.
The user may remove it again: everything outside that folder is listed at
the top of `PreviewSettings.swift`. Principles 1 and 2 in `BUILD_PLAN.md`
§1 carry the exceptions it needed.

What it is: a WKWebView in a right-hand panel of its own (⌃⌘P, or the
compass button in the titlebar), one per workspace with its own cookies,
for the site being developed. It and the inspector/terminal column are
never open together: showing one swaps the other out, and closing the
preview brings back what was there. It always opens at full width, with the
conversation at its minimum, and its controls sit in the titlebar row above
it (the user's layout, 2026-11-10; it began as an inspector tab).
While it's open the workspaces sidebar collapses to give the page its room
(Settings ▸ Preview can turn that off), and ⌃⌘S floats the sidebar over
the conversation until a workspace or conversation is picked, Esc, or a
click elsewhere (`PreviewSidebarPanel`). Resting the pointer on the window's
left edge (0.15 s) slides it out too, and then it also leaves when the
pointer does. Discussed and left for later: moving the activity toast to
the upper-left while the preview is open. Phone (390×844,
iPhone user agent) or desktop (1280 wide) size; the page is always laid out
at its real width and drawn smaller in a narrow column. Comment mode: click
an element or drag an area, type a note, and a screenshot plus one line
(selector, viewport, URL) go to the open conversation. Return sends it at
once as its own prompt (the user's choice 2026-11-10, "experiment with it");
Shift-Return adds it to the composer instead, to send several together.
The page reloads whenever Claude finishes a turn in the workspace.
Claude gets an MCP server `preview` (navigate, screenshot, read_console,
set_viewport, evaluate, click, type) in conversations started while it's
on, relayed through the bridge. "Open in <default browser>" in the toolbar.
The start screen offers local addresses the workspace's terminals printed,
and a local link (localhost, an IP address, `.local`) clicked in a terminal
opens in the preview; named sites still go to the default browser.

Not done / to decide after living with it:
- Turning the setting on or off reaches running conversations only when
  they restart (the SDK's `setMcpServers` could do it live).
- No console view for the user (Claude has `read_console`; right-click ▸
  Inspect Element opens Safari's Web Inspector if that's enabled).
- Whether the preview is showing isn't remembered across launches.
- Claude's `navigate` opens the panel (and so narrows the conversation) in
  the workspace on screen; may want to be less forceful.
- No touch emulation, no back/forward buttons (two-finger swipe works), no
  shortcut for comment mode.
- A page in a workspace that isn't on screen runs as a hidden page (timers
  slow down); screenshots and scripts still work.
- Chromium-only bugs: "Open in Chrome" is the answer for now. A headless
  Chrome over CDP was considered and left out.
- Comments carry a selector, not source file and line.

## SDK hooks & callbacks (considerations)

Not committed: options worth weighing, checked against the SDK docs for
0.3.319 on 2026-11-09 (https://code.claude.com/docs/en/agent-sdk/typescript,
.../agent-sdk/hooks). The bridge (`toasty-agent.mjs`) registers no `hooks`
today. SDK hooks run alongside the user's own settings hooks, not instead
of them. Rough order of value:

- **`onElicitation`.** MCP servers asking the user for input (forms,
  sign-in links) have no handler in Toasty, so they likely fail where the
  CLI would ask. More a correctness gap than a feature.
- **`session_state_changed`** (idle / running / requires_action) as the
  source for sidebar status instead of inferring it. Needs
  `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1`.
- **Background tasks panel.** `task_started` / `task_progress` /
  `task_notification` + `background_tasks_changed` (full live set; replace
  the cache), `agentProgressSummaries` for one-line progress,
  `stopTask(id)` per row, `backgroundTasks()` to move a running Bash or
  subagent to the background (the CLI's Ctrl-B).
- **Undo Claude's edits.** `enableFileCheckpointing` + `rewindFiles(uuid)`;
  pairs with Fork. The `replay-user-messages` prerequisite is already on.
  Only reverts Write/Edit/NotebookEdit: not Bash changes, most subagent
  edits, or folder create/delete, so label it "Undo Claude's edits", not
  "Restore". After the stream ends, resume with an empty prompt first.
- **Live files-touched list.** `PostToolUse` on Edit/Write/MultiEdit feeds
  the Changes header the moment each edit lands (no git polling); rows
  jump to the diff.
- **Terminal context on send.** `UserPromptSubmit` → `additionalContext`
  with the last command + output from the workspace's terminal tab, so
  "fix this" after a failed build needs no paste.
- **Next-prompt ghost text.** `promptSuggestions` → `prompt_suggestion`
  after each turn; show in the composer, Tab accepts.
- **Model fallback notice.** `PostModelSwitch` fires on fallback too; say
  "Fell back to X" instead of switching silently.
- **Question previews.** `toolConfig.askUserQuestion.previewFormat`
  (markdown/html) for side-by-side option previews in the question card.
- **MCP panel.** `mcpServerStatus()`, `toggleMcpServer()`,
  `reconnectMcpServer()`: per-server status, toggle, reconnect.
- **User hooks visible.** `includeHookEvents` → `hook_started` /
  `hook_response`, to explain "stuck" turns caused by a slow settings hook.
- **`conversation_reset`** (sent on `/clear`): check the transcript clears.
- **Bash in a real terminal (speculative).** `PreToolUse` + `updatedInput`
  to route long-running commands (dev servers, watchers) into a Toasty
  terminal tab.

Skip unless a need appears: `MessageDisplay` (display-only rewrite; Toasty
renders its own transcript), `PreModelSwitch`, `DirectoryAdded`,
`Notification` (canUseTool covers prompts), `Setup`, `ConfigChange`,
`InstructionsLoaded`, `TeammateIdle`, `Task*` hooks, `FileChanged`,
`CwdChanged`, `Worktree*` (unless routing Claude Code's worktrees through
Toasty's). `onUserDialog` exists in the SDK code but isn't documented.

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
