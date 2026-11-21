# Toasty — To Do

Features discussed but not built yet. Remove items as they ship. The
principles in `BUILD_PLAN.md` §1 still apply: Toasty renders and collects
input; Claude Code (via its own features) decides what Claude does.

## Claude Code / SDK version drift (soon)

Toasty runs the installed `claude` (terminal tabs and the bridge's
`pathToClaudeCodeExecutable`), so Claude Code updates reach Toasty on their
own. The Agent SDK is vendored and pinned
(`Resources/Bridge/claude-agent-sdk-VERSION.txt`: 0.3.330, built for
Claude Code 2.1.330). Both ship almost daily (19 releases Oct 14 - Nov 6),
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
- **Launch-test** a notarized Release build's dictation.
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

## Activity (inspector tab)

Built (2026-11-18): the inspector's fourth tab (⌃⌘4,
`Inspector/ActivityTab.swift`), for long runs where it's unclear whether
Claude is still alive. It follows the selected conversation and reads only
what Claude Code already sends (no tokens). Status: working / waiting for
you / idle / "No Activity for Nm" / "Claude Code Stopped", with this turn's
time, "Last heard from Claude" (any message from Claude Code, including
streamed text and `tool_progress` heartbeats) and tokens written. Now: each
running tool call with its clock, and a subagent's current step. In the
Background: `backgroundTasks` with running times; hover a row to stop it.
A `<task-notification>` in a resumed transcript now shows as a notice with
its summary, not as raw markup.

Not done:

- **Check it against real long runs.** It was checked with a made-up turn
  (`mctl liveness fake=working`, `quiet=`, `fake=stopped`), not a real long
  one. The quiet warning starts at 3 minutes (`ActivityTab.quietAfter`),
  a guess: confirm that long thinking, slow MCP tools and API retries
  don't go quiet that long, and raise it if they do.
- **Claude's to-do list** (`TodoWrite` / `TaskCreate`): "3 of 7 · current
  item" under the step. Left out (2026-11-18): progress is a nice-to-have
  next to liveness, and the tools may not exist for current models. Check
  a live session's init `tools` first; costs no tokens to show.
- **Stall and stopped in the conversation itself**, for when the inspector
  is on another tab. Offered 2026-11-18; the user chose the tab alone.

## Tee-Up (inspector tab)

Built (2026-11-18): the inspector's third tab (⌃⌘3, `TeeUp/`). Prompts
written ahead of time with pictures and files; each is sent to the open tab
(as if typed there) and leaves the list. Like a to-do app: every prompt is
a one-line card (a paperclip counts its attachments); clicking one opens it
in place to edit, and Return, Esc or a click elsewhere closes it (edits are
kept as typed; no save step). "New Prompt" under the cards, ⌃⌘3, or
files dropped on the tab add a card, open (left empty, it goes away). Drag to reorder; delete from the open card or
the context menu. The list is saved with the workspace; pictures are PNGs in `Application Support/<app>/TeeUps`.

### To decide after using it

- **Auto-Send (trial, 2026-11-18).** A bar under the
  list turns it on for the open tab, after a confirmation that names the
  tab, the count and its permission mode; it stays with that tab while you
  move around. Each prompt is sent when Claude
  finishes the one before, after a 5 s countdown, top to bottom. It pauses
  by itself on an error, an interrupt, a pending permission/question, a
  message typed in that tab, the next prompt being open for editing, the
  tab closing, or a relaunch. A card's menu holds it back ("Hold Back from
  Auto-Send"). While it has more to send, the tab it's feeding doesn't
  notify after each turn: only when it pauses ("Auto-Send paused", with
  the reason) and when the last prompt is done ("Auto-Send finished").
  Other tabs notify as usual.
