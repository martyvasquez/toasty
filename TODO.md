# Toasty — To Do

Features discussed but not built yet. Remove items as they ship. The
principles in `BUILD_PLAN.md` §1 still apply: Toasty renders and collects
input; Claude Code (via its own features) decides what Claude does.

## Widgets (follow-ups, 2026-11-22)

The inspector is gone; its tools are widgets in spaces (`Toasty/Widgets`).
Merging the Widgets branch is a one-time switchover: everyone gets the
default spaces (Git; Tee-Up; Usage + Activity), widgets showing even where
the inspector was hidden, terminal at 320pt. Saved spaces are kept after
that, so any change to the defaults only reaches new users.

- **Drag the gallery's preview** to place a new widget. Today the blue
  outline in the column is what you drag; the canvas drags the preview.
- **Hand-check what mctl can't drive**: synthetic drags don't reach
  SwiftUI gestures, so check by hand: swipe between spaces (it wasn't
  always caught), the terminal's top edge, resizing and moving widgets,
  reordering spaces in edit mode, and right-click on an empty column.
- **More widgets**: the gallery has the inspector's four (Git, Tee-Up,
  Usage, Activity). Candidates are new tools, judged by speed (the
  product thesis), each with the same Small / Medium / Large grammar.
- **Open in Editor** (2026-11-24, on trial, `App/ExternalEditor.swift`):
  Settings ▸ General ▸ Editor; "Open in <Editor>" opens a file in the
  editor's window for its project (workspace folder, else git root), at
  the line in view (`ShownCode`): file/diff page header button and
  File ▸ Open in … (⇧⌘O), the Files and Git widgets' menus, file links
  in replies (text files only), and a workspace's right-click menu
  (its folder). Sublime was checked for real; VS Code family, JetBrains
  and Zed are wired from their documented CLIs and need a hand check.
  The user may ditch it.
  - **JetBrains handoff** (2026-11-28, needs the user's friend to test
    with PhpStorm, `App/JetBrainsHandoff.swift`): `open -na` showed
    PhpStorm's "Start Failed … still running and does not respond" when
    the running IDE was slow to answer. Now, if the IDE is running and the
    file's project is open in it (its recentProjects.xml), Toasty sends
    `<scheme>://open?file=…&line=N` to it instead; otherwise `open -na`
    as before. Check: file opens in the right window at the line; a
    project that isn't open still opens via `open -na`; no Start Failed.
    Undo: delete the file and its one call in `ExternalEditor.launch`.
