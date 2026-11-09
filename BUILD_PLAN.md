# Toasty — Build Plan

A slim, native macOS app for working with Claude Code: one window per
project, Claude Code conversations as tabs, a terminal sidebar, and replies
rendered as refined native Mac text.

Toasty replaces **mostty** (a Ghostty fork at `~/Development/mostty`, branch
`native-claude`, pushed to `github.com/martyvasquez/toasty` main). mostty
proved the product; Toasty rebuilds it without forking Ghostty's app. Most
of mostty's Claude layer is reused nearly verbatim (see §6).

Build in the phases below, in order. Each phase ends with a working build
and the acceptance checks listed. **Phase 1 is a go/no-go spike for the
terminal**; don't build the rest of the app on it until it passes.

---

## 1. Principles (non-negotiable)

1. **Claude Code must behave exactly like Claude Code.** Use the official
   Claude Agent SDK with the Claude Code presets and the user's own
   settings. Never write a system prompt, tool, or agent loop. Never add
   instructions to change Claude's behavior. If something can't be done
   faithfully, say so instead of substituting.
2. **Native means native.** Swift, SwiftUI for structure, AppKit where it is
   better (text, menus, split views). No Electron, no web views, no
   browser-based editors.
3. **The UI renders events and collects input; it never decides what Claude
   does.**
4. **Simple.** A personal tool. No speculative features, no abstractions
   without a second use. One standard Settings window (⌘,) is allowed
   (added 2026-11-08 at the user's request, for dictation's vocabulary);
   add a pane only when something truly needs it.
5. **Refined.** The user cares a lot about typography, spacing and
   integration (§5). Verify visually with real screenshots (§9) after every
   UI change. Don't guess.
6. Keep a working build at every step. Commit at the end of each phase
   (on a branch; push only when asked).

## 2. Key decisions (already made with the user)