- **Reply check (trial, 2026-11-18).** When a reply's
  last paragraph has a question, Auto-Send asks Claude Haiku (a one-turn,
  tool-less, unsaved query: the bridge's `ask`) whether Claude is waiting
  for an answer or only offering more, and pauses with what it needs.
  Settings ▸ Tee-Up: ask the small model (default), always pause, or keep
  sending. A failed or unclear check pauses. 36/36 on twelve sample
  replies ×3 once the instructions had examples (without them it flipped
  on wording changes). Takes 4–5 s, inside the countdown. Untested: a
  provider where the `haiku` alias doesn't resolve (it would pause).
- **Pause, Resume, Stop (2026-11-18).** Auto-Send is
  off, sending or paused. A pause (its own, or the Pause button) keeps the
  tab: Resume carries on without asking again, Stop turns it off. The
  reason for a pause, and what the reply check decided ("Claude's question
  was only an offer", shown through the countdown), have a line of their
  own under the bar. Decisions are logged (`category == "teeup"`). A draggable "stop here" line was the alternative to Hold.

- **Screenshots follow the cursor (trial, 2026-11-18).** ⇧⌘0 attaches to
  the prompt field that last had the text cursor: the composer or an open
  tee-up card (else the open conversation). Watch
  for: a screenshot landing in Tee-Up when the conversation was meant,
  because the cursor was left there.

- **Per workspace or per tab?** Per workspace today, shared by its tabs
  (worktrees have their own list, being workspaces).

### Ideas (not committed)

- **Tee up from the composer.** A key (⌥⏎?) that puts the composer's draft
  on the list instead of sending it.
- **Count on the tab button** while the list isn't empty and another
  inspector tab is showing.
- **Send the next one when Claude finishes** (a queue that runs itself).
- **Drag a row onto a tab** to send it there instead of the open one.

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

## Vibe-coding ideas (discussed 2026-11-21, not committed)

Judged by "does it make trying things cheaper without adding a screen?"

1. **Rewind.** Hover your own message → "Go Back to Here": restores files
   and the conversation to before that prompt. The SDK has it
   (`enableFileCheckpointing`, `rewindFiles`); check it works in SDK mode
   for current models first. Same row as "Fork from your own prompt".
2. **Errors go to Claude in one click.** A browser console error or a
   crashed dev server in a terminal shows a small "Send to Claude" chip that
   attaches the output. User-driven, so principle 3 holds.
3. **Run (⌘R).** Start the project's dev server (from `package.json`,
   etc.) in a terminal tab and open the browser on its port. Local
   Servers already tracks what's running.
4. **Turn summary.** At the end of a turn, one quiet line: "Changed 4 files
   +120 −30", clicking into the Changes tab's diffs. No tokens.
5. **New Project…** An empty folder, `git init`, a workspace and a
   conversation in one step.

Promote from other lists: Files in the @ menu; Tee up from the composer.

## Browser (experimental; was "Preview")

Built 2026-11-10 (`Toasty/Preview/`), off by default in Settings ▸ Browser.
The user may remove it again: everything outside that folder is listed at
the top of `PreviewSettings.swift`. Principles 1 and 2 in `BUILD_PLAN.md`
§1 carry the exceptions it needed.

Reworked 2026-11-20 (the user: the main window is the workspace for
conversations; the browser is a tool agents use without competing for room
or attention). It used to be a panel in the right column, with a desktop
page taking the whole window and the conversation becoming a drawer; all of
that is gone (`PreviewDrawer`, `MainContainerController`, the preview's turn
in the right column, ⇧⌘L, the phone column width).

What it is now: a browser per workspace (`PreviewSession`, a WKWebView with
its own data store: cookies, logins, storage, page state) that runs whether
anything shows it or not, and one native window (`PreviewWindowController`,
frame remembered) that shows one workspace's browser (the user,
2026-11-20: multiple isolated sessions, one shared presentation window; it
was one window per workspace for an afternoon). Which one is the window's
own choice (the user, 2026-11-20: the main window decides which conversation
I'm in, the browser which browser I'm inspecting; neither changes the
other): a menu in its toolbar (folder, name, chevron) lists the workspaces
whose browser has a page, and selecting a workspace in Toasty doesn't change
it. Asking for a workspace's browser from the main window does (its compass,
⇧⌘B, ⇧⌘C, a local link clicked in its terminal). The choice is kept across
launches (`PreviewWindowWorkspace`); first time, Toasty's selected workspace;
if it closes, another with a page, else Toasty's. Switching swaps which page
the window shows without reloading or navigating any of them.
Claude's tools reach their conversation's workspace's browser
(`PreviewTools.handle`), never "the one on view", so switching never changes
which browser an agent drives. Closing the window only hides it. Claude's
tools never open the window, bring it forward or take the keyboard
(`navigate` used to show the panel). No tabs: a testing and
inspection tool, not a general browser. Titlebar row: back (⌘[; no forward),
reload, the address (fills the room in a narrow window; at most 640
points, centered in the window, in a wide one), open in
the default browser at the right end. Footer: workspace, comment,
the iPhone/desktop toggle, show conversation, the size menu.
- The titlebar's compass, at the end of the conversation tabs, is the
  indicator: accent-colored and pulsing while Claude is using the browser
  (a call running, or one ended in the last 3 s), filled while the window
  is open on this workspace. A click shows the window on this workspace.
  ⇧⌘B (View ▸ Show Browser) and Window ▸ Browser go back to the window as
  it was left, on whatever workspace it shows (never opened: this one);
  the user, 2026-11-20: going back and showing this workspace's are two
  things, and no extra button for it. In the window:
  ⇧⌘B or ⌘W hides it, ⌘R reloads, ⌘L goes to the address, ⇧⌘M switches
  phone/desktop (and sizes the window for it; Claude's `set_viewport`
  never moves the window), ⇧⌘C comments.
- Its titlebar row is Toasty's own, built as the main window's
  (`PreviewBar`, hosted in the titlebar view, on the window buttons' line):
  `BarIconButton`s, Toasty's tooltips, the workspace chip opening
  `PopoverMenu`, the address in a `Theme.Fill.subtle` capsule, the chrome
  color and bar divider (the user, 2026-11-20: match the rest of the app
  before it ships). It was an AppKit `NSToolbar` with Liquid Glass capsules
  for an afternoon. The row has only what a browser has: back, reload,
  the address. Everything else is in a footer built as the composer's
  control row (the user, 2026-11-20): the workspace chip on the left;
  comment, phone/desktop and show the conversation (the one whose Claude last used this browser, else the
  workspace's selected tab) as wide icon buttons in the middle; the page's
  size on the right (dropped when there's no room). The window is never
  narrower than a phone page with a margin (460 × 560 content minimum); a
  short window gives the page less height and it scrolls.
- While Claude uses a page whose window is closed, the page waits in
  `PreviewBackstage`: a 1-point, transparent, click-through window. Out of
  any window WebKit runs a page as hidden: no requestAnimationFrame at all
  and throttled timers, so animated UIs never settle. In the backstage it's
  visible to WebKit (60 fps rAF, full-rate timers, measured 2026-11-20).
  When Claude goes idle the page leaves it and is throttled again. A call
  that has just put a page there waits (up to ~0.5 s) for WebKit to report
  it visible; without that the first call saw a hidden page. Pages of
  workspaces that aren't on view use the backstage the same way.
- Comment mode works in the window as before; Esc or sending a comment keeps
  the keyboard in the browser window (it used to go back to the composer).
  A comment to the conversation goes to the tab last selected in the
  workspace the browser shows (not necessarily the one on screen in
  Toasty). When that workspace has more than one tab, the comment field
  shows that tab as a chip; clicking it lists the workspace's tabs to send
  to another (the user, 2026-11-20). The pick lasts until commenting ends
  and never selects the tab in Toasty. Tee-Up is the workspace's, so no
  chip there.
- A local link clicked in a terminal opens in the workspace's browser, and
  the window comes forward showing it (that's the user's own click). The page reloads
  whenever Claude finishes a turn in the workspace. Claude gets an MCP
  server `preview` (navigate, screenshot, read_console, set_viewport,
  evaluate, click, type) in conversations started while it's on, relayed
  through the bridge; its instructions say the window may be hidden.
- iPhone (402×874) or iPhone Pro Max (440×956), both with an iPhone user
  agent, or desktop (the user, 2026-11-20: just those two phones; no
  iPads or particular Macs). The footer's icon toggles iPhone/desktop
  (⇧⌘M); the size at its right end is a menu: which iPhone, or desktop
  presets (1280×800, 1440×900, 1920×1080; those bigger than the screen
  dimmed). A desktop page is the window's page area, sized by dragging the
  window as in any browser; switching to an iPhone keeps the desktop
  window's frame and switching back restores it (`PreviewDesktopFrame`).
  With no window open a desktop page is 1280×800. The size menu is always
  shown whole (the window's 460-point minimum leaves room for it); the
  workspace chip (the name and a chevron, no icon) gives up room first:
  shorter and shorter names. A phone is laid out at
  its real width and drawn smaller in a narrow window.
- Side by side (the user, 2026-11-20, for a big monitor: one page at both
  sizes, one address bar): a footer button (laptop and phone) shows the
  desktop page with the iPhone page in a column to its right, and the
  window grows by that column so the desktop page keeps its width (and
  gives it back when turned off). The phone is a second web view (`twin`
  in `PreviewSession`) on the workspace's data store, so one login. The
  address, back and reload (and the reload at the end of a turn) drive
  both; a page either one goes to, the other follows (a load that's
  following the other page doesn't lead back until it ends, so redirects
  can't ping-pong). In side by side the footer has a second size menu,
  which iPhone (kept per workspace; also the phone ⇧⌘M goes to); the
  window changes width with it. Claude's tools, the console and comments
  stay with the desktop page; choosing a phone (⇧⌘M, or Claude's
  `set_viewport`) ends side by side. A page that can't open leaves the
  phone column empty. Not yet: comments on the phone page, a screenshot of
  both for Claude, scroll sync (the layouts differ; probably never).
  Comments (⇧⌘C): click an element or drag an area, type a note; Return
  sends to the conversation or Tee-Up per Settings ▸ Browser ▸ Comments,
  Shift-Return the other way.

Not done / to decide after living with it:
- The indicator shows only the workspace on screen; Claude using the
  browser in a background workspace shows nowhere (the sidebar could).
- A page's alert/confirm/prompt is a sheet only while its window is open
  and Toasty is in front; otherwise it's dismissed and noted in the console.
- Whether the window was open isn't remembered across launches.
- Turning the setting on or off reaches running conversations only when
  they restart (the SDK's `setMcpServers` could do it live).
- No console view for the user (right-click ▸ Inspect Element opens
  Safari's Web Inspector if that's enabled). No forward button
  (two-finger swipe works). No touch emulation.
- Chromium-only bugs: the footer's "Open in <default browser>".
- Comments carry a selector, not source file and line.

## Screenshots from any app (⇧⌘0)

Built 2026-11-10 (`Toasty/Screenshot/`): ⇧⌘0 in any app runs the system's
area/window picker and attaches the picture to the open conversation's
composer. It doesn't send, and Toasty stays in the background so several
can be taken (the user's choices). Nothing is saved: the file
`screencapture` writes is read and deleted at once. Settings ▸ Screenshots
turns the any-app shortcut off (then it works only in Toasty). Needs Screen
Recording permission.

Not done / to decide after living with it:
- The real capture (drag, permission prompt) has only been tried by the
  user, not by a test; `mctl screenshotAttach path=…` covers delivery.
- The shortcut can't be changed (no shortcut recorder in Settings).
- No sign in Toasty that a screenshot arrived while it's in the background,
  beyond the system's shutter sound.
- Whether macOS asks again for Screen Recording every so often.
- Reliability (2026-11-10): Toasty Debug's shortcut is ⌃⇧⌘0, because two
  apps registering the same one both succeed and only one gets the press.
  Every step is logged (`/usr/bin/log show --last 10m --predicate
  'category == "screenshot"'`). Screen Recording is granted per app: Toasty
  and Toasty Debug each need it, and a relaunch after granting. Still open:
  the first press after granting without relaunching, and a press with no
  conversation open only beeps.

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
- **Background tasks panel.** Built so far: the line above the composer
  (`background_tasks_changed`, click to `stopTask`), and what Claude leaves
  running stops when its conversation closes (BUILD_PLAN §7). Not built: a
  list in the inspector (discussed 2026-11-10 and dropped in favor of
  Window ▸ Local Servers; bring it back if servers running unseen while a
  workspace is open turn out to bite; the Activity tab now lists the
  selected conversation's tasks), the line staying up during a turn,
  `agentProgressSummaries` for one-line progress, `backgroundTasks()` to
  move a running Bash or subagent to the background (the CLI's Ctrl-B).
- **Local Servers follow-ups.** The preview's address field could offer the
  ports found; a row could name the Toasty workspace or conversation that
  started its server (the tag says which).
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