- **Files widget** (2026-11-23, Large only, `FilesWidget.swift`): a click
  shows a file in the conversation column (`Inspector/FilePage.swift`),
  read-only (the user's call: a viewer, not an editor, not a tab).
  Selecting lines shows a Comment pill that opens the browser's comment
  box. Not yet: comments on Markdown Preview or Diff lines (only @ for the
  whole file there); a real mouse drag-select hasn't been checked by hand
  (mctl can't drive the text view's tracking; `inspector selectLines`
  stands in).
- **Fit to Content** (merged to main 2026-11-23, not yet pushed):
  Git, Tee-Up, Activity and Files (each reports what it wants:
  `reportsFit`, `WidgetFit`). Its saved height is the most it takes; it's drawn as tall as
  its rows, grows at once, shrinks after a 1s settle with the pointer off
  the column. Widgets below move up. Each list widget picks Fixed or Fit
  (switch on its bottom edge in edit mode, and Height in its menu); a Fit
  widget's limit shows dashed below its content. New list widgets start as
  Fit. Watch: Activity's rows come and go with each tool, so it may
  bob; a longer shrink delay for it alone is the first fix to try.
- **Stale test**: `WidgetLayoutTests.savedTerminalWidgetsAreDropped`
  expects Terminal out of the gallery, but it's back as an experiment.

## Actions widget (trying it, 2026-11-28; branch `actions-widget`)

A widget of the project's commands (a friend's idea: deploy staging,
deploy production, open the local site), each run in its own shell inside
the widget. All in `Toasty/Widgets/ActionsWidget.swift`; to remove it, take
`.actions` out of `WidgetKind.gallery`, its case in `WidgetContent`, and
that file. The user's calls: contained to the widget (output in the widget,
not the drawer); tight (output opens on run, × folds it away); one + popover
adds, changes, reorders and removes; picking a project command fills the
form; kept in Toasty (`actions.json`, by folder; worktrees share their
repo's), not a file in the repo.

Open:
- **✓ / ✗.** Each run as its own process (exit status) instead of typed
  into a shell that stays; offered, not decided.
- **Team sharing.** If wanted: read a project's `toasty.json` as more
  suggestions in the + popover; Toasty never writes into the repo.
- **Moved or renamed folder** loses its actions (keyed by path).
- **Herd/Valet Open Site** untested (neither installed here).

## Terminal placement (trying three, 2026-11-23)

Three ways to have a terminal, all shipped side by side to try them in use
(Settings ▸ Terminal): terminal tabs in the top row (⇧⌘T, ⌃` switches),
the drawer under the conversation (⌘J), and the one under the widgets
(can be turned off). Pick one, or none, and remove the others.

- **Quit warning** doesn't count terminal tabs or the drawer's shells
  (only the widget column's).
- **A terminal tab doesn't resize** when its title changes length.
- **Cursor blink setting** blinks even when a program asks for a steady
  cursor (the engine reports "steady" both for that and for nothing asked).

## Return key setting (trying it, 2026-11-24)

Settings ▸ General ▸ Typing ▸ Return key: "Sends the message" (default) or
"Starts a new line" (⌘Return sends), asked for by a friend of the user's.
Either way ⌘Return sends and Shift-Return starts a new line; the @ and /
menus still pick with Return. Shipped to try; drop it if it doesn't earn
its place.

- While a request card shows, its ⌘Return (Allow / Submit) still wins over
  sending from the composer.

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

## Setup check (launch)

Built 2026-11-21 (`Claude/ClaudeSetup.swift`): every launch checks Claude
Code (>= `minimumClaude`), sign-in (`claude auth status`) and Node; a sheet
blocks the window until they pass. No "Don't Remind Me": no setup, no
Toasty. Fix in Terminal runs the missing steps in a terminal in the sheet.

Next:
- **Managed runtime** (proposal, `docs/MANAGED_RUNTIME.md`, 2026-11-22):
  Toasty downloads and updates its own official Claude Code build for
  conversations, and the overhaul likely replaces Node too (`NO_NODE*.md`),
  so setup is just signing in. Came from a friend stuck on an fnm +
  Homebrew setup.
- **Toasty's own Node.** Without Homebrew, Fix in Terminal can't install
  Node (nodejs.org's installer needs an admin password). Download the
  official Node tarball into Application Support, like the SDK, so the
  Node row never needs the user. Superseded if the managed-runtime
  overhaul replaces Node.
- **Test from a fresh macOS user account** before sending Toasty to
  someone: permission prompts and the full Fix run.

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
- **Drop the in-window toast? (discussed 2026-11-25, user undecided.)**
  The top-right toast only shows while Toasty is in front and the tab
  isn't on screen; dots, sound and ⌃⌘U already cover that, and it sits over
  the widgets' top for 6s. If removed, fill two gaps: a dot on the
  sidebar's edge handle when the sidebar is hidden and another workspace
  needs you (tabs only show the active workspace), and send `announce`
  (default model removed, `DefaultModel.swift`) as a macOS notification
  even while frontmost. Out-of-app banners stay as they are.

## Activity (inspector tab)

Built (2026-11-18), redesigned 2026-11-21 on the inspector design system
(`Inspector/InspectorKit.swift`; the user's Design canvas "Inspector
System"): `Inspector/ActivityTab.swift`, for long runs where it's unclear
whether Claude is still alive. It follows the selected conversation and
reads only what Claude Code already sends (no tokens). Summary row: Working
/ Waiting for You / Idle / No Activity / Stopped, the turn's clock, "Heard
from Claude …" and tokens written. "Now": each running tool call with its
clock (a command alone in mono, an agent's task with its current step).
"In the Background": `backgroundTasks`; hover a row to stop it. "Usage"
pinned at the bottom: context and plan-limit meters; "Details" opens the
context breakdown and the session's cost and tokens. Empty: "Nothing
Running".
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

## Changes (inspector tab)

Redesigned 2026-11-21: the branch as the summary row (sync chips, files and
+/− counts), files under "Uncommitted". The diff page
(`Inspector/DiffDocument.swift`) has line numbers in a gutter, syntax colors,
changed words marked, full-width tints, and ⌃⌘↑/↓ between files.

Open (decide first):
- **Read-only or not?** Decided 2026-11-23: no committing in the app
  (Claude does it better); the Git widget keeps Push and Pull and lists
  the commits not yet pushed. Open Pull Request (`gh`) still undecided;
  no discard or staging.

Next (agreed order):
- **Comment on a diff line → Claude**, like the browser's comments: the
  file and line go with the note.
- **"This conversation / All" filter**: which tab changed each file, from
  its Edit/Write tool calls.
- **Branch story**: ahead/behind main, last commit, "Compare with main".
- Not checked: a very large diff (8,000-line cap) for speed.

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

Built 2026-11-10 (`Toasty/Preview/`), on by default since 2026-11-21 (off before) in Settings ▸ Browser.
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
  The comment box is the composer's own text view (the user, 2026-11-21:
  dictation works there too): two lines at rest, growing to six, then
  scrolling; Return sends, Shift-Return a new line, Esc drops the pick; a
  small mic in its bottom row. Dictation targets it while it has the
  keyboard (it has its own id, so the conversation's mic doesn't light;
  vocabulary from its workspace). Pictures and files go with a comment
  (the user, 2026-11-21): pasted, dropped on the text, the + button, or
  ⇧⌘0, whose screenshot goes to a comment open in the browser window
  before any composer; they follow the page's own picture, and a Tee-Up
  card gets them too. It has a second row: a Send |
  Tee-Up switch (sticky; it's the Settings ▸ Browser ▸ Comments choice)
  and, with Send and more than one tab in the workspace, "to [tab ▾]".
  By default a comment goes to the tab last selected in the workspace the
  browser shows (not necessarily the one on screen in Toasty). The tab
  menu's first item, Last Active Tab, is that default; picking a tab pins
  it (a pin glyph on the chip) for later comments too, until Last Active
  Tab is picked again or the tab closes. Pinning never selects the tab in
  Toasty, and isn't remembered across launches. Tee-Up is the
  workspace's, so no tab there.
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
  both for Claude.
- Sync Scrolling (the user, 2026-11-21; `PreviewScrollSync.swift`): in side
  by side, a footer button (arrows up and down) locks the two pages'
  scrolling together; with it off, holding ⌘ as a scroll starts syncs that
  scroll (the button turns blue while ⌘ is held). Shift was out: it turns
  a wheel's scroll sideways. Each page describes its blocks (child index
  and tag) and where they are; matched, their tops and bottoms make a map
  from one page's positions to the other's (blocks side by side in either
  layout count as one, so a desktop row spans its stacked phone cards),
  redone when the layout changes. The reading line slides from the view's
  top to its bottom as the page scrolls, so top and bottom match. The
  follower moves on a spring that takes on the leader's speed. Inner
  scrolling areas: each page's main scroller (the document, or its
  biggest scrolling area) maps to the other's; other areas fall back to
  matching the element at the line. Not yet: sites whose phone and
  desktop markup differ (different components) only match where the
  structure does.
  Comments (⇧⌘C): click an element or drag an area, type a note; Return
  sends or tees up per the field's Send | Tee-Up switch.

- Browser as a tab (experiment, branch Browser-Tab, 2026-11-26; the user
  was never thrilled with the separate window): Settings ▸ Browser ▸ Show In:
  Its Own Window | A Tab (default Tab on the branch). In a tab: one per
  workspace in the top row (compass + address, pulses while Claude uses
  it). Selected, the tab itself is the address bar, as Safari's compact
  tabs (the user, 2026-11-26: "a bit more Apple, keep things compact"):
  260–400 wide, never the whole row; selected, back and forward (⌘[ ⌘])
  where the compass is (the user: no compass on the active tab), the
  address centered, reload on hover and a ≡ page menu (Open in each
  browser, Fill the Window, Move to Window, Close Tab); the window's
  footer has Move to Tab. One rule for open and close (the user,
  2026-11-26: "close tab, close browser, new browser… really confusing"):
  the browser is open (a tab, or its own window) or closed. Open: + ▸
  Open Browser, ⇧⌘B, a link, Claude opening a page. Close: the tab's ×,
  ⌘W, the window's close button, ≡ ▸ Close Browser: all the same, the
  page unloaded and forgotten and nothing in the row. Hide (window only):
  ⇧⌘B in the window, or switching away; its pseudo-tab (`BrowserPill`,
  window mode only: never highlighted, a dashed outline (the user: "both
  tabs appear active"), compass + host + ≡, compass pulses while Claude
  uses it) brings it back; its ≡: Show Browser Window / Move Back to Tab /
  Close Browser. The window's titlebar has the same address pill as the
  selected tab (`BrowserAddressBar`: back, forward, address, reload, ≡ with
  Open In, Move Back to Tab, Close Browser), centered; its footer lost
  Move to Tab (the user: window and tab controls consistent). The titlebar compass is gone.
  Several browser tabs (the user, 2026-11-26), tab mode only (the window
  keeps one page per workspace, shared with Claude, as before): + ▸
  Browser opens another page on the workspace's logins and storage (the
  first is the main page, the one the window shows). Each conversation
  whose Claude uses the browser gets its own tab (blue: an accent outline,
  the whole tab accent-tinted when shown; the user tried it instead of a ✦; the
  compass), made by its first tool call right after the conversation's
  tab, never shown or focused; closed by the user, the next call makes a
  new one (`PreviewStore.agentPage`). Closing a tab closes that page (the
  main one is reset). ⇧⌘M/⇧⌘C act on the shown tab's page; a terminal
  link opens in the main page's tab; a turn's end reloads every page of
  the workspace. Tabs and their addresses are kept across launches. A
  closed conversation's tab stays (as an ordinary tab). Moving flips Settings ▸ Browser ▸ Show In (one
  window for every workspace's browser), page untouched; clicking it edits the whole URL,
  selected, with an accent ring and a clear button. Closed with ⌘W
  or its menu. The page starts right under the row, and the window's
  footer stays (the user loves it; a one-row bar with no footer was tried
  and rejected; controls beside the tabs was the step before this)
  without the workspace menu or Show Conversation.
  Desktop size = the tab's room, no presets. ⇧⌘B goes to it and back, ⌘W closes it (the page keeps
  running), the compass, ⇧⌘C and terminal links open it. Fill the Window
  (button at the bar's end, ⇧⌘F; remembered): the workspaces and widgets
  step aside while it shows, back with any other tab; showing either by
  hand stops filling. If the user drops it: delete the branch.

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
area/window picker and attaches the picture to a comment open in the
browser (since 2026-11-21), else the open conversation's composer. It doesn't send, and Toasty stays in the background so several
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

### Browser windows: one per moved-out tab (2026-11-26, the user: "Build it")

Replaces the single shared browser window and Settings ▸ Browser ▸ Show In
(both gone). Every browser starts as a tab; Move to Window (the tab's ≡ or
right-click) moves that one tab to a window of its own, as dragging a tab
out of Safari. The window is that tab's page for good (one workspace, one
page): no workspace menu, its title "workspace — host", its own frame
(autosave per page; a new one cascades from the browser window in front).
The tab stays in the row as a dashed pseudo-tab (blue dashes for Claude's):
click brings the window forward; ≡/right-click: Show Window, Move Back to
Tab, Close Browser. Several can be out at once. The window's close button,
⌘W and ⇧⌘B only put it away (the user, 2026-11-26): the page goes on and
the pseudo-tab brings the window right back; Close Browser (the window's
or the pseudo-tab's ≡) closes the page. Claude's tab can be moved out
too, and its tools keep driving it there. Moved-out tabs reopen in their
windows at launch (behind the main window). ⌃⇥ / ⌥⌘→ skip pseudo-tabs;
closing a tab never lands on one. Window ▸ Browser is gone (AppKit lists
the windows). Not done: dragging a tab out of the row to detach it.