| Decision | Choice | Why |
|---|---|---|
| App | New Swift app, **not** a Ghostty fork | Forking Ghostty's app layer (≈30k lines of Swift for its windows/tabs/titlebars) caused most of mostty's friction. |
| Terminal engine | **libghostty-vt** (Ghostty's official embeddable VT library) + **our own Core Text renderer** | Ghostty-grade emulation, drawn natively in the app's typography; light. Spike first (Phase 1). |
| Terminal fallback | Full libghostty (GhosttyKit, the embedded apprt used by Ghostty.app) | Only if the Phase 1 spike fails. |
| Claude integration | Official **Claude Agent SDK** (TypeScript) via a tiny Node bridge, using the **installed** `claude` | Already built and verified in mostty; same approach as Conductor (which also uses the Agent SDK). |
| Layout | One window per workspace: **Workspaces sidebar · conversation (tabs on top) · terminal sidebar (terminal tabs on top)** | Iterated with the user in mostty. |
| Project file | **XcodeGen** (`project.yml`), like Marker | User's convention (`~/Development/markdown-editor/project.yml`). |
| Platform | macOS 26+, Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, team `G88C7HMHUJ`, bundle id `com.martyvasquez.toasty` | Matches Marker. |

## 3. Reference material

- **mostty** (`~/Development/mostty`, branch `native-claude`):
  `macos/Sources/Features/Claude/` is the Claude layer to port.
  `macos/Sources/Features/Workspaces/` has the workspace/notification
  behavior to re-implement (not copy — it's entangled with Ghostty types).
  `MOSTTY.md` documents mostty's features.
- **Marker** (`~/Development/markdown-editor`): the user's Markdown editor.
  Typography source of truth: `Marker/Styling/Theme.swift`,
  `Marker/Editor/MarkdownLayoutManager.swift`. Test document:
  `Design/Comparison.md`.
- **libghostty-vt**: headers in `~/Development/mostty/include/ghostty/vt/`
  (start with `vt.h`, `terminal.h`, `render.h`, `key.h`, `mouse.h`,
  `paste.h`, `selection.h`, `focus.h`). Examples in
  `~/Development/mostty/example/` — especially `c-vt-render`,
  `c-vt-stream`, `c-vt-encode-key`, `c-vt-encode-mouse`, `c-vt-selection`,
  `c-vt-selection-gesture`, `swift-vt-xcframework`. The API is marked
  work-in-progress; pin a Ghostty commit (§4.3).
- **Claude Agent SDK**: vendored file
  `mostty/macos/Sources/Features/Claude/Bridge/claude-agent-sdk.mjs`
  (0.3.319, built for Claude Code 2.1.319), and
  `mostty/extras/update-claude-agent-sdk.sh`. Types: `npm pack
  @anthropic-ai/claude-agent-sdk` → `sdk.d.ts`. Docs:
  https://code.claude.com/docs/en/agent-sdk/overview
- **Conductor** (`/Applications/Conductor.app`): visual reference only
  (Tauri + web; we don't copy it). The user likes its content width and
  composer proportions.

## 4. Architecture

### 4.1 Layout

```
┌──────────────┬─────────────────────────────────────┬─────────────────────────┐
│ ● ● ●        │ [✦ Fix login][✦ New Chat][+]        │ [▣ zsh][▣ npm dev][+] ◨ │  ← titlebar row (toolbar tone)
│ Workspaces + ├─────────────────────────────────────┼─────────────────────────┤
│ ▸ toasty     │                                     │                         │
│ ▸ lsc-astro  │   conversation transcript           │   terminal (panel)      │
│   Working…   │   (900pt column, centered)          │                         │
│              │                                     │                         │
│              │   ╭ composer (900pt) ──────────╮    │                         │
│              │   ╰────────────────────────────╯    │                         │
└──────────────┴─────────────────────────────────────┴─────────────────────────┘
```

- Use **`NSSplitViewController`** with a sidebar item (workspaces, native
  sidebar material, collapsible ⌃⌘S), a content item (conversation), and an
  inspector item (terminal, collapsible ⌃⌘T, resizable, full height). This
  gives real macOS sidebar behavior instead of mostty's hand-rolled HStack.
- **Toolbar / titlebar row**: `NSToolbar` (`.unifiedCompact`) whose items
  are tracking-separator-aligned to the split view
  (`NSTrackingSeparatorToolbarItem`), so the conversation tabs sit over the
  conversation column and the terminal tabs + sidebar toggle sit over the
  terminal column. Tabs are custom SwiftUI views hosted in toolbar items
  (`NSHostingView`). If tracking separators can't produce this cleanly,
  host one `NSHostingView` in the titlebar spanning the content area and
  mirror the column widths from the split view (mostty's approach — see
  `ClaudeTabBarHost` in `mostty/.../Claude/ClaudeTab.swift`). Views placed
  under a transparent titlebar as plain content do **not** receive clicks;
  they must be in the titlebar/toolbar view hierarchy.
- One window per workspace; only one visible at a time (switching swaps
  the window's content, simpler than mostty's hidden-window trick: the
  window keeps all workspaces' views alive and shows the active one).
  Conversations and terminals of background workspaces keep running.

### 4.2 Modules (folders in one app target)

```
Toasty/
  App/            AppDelegate, main menu, window controller, split view
  Workspaces/     WorkspaceStore (model + persistence), sidebar view
  Claude/         (ported from mostty) agent bridge, conversation model,
                  transcript views, markdown, typography, request cards
  Terminal/       PTY, libghostty-vt wrapper, renderer, terminal view,
                  terminal tabs
  Notifications/  status, toasts, sounds, dock badge, keep-awake,
                  UNUserNotifications
  Dictation/      local voice dictation (§13): engine, mic, trigger,
                  text pipeline, vocabulary
  Debug/          DEBUG-only control channel + in-app screenshot (§9)
  Resources/      Bridge/ (mostty-agent.mjs, claude-agent-sdk.mjs),
                  Assets.xcassets, SpeechModels/ (fetched, gitignored),
                  Acknowledgements.txt
Vendor/
  GhosttyVt.xcframework   (built from a pinned Ghostty commit, §4.3)
  CTranscribe.xcframework (transcribe.cpp at a pinned commit, §13)
scripts/
  build-ghostty-vt.sh     update-claude-agent-sdk.sh
  build-transcribe.sh     fetch-speech-models.sh
Tests/
  DictationTests/ (Swift Testing, hosted in the Debug app) and Fixtures/
```

### 4.3 libghostty-vt

- Build from a pinned Ghostty commit. Use the user's Ghostty checkout
  (`~/Development/mostty` has `upstream` = ghostty-org/ghostty) or a
  shallow clone in a temp dir: `zig build -Demit-lib-vt -Doptimize=ReleaseFast`
  → `zig-out/lib/ghostty-vt.xcframework`. Copy it to `Vendor/` and record
  the commit in `Vendor/GHOSTTY_VT_VERSION`. `scripts/build-ghostty-vt.sh`
  automates this (Zig 0.17 is installed).
- Wrap the C API in one Swift file (`Terminal/VT.swift`) so API churn is
  contained.

### 4.4 Persistence

Own it; don't use NSWindow restoration (mostty fought it).
`~/Library/Application Support/Toasty/state.json`, written debounced on
change and on quit:

```
workspaces: [{ id, name, folder, order,
               conversations: [{ id, sessionID?, cwd, customTitle? }], selected,
               terminals: [{ id, cwd }], selectedTerminal, terminalVisible, terminalWidth }]
activeWorkspace, sidebarVisible, window frame
```

Terminals restore as fresh shells in their last directory (scrollback
restore is optional; libghostty-vt has a snapshot API if wanted later).
Conversations restore by session id (load history from the transcript,
resume lazily — see §6).

## 5. Design spec (decided with the user — keep exactly)

All colors are dynamic (light/dark). Only dark mode has been reviewed with
the user; check light mode and ask.

**Window chrome**
- Titlebar row: toolbar tone `chrome` = dark `#2A2A2A` (white 0.165),
  light `#EEEEEE`; 0.5pt separator hairline below it.
- Conversation page background = `NSColor.textBackgroundColor`
  (dark `#1E1E1E`).
- Workspaces sidebar: native sidebar material.
- Terminal: the panel color of the sidebar and inspector (`chrome`),
  `#2A2A2A` in dark mode and `#EEEEEE` in light mode (changed from true
  black so the right column reads as one panel); macOS Terminal palette ("Apple System Colors"
  ANSI colors — copy from `mostty/macos/Sources/Features/Claude/mostty-terminal-dark.theme`).
  12pt horizontal / 8pt vertical padding inside the terminal.
- Full-height 0.5pt divider between conversation and terminal columns;
  draggable (min terminal 280, min conversation 440).

**Tabs (conversation and terminal tabs use the same style)**
- Height 28, corner radius 8, 12pt text, 6pt gaps.
- Selected: filled with the page color `textBackgroundColor`, 0.5pt border
  `primary @ 9%`, shadow black 18% radius 1.5 y 0.5 ("raised out of the
  bar"); title `.medium`, primary.
- Unselected: no fill (hover `primary @ 6%`), title secondary.
- Conversation tab leading status: orange dot = waiting for you; mini
  spinner = working; accent dot = finished while you weren't looking;
  otherwise a `sparkle` symbol (orange when selected, faint otherwise).
- Close ✕ appears on hover (16pt circle). Right-click: Rename…, Close,
  Close Other Tabs. Title = custom name, else first line of the first
  prompt (≤40 chars), else "New Chat".
- Terminal tab: `terminal` symbol + shell title (pwd's last component when
  the title is `user@host:path`).
- `+` after the tabs. Terminal sidebar toggle (`sidebar.right`, accent when
  open) always at the window's top-right corner.
- No second header row in the conversation (no breadcrumb, no activity
  pill). "Open in Finder" lives on the workspace's context menu.

**Conversation column**
- The transcript and the composer share **exactly one width: 720pt**
  (`composerWidth`, a reading measure like Claude/Codex/Conductor; was 900),
  centered, same left/right edges; both shrink together in narrow windows.
- Composer (Codex-style, refined 2026-11-06): corner radius 18, fill
  `field` = dark white 0.19 / light white, 0.5pt border `primary @ 9%`,
  shadow black 8% radius 6 y 2. Text view one line at rest (grows to 300),
  14pt text, line height 1.2, 16pt left inset shared with the controls.
  One control row inside: `+` (attach), permission mode as quiet text
  (tinted text, no fill; hover fill only) on the left; model name as quiet
  text and a 28pt circular send button (accent when enabled; stop while
  working) on the right. The transcript scrolls under the composer and
  fades out above it (28pt gradient); a round "jump to latest" button
  appears when scrolled up.
- Placeholder: "Ask Claude to make changes, or type / for commands"; while
  working "Send a follow-up…"; while a prompt is pending "Claude is waiting
  for your answer above".
- Permission/question/plan cards sit above the composer, same width,
  `field` fill, radius 16, orange 45% border.
- User messages: trailing bubble sized to its text, radius 18, fill
  `primary @ 7.5%`, padding 15×8, line height 1.38.
- Spacing: 34 before a user message, 18 after one, 16 between other rows.
- Turn footer under the last reply: "12s · 4:41 PM" + copy button,
  tertiary 11.5pt.
- Tool calls: consecutive calls collapse into one quiet line (12.5pt,
  secondary, chevron): a sentence of what happened ("Read 2 files, ran
  `npm test`, wrote README.md"), or the live step with a spinner while
  working ("Running npm test 12s"). Click expands the rounded box (radius
  10, fill `primary @ 4.5%`, hairline dividers, one row per call: status
  icon, tool name semibold 12.5, summary). Below the line stay what matters:
  diffs of edits to existing files (once done, not while the permission
  card shows them), todo lists, and errors; failed calls aren't counted in
  the sentence. File links look like the code/text they're in (hand cursor
  only); web links are blue with a soft underline.
- Empty-thinking blocks are hidden. Notices are centered tertiary 11.5pt.

**Typography of Claude's replies** (from Marker, tuned denser — port
`ClaudeTypography.swift`, `ClaudeMarkdown.swift` from mostty as-is)
- Body 14pt SF Pro, code 13pt SF Mono; headings semibold 21 / 18 / 15.5 /
  14.5 / 14 / 14.
- Fixed line height 1.5× with **half-leading** (min=max line height +
  baseline offset = half the extra), headings 1.2×, code 1.45×.
- Paragraph gap 0.6 × line height; after a heading 0.4 × gap; heading
  space-before = gap + 0.45 × size.
- Text color graphite: dark `#DFE0E0`, light `#444444`; secondary
  `#A2A3A4` / `#888888`. "Bold" = semibold.
- Accent color is the only color: drawn bullets (dot / ring / diamond by
  level), numbers (monospaced digits, right-aligned to the text edge, edge
  widens for 10+), drawn checkboxes (accent fill + white check / outline),
  quote bars (3pt, one continuous bar per quote, one per nesting level),
  links (link color, underline at 40%).
- Inline code: monospaced at 13/14 of the text size, rounded background
  (radius 4, `white @ 7%` dark / `black @ 4.5%` light), padding via kern on
  the last character (copying stays exact).
- Code blocks: rounded box radius 8 `codeBackground`, padding 14×10, no
  header; language + Copy + Run in Terminal appear on hover. Syntax colors
  Bear Graphite: keyword `#70B8D7`/`#AD3DA4`, type `#AAC97F`/`#4A838B`,
  string `#E6945E`/`#D12F1B`, number `#E6945E`/`#0095C9`, comment
  `#7F8C97`/`#8A95A0` (dark/light).
- Tables: `NSTextTable`, rounded 6pt outline drawn around it, inner grid
  only, header shading, alternating rows, cell padding 12×7, text 13.5.
- Single newlines inside a paragraph are line breaks (U+2028), not
  paragraph gaps. Ordered lists keep the numbers as written.

## 6. Claude layer (port from mostty)

Copy these from `mostty/macos/Sources/Features/Claude/` and adapt
(remove Ghostty/`TerminalController` references; route through the new
workspace model):

| mostty file | Keep | Change |
|---|---|---|
| `Bridge/mostty-agent.mjs` | All (rename `toasty-agent.mjs`) | `CLAUDE_AGENT_SDK_CLIENT_APP: "toasty"` |
| `Bridge/claude-agent-sdk*.{mjs,md,txt}` | Vendored SDK as-is | Update via script |
| `ClaudeAgent.swift` | Process + login-shell environment + node/claude discovery | Drop Ghostty env var filtering only where irrelevant |
| `ClaudeConversation.swift` | All message handling (see notes below) | Notifier calls → Toasty's `Activity` (§7) |
| `ClaudeConversationView.swift` | Transcript, rows, composer box, chips, `ClaudePopUp` | Remove header bar remnants |
| `ClaudeTextViews.swift` | `ClaudeRichText` (offscreen measuring!), composer | — |
| `ClaudeMarkdown.swift`, `ClaudeTypography.swift`, `ClaudeStyle.swift` | All | — |
| `ClaudeToolViews.swift`, `ClaudeRequestCard.swift` | All | — |
| `ClaudeWorkspace.swift`, `ClaudeTab.swift` | Concepts only | Rewrite against the new window/split view |
| `ClaudeDebugControl.swift` | Concept + commands | Rewrite for Toasty (§9) |

**SDK configuration (verified working in mostty; keep exactly):**
`systemPrompt: {type:'preset', preset:'claude_code'}`,
`tools: {type:'preset', preset:'claude_code'}`,
`settingSources: ['user','project','local']`, `includePartialMessages: true`,
`canUseTool` → UI, `pathToClaudeCodeExecutable` = installed `claude`
(found on the login-shell PATH), `env` = the user's login-shell environment
(`$SHELL -i -l -c env -0`, minus terminal-specific vars),
streaming input (AsyncIterable), `resume: sessionID` for restored tabs.
Don't set `permissionMode` (the CLI then uses the user's default, e.g.
`auto`). `q.supportedModels()` feeds the model picker; `q.setModel`,
`q.setPermissionMode`, `q.interrupt()`.

**Verified behaviors (from live tests in mostty):** same Claude Code build
as the CLI; user hooks run; all plugins load via `enabledPlugins`; MCP +
claude.ai connectors present; subscription login (`apiKeySource: none`);
resume interoperates with `claude --resume`; AskUserQuestion and
ExitPlanMode both arrive via `canUseTool`.

**Message handling notes (all implemented in `ClaudeConversation.swift`):**
- Stream events: `content_block_start/delta` for text, thinking,
  `tool_use` (keyed by message id + index); the final `assistant` message
  replaces streamed text.
- `system/status` → only show "Compacting conversation…" (ignore
  `requesting`). `compact_boundary` → notice. `api_retry` → status.
- `result`: count turns in flight — a message sent while working runs as
  its own turn; only go idle when the count reaches 0. Interrupted turns
  show "Interrupted · What should Claude do instead?" and no "finished"
  notification.
- Permission responses: allow `{behavior:'allow', updatedInput}` (+
  `updatedPermissions: suggestions` for "Always Allow");
  deny `{behavior:'deny', message, interrupt:true}` (Esc) or with feedback
  `interrupt:false`. AskUserQuestion: `updatedInput = {...input, answers:
  {[question]: "label, label"}}`. ExitPlanMode approval:
  `updatedPermissions: [{type:'setMode', mode, destination:'session'}]`.
- History: parse `~/.claude/projects/*/<session>.jsonl` (tail ~1500 lines,
  skip sidechain/meta/compact-summary entries), same handler as live
  messages; show "Resumed session".
- Start the agent as soon as a tab opens (like running `claude`).
- Notification text: strip Markdown markers.

**Known differences from the CLI (document, don't "fix"):** terminal-only
slash commands (`/config`, `/theme`…) report unavailable; no `!` bash mode
or `#` memory shortcut; no statusline; entrypoint reports `sdk-ts`.
Claude Code 2.1.319 here has no TodoWrite/Task tools, so there's no task
list to show.

## 7. Workspaces, activity & notifications

Re-implement mostty's behavior (`mostty/.../Workspaces/` +
`MOSTTY.md`) on Toasty's model:

- Workspaces: name (default: git repo name of the folder), folder,
  order (drag to reorder), rename inline (double-click / ⌃⌘R), context menu
  (Rename, Change Folder…, Open in Finder, Move Up/Down, Close). ⌘N new
  workspace (pick a folder), ⌥1–9 switch, ⌃⌘J/⌃⌘K next/prev. Opening a
  folder (Finder > Services > "New Toasty Tab Here", `open -a Toasty <dir>`,
  Finder, Dock) → a new tab in its workspace, or a new workspace.
- `Activity` (replaces mostty's `WorkspaceNotifier`), keyed by conversation
  (and by terminal for CLI sessions run in a terminal, optional): states
  working / waiting / idle.
  - Sidebar rows are one line (no folder path; worktrees indented under
    their parent). The leading icon shows status: spinner while working
    (with a trailing "4m" after a minute), pulsing orange dot when waiting,
    accent dot when finished unseen. Messages live in the sidebar's
    Notifications; the row's tooltip has the status and the folder.
  - Tab dots as in §5. Dock badge = conversations needing you.
  - Sound (`defaults write com.martyvasquez.toasty ToastySound Glass`,
    "none" to mute), in-window toast (top-right, click jumps to the tab),
    macOS notification when Toasty isn't frontmost (click jumps).
  - ⌃⌘U jumps to the latest conversation needing attention.
  - Keep-awake (`IOPMAssertion` PreventUserIdleSystemSleep) while any
    conversation is working.
  - Close/quit confirmation when a conversation is working/waiting or a
    terminal has a running process.

## 8. Phases

### Phase 0 — Project setup
- `project.yml` (XcodeGen) modeled on Marker's; `xcodegen generate`.
- `scripts/build-ghostty-vt.sh`; build and vendor `GhosttyVt.xcframework`.
- Minimal app launches with an empty window; Debug control channel and
  in-app screenshot command in place from day one (§9).
- **Accept:** `xcodebuild` builds; screenshot command produces a PNG.

### Phase 1 — Terminal spike (go/no-go)
A standalone `TerminalView` (NSView) in the app:
- PTY: `forkpty`/`posix_spawn` the login shell (`$SHELL -l`) in a
  directory, with `TERM=xterm-256color`, `COLORTERM=truecolor`,
  `TERM_PROGRAM=Toasty`; read on a background queue; feed bytes to the
  libghostty-vt terminal; resize → `TIOCSWINSZ` + terminal resize.
- Renderer: libghostty-vt render state → draw only dirty rows with Core
  Text (`CTLineDraw` per run of identical style); cache line images or
  layers per row; cell metrics from the font (SF Mono 13, configurable);
  wide chars, emoji/font fallback (`CTFontCreateForString`), bold/italic/
  underline/strikethrough/inverse/dim, 256-color + truecolor, cursor
  styles + blink, selection highlight. 60fps target while output streams.
- Input: `keyDown` → libghostty-vt key encoder (respects terminal modes);
  `NSTextInputClient` for IME/dictation/dead keys; paste via the paste API
  (bracketed paste); mouse encoding when the program requests it; focus
  events.
- Selection (mouse drag, double/triple click) + ⌘C; scrollback with
  trackpad scrolling and a scroller; ⌘K clear; URL ⌘-click.
- **Accept (show the user side-by-side with Ghostty):** zsh prompt with
  colors; `npm run dev`-style streaming output stays smooth; `vim`, `htop`,
  `less` render and respond correctly; `claude` (the CLI's TUI) works;
  CJK + emoji render; IME works; selection/copy/scrollback feel native.
  **If it fails**, switch to full GhosttyKit (embed `ghostty_surface`
  as mostty does) and continue — tell the user before switching.

### Phase 2 — App shell
- Window + `NSSplitViewController` (sidebar / content / inspector),
  toolbar tab rows (§4.1), workspace store + persistence (§4.4),
  workspace sidebar (§7), main menu with all shortcuts (⌘T new tab, ⌘W close
  tab or focused terminal, ⌘1–9, ⌘⇧[ ], ⌃⌘T, ⌃⌘S, ⌘N, ⌥1–9, ⌃⌘R, ⌃⌘U).
- **Accept:** create/switch/rename/reorder workspaces; tabs render per §5;
  state survives quit + relaunch.

### Phase 3 — Claude conversations
- Port the Claude layer (§6). Each tab = one `ClaudeConversation`.
- **Accept:** prompt → streaming reply; Bash permission card (Allow /
  Always Allow / Deny / feedback); AskUserQuestion; plan approval;
  interrupt (Esc and stop button); a follow-up queued while working;
  two conversations working at once; quit/relaunch resumes sessions with
  history; Marker's `Design/Comparison.md` renders correctly (debug
  `render` command) — compare against §5.

### Phase 4 — Terminal sidebar
- Terminal tabs (§5) using the Phase 1 view; new terminal in the workspace
  folder; shell exit closes that terminal tab (last one → fresh shell,
  sidebar hides); "Run in Terminal" from code blocks pastes (never
  executes) into the shown terminal; ⌃⌘T show/focus/hide.
- **Accept:** multiple terminals per workspace; they keep running when
  hidden or when switching workspaces; restored in their directories.

### Phase 5 — Activity & notifications (§7)
- **Accept:** every indicator in §7 verified with two workspaces and
  concurrent conversations; notification clicks jump to the right tab.

### Phase 6 — Import from mostty (one-time, optional — ask the user)
mostty's state lives in AppKit window restoration archives (hard to read).
Practical import: read mostty's defaults (`com.mostty.app`:
`MosttyWorkspaceNames`, `MosttyWorkspaceFolders`, `MosttyWorkspaceOrder`)
to create workspaces, and offer each folder's recent Claude sessions
(`~/.claude/projects/<encoded folder>/*.jsonl`, newest first) as tabs.

### Phase 7 — Polish & ship
- App icon (ask the user), About, signing, `scripts/release.sh`
  (zip + optional Sparkle later — ask), light-mode review, accessibility
  labels, performance check with a long session (1,500+ transcript rows;
  only the last 160 rows are laid out, "Show N Earlier").

## 9. How to test (lessons from mostty — use these)

- **No Screen Recording / Accessibility needed.** An app may capture its
  own windows: call `CGWindowListCreateImage` (look it up with `dlsym`, it's
  unavailable to Swift in the current SDK) with
  `kCGWindowListOptionIncludingWindow` and the window number. This gives
  real pixels (materials, titlebar, terminal). `cacheDisplay` does not.
- **DEBUG-only control channel** (compiled out of Release):
  `DistributedNotificationCenter` notification `com.martyvasquez.toasty.debug`
  with a JSON object, driven by a tiny Swift CLI (`mctl`) compiled in the
  scratchpad. Commands used in mostty: `open/newTab/selectTab`,
  `type`, `submit`, `allow`, `deny`, `answer`, `interrupt`, `mode`,
  `terminal`, `newTerminal`, `selectTerminal`, `runInTerminal`,
  `terminalReturn`, `render` (inject Markdown as a reply), `scroll`,
  `click x y` (real `NSEvent` through `window.sendEvent`), `screenshot`,
  `dump` (JSON state incl. view hierarchy), `workspace`, `quit`.
- Use a separate bundle id for Debug (`com.martyvasquez.toasty.debug`) so
  testing never touches the user's real state or sessions.
- Wait for streaming turns by polling `dump` until idle or a request is
  pending.
- Quit with the `quit` command, not `pkill` (state is saved on quit).
- Screenshots right after a show/hide animation catch mid-transition
  frames; wait ~1s.

## 10. Gotchas already solved in mostty (don't rediscover)

- **NSTextView in SwiftUI:** measure height with a *separate offscreen*
  `NSLayoutManager`/`NSTextContainer` (the view's own container tracks its
  width and corrupts measurements). In `sizeThatFits`, never answer a
  zero/tiny probe width with a "one character per line" height. Cache
  heights per width. Use a non-lazy `VStack` for the transcript (with a
  row limit) — `LazyVStack` cached bad heights and left huge blank areas.
- **Content-hugging bubbles:** natural width = layout at a huge width.
- **SwiftUI `Menu` on macOS flattens custom labels** (shows only the first
  image + text). Draw the chip yourself and pop up an `NSMenu`
  (`ClaudePopUp`).
- **Clicks under a transparent titlebar don't reach content views.** Host
  controls in the titlebar/toolbar view hierarchy.
- An empty `NSToolbar` with `.unifiedCompact` gives the titlebar the
  standard tabbed-toolbar height.
- Composer: own `UndoManager`; implement `undo:`/`redo:` on the text view
  so ⌘Z never hits the window's undo stack; disable smart quotes/dashes/
  autocorrect; Return submits only when not composing marked text;
  Shift/Option-Return inserts a newline; plain-text paste; image paste →
  attachment.
- Inline code pill: kern on the last character for padding; subtract that
  kern when drawing the background.
- Quote bars: start at the first line's text, not its paragraph spacing;
  include the paragraph break in the quote attribute so bars join.
- `NSTextTable` header alignment: apply the same `paragraphSpacingBefore`
  to every header cell.
- Hide edit diffs while a permission card shows the same diff.
- Run `claude` processes eagerly per tab; close stdin to end a session
  (the bridge exits; the SDK stops the CLI).
- Login-shell environment capture: `$SHELL -i -l -c "printf MARKER; env -0"`
  with a timeout; parse after the marker (rc files may print).
- `node` may only be found via nvm (`~/.nvm/versions/node/*/bin`).

## 11. Out of scope (unless the user asks)

Git diff / "Changes" panel, @-mention file picker, slash-command
autocomplete, model effort controls, Remote Control, a settings window,
multiple windows per workspace, CLI-in-terminal session tracking via hooks.

## 12. Open questions to confirm with the user at the start

1. App name/bundle id `Toasty` / `com.martyvasquez.toasty` — OK?
2. Repo: build in `~/Development/Toasty` as a new git repo and push to
   `github.com/martyvasquez/toasty` (currently holds mostty's
   `native-claude` code on `main`) — replace its `main`, or use a new
   branch/repo?
3. Phase 6 import from mostty — wanted?
4. Updates (Sparkle) — wanted for a personal tool?

## 13. Dictation

**Full documentation: [`docs/DICTATION.md`](docs/DICTATION.md)** (using it,
what you can say, vocabulary, how it works, setup, tuning, troubleshooting,
decisions). The original phase plan (D0–D6) was
`~/Development/dictation/TOASTY_DICTATION_PLAN.md`; its decisions are
summarized in the doc.

In short: hold Right Option, speak, release; text appears in the message
box (never sent). Fully local: Parakeet TDT 0.6B v2 on Metal through
transcribe.cpp (pinned), Silero VAD, models bundled at build time. Text
pipeline ported from Hex (symbols, formatting, fillers, replacements),
plus repo-aware paths and a layered vocabulary (project file, your file,
names from the conversation and repo, built-in developer names), edited in
Settings ▸ Dictation. Code in `Toasty/Dictation/`, tests in
`Tests/DictationTests/`, remaining work in `TODO.md` › Dictation.
