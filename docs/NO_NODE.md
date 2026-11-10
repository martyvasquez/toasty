# Removing the Node.js dependency

Status: **proposal, open for evaluation.** Nothing here is implemented in the
app yet. Two proofs of concept (POCs) were run outside the app against real
Claude Code sessions. Their results are summarized below.

This document is written for someone who hasn't seen the codebase or the
conversation that produced it. It covers the problem, how Toasty works today,
what was learned, the options considered with their trade-offs, and the
current recommendation. The aim is to let a reviewer challenge the
recommendation or propose something better.

---

## 1. The problem in one paragraph

Toasty is a native macOS app (Swift, macOS 26+) that is a terminal plus a
native front end for Claude Code. Its conversation tabs run Claude Code
through Anthropic's **Claude Agent SDK**, which is a JavaScript package. A
JavaScript package needs a JavaScript runtime, so Toasty requires the user to
have **Node.js** installed and on the PATH of their login shell. Anyone else
who installs Toasty therefore has to install Node first, only so a small
background script can run. The goal is to ship Toasty so that its only
requirements are **macOS 26 and Claude Code itself**.

## 2. Why remove Node

1. **Sharing and installation.** Toasty is meant to be handed to other people
   as a signed, notarized `.zip`. Today a recipient has to:
   - install Node, which most non-JavaScript developers don't have;
   - get it onto their *login shell's* PATH (Toasty runs the user's shell to
     find it and also checks `~/.nvm/versions/node`);
   - otherwise see "Couldn't find Node.js (needed by the Claude Agent SDK)".

   Claude Code is a reasonable requirement, because Toasty is a front end for
   it. Node is not: it's an implementation detail leaking out to the user.
2. **Product thesis.** Toasty aims to be the *fast* middle ground between a
   plain terminal (Ghostty) and the Claude desktop app, with a refined native
   feel. A hidden runtime dependency that can be missing, outdated or wrong
   undercuts that.
3. **Fewer moving parts per tab.** Each tab currently runs
   Toasty → `node toasty-agent.mjs` → `claude`, three processes. Without the
   SDK in the middle it's Toasty → `claude`. In the POC this made a tab ready
   about 100 ms sooner (~470 ms instead of ~570 ms), and removed one process
   and ~1.3 MB of JavaScript parsing per tab.
4. **Less fragile environment handling.** Finding `node` means sourcing the
   user's interactive login shell (nvm, asdf, Homebrew and the like). That's
   a common cause of "works on my machine" problems.
5. **No bundling alternative is good.** Shipping Node inside the app would add
   roughly 100 MB per CPU architecture (Toasty is universal: arm64 + x86_64).
   Toasty would also have to keep that Node patched for security, and the
   extra process would remain.

Constraint the user cares about: **don't break a working app they use every
day.** Any change must be low risk and reversible.

## 3. How it works today

### Components

| File | Role |
|---|---|
| `Toasty/Claude/ClaudeAgent.swift` | Starts `node toasty-agent.mjs` per conversation tab and relays JSON lines. Also resolves the environment: runs the login shell to get PATH and finds `node` and `claude`. Has a separate `fork(...)` that runs the bridge in one-shot `fork` mode. |
| `Toasty/Resources/Bridge/toasty-agent.mjs` | ~200-line Node bridge. Starts one SDK `query()` configured like the interactive CLI and maps Toasty's messages to SDK calls. |
| `Toasty/Resources/Bridge/claude-agent-sdk.mjs` | The vendored SDK bundle (`@anthropic-ai/claude-agent-sdk` 0.3.319, built for Claude Code 2.1.319), unmodified, 1.3 MB minified. |
| `Toasty/Claude/ClaudeSDK.swift` | Keeps the SDK in step with the installed `claude`. Claude Code updates almost daily and the bundled SDK doesn't, so Toasty downloads a matching SDK from npm, checks it against npm's checksum and its `manifest.json`, runs the bridge's `selftest`, and falls back to older good copies, then the bundled one. |
| `Toasty/Claude/ClaudeConversation.swift` | The conversation model. Reads transcripts straight from disk (`~/.claude/projects/<project>/<session>.jsonl`) to show history, and reads `forkedFrom` entries to show a "Forked from …" line. |
| `scripts/update-claude-agent-sdk.sh` | Updates the vendored SDK. |

### What the bridge does

Toasty → bridge (stdin), one JSON object per line: `start`, `user` (text plus
images), `interrupt`, `permission_response`, `set_permission_mode`,
`set_model`, `stop_task`, `context_usage`, `remote_control`.

Bridge → Toasty (stdout): `ready`, `sdk` (raw SDK messages), `models`,
`commands`, `permission_request`, `permission_cancel`, `remote_control_init`,
`remote_control`, `context_usage`, `error`, `end`.

`start` configures the SDK to behave like the interactive CLI:
- the `claude_code` system prompt and tool presets;
- `settingSources: user, project, local`;
- partial messages and prompt suggestions on;
- `--replay-user-messages`;
- a `canUseTool` callback that forwards permission prompts to Toasty.

**Fork is different from everything else.**
`node toasty-agent.mjs fork '{sessionId, upToMessageId, title, dir}'` calls
the SDK's `forkSession()`. That function does **not** talk to `claude`. It
rewrites transcript files in JavaScript (see §5).

## 4. Key finding: the SDK is mostly a messenger

To learn what the SDK actually sends, a logging wrapper was put in front of
`claude` and the real Node bridge was run through it.

The SDK starts `claude` like this:

```
claude --output-format stream-json --verbose --input-format stream-json \
       --permission-prompt-tool=stdio --tools=default \
       --setting-sources=user,project,local \
       --include-partial-messages --replay-user-messages
       [--resume <id>] [--plugin-dir <path> ...]
```

It sets these environment variables (captured from a clean run):

```
CLAUDE_CODE_ENTRYPOINT=sdk-ts
CLAUDE_AGENT_SDK_VERSION=0.3.319
CLAUDE_AGENT_SDK_CLIENT_APP=toasty        (set by Toasty's bridge)
CLAUDE_CODE_SDK_READS_SESSION_STATE=1
```

Everything after that is newline-delimited JSON over stdin and stdout.

Toasty → `claude`:

```json
{"type":"control_request","request_id":"ev6q…","request":{"subtype":"initialize","promptSuggestions":true}}
{"type":"control_request","request_id":"tx66…","request":{"subtype":"set_model","model":"haiku"}}
{"type":"control_request","request_id":"2vdo…","request":{"subtype":"get_context_usage","detail":"summary"}}
{"type":"user","uuid":"…","message":{"role":"user","content":"…"},"parent_tool_use_id":null}
```

`claude` → Toasty:
- `control_response` messages, matched by `request_id`. The `initialize`
  response carries `commands`, `models`, `account`, the Remote Control flags
  and more.
- The normal SDK message stream: `system`/`init`, `stream_event`,
  `assistant`, `user`, `result`, `prompt_suggestion`, `task_*`, and so on.

Permission prompts arrive from `claude` as a request in the other direction:

```json
{"type":"control_request","request_id":"…","request":{"subtype":"can_use_tool","tool_name":"Write","input":{…},"permission_suggestions":[…],…}}
```

Toasty answers:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"…","response":{"behavior":"allow","updatedInput":{…}}}}
```

The SDK→bridge messages Toasty uses all map one-to-one:

| SDK call (in bridge) | Wire message |
|---|---|
| `query()` start | process launch with the args above, then `initialize` |
| `supportedModels()` / `supportedCommands()` / `initializationResult()` | fields of the `initialize` response |
| send prompt | `{"type":"user",…}` (images as `content` blocks) |
| `interrupt()` | `{"subtype":"interrupt"}` |
| `setModel(m)` | `{"subtype":"set_model","model":m}` |
| `setPermissionMode(m)` | `{"subtype":"set_permission_mode","mode":m}` |
| `stopTask(id)` | `{"subtype":"stop_task","task_id":id}` |
| `getContextUsage()` | `{"subtype":"get_context_usage","detail":"summary"}` |
| `enableRemoteControl(b)` | `{"subtype":"remote_control","enabled":b}` |
| `canUseTool` callback | incoming `can_use_tool` request → our `control_response` |
| close | close `claude`'s stdin |

**Caveat:** this control protocol is what the SDK uses internally. It isn't
documented as a stable public API. `claude` and the SDK are released in
lockstep, so the protocol can change between releases.

### POC 1: Swift talking to `claude` directly (no Node, no SDK)

A ~170-line Swift program did everything above directly. It ran against the
real installed `claude` (2.1.321) with Claude Code variables stripped from
the environment, as the app would run it.

| Test | Result |
|---|---|
| `initialize` | Answered in ~470 ms with 71 commands, 14 models and the Remote Control flags (the Node path takes ~570 ms) |
| Permission prompt round trip | `claude` asked to use Write; Swift allowed it; the file was created |
| `set_model`, `set_permission_mode` | ok |
| Streaming text, prompt suggestions | received |
| `get_context_usage` | ok |
| `interrupt` mid-reply | stopped about 13 ms after the request |
| Resume the session in a new process | remembered the earlier turn |
| Image attachment (base64 PNG) | model identified the color correctly |
| Background task + `stop_task` | stopped in ~12 ms; no leftover process |
| Remote Control on/off | ok; returned `session_url` and `connect_url` |
| Plugins | just `--plugin-dir` arguments; Toasty doesn't pass any today |

Conclusion: **everything except fork** can be done from Swift with no Node.
The SDK is only relaying messages for these features.

## 5. The hard part: fork

### What Toasty needs from fork

"Fork from here" on a message creates a new saved session containing the
conversation up to and including that message, with a title. Toasty then
opens it in a new tab. Toasty relies on:

1. **The new session ID, returned immediately.** The fork exists on disk
   before the user types anything.
2. **The transcript file existing right away.** Toasty shows history by
   reading the `.jsonl` file directly.
3. **`forkedFrom` entries in the new transcript**
   (`{"forkedFrom":{"sessionId":…,"messageUuid":…}}`), which drive the
   "Forked from …" line (`ClaudeConversation.forkOrigin`).

### Why fork isn't just a message to `claude`

The SDK's `forkSession()` runs **in JavaScript**, inside the SDK, and edits
Claude Code's transcript files itself. Reading the minified code shows it:

- loads the source `.jsonl` and keeps only the main chain (drops sidechain
  and subagent entries);
- **rebuilds the real message chain across compactions.** After a
  compaction, a `compact_boundary` entry's `compactMetadata`
  (`preservedMessages` / `preservedSegment`) re-links preserved messages to
  new parents, so the file order is not the chain order;
- cuts at `upToMessageId`, running an iterative trimming pass when the cut
  falls near a compaction boundary;
- gives every kept entry a **new UUID**, and rewrites every reference to the
  old ones: `parentUuid`, `logicalParentUuid`, UUIDs inside `compactMetadata`,
  `deferred_tools_record` attachment announcements, attachment `source_uuid`
  and others;
- skips `progress` entries, re-linking parents across them without looping;
- carries over session-wide records (`content-replacement`, `atis-latch`,
  `tools-used`, `relocated`, `history-suppression`), but only when they
  belong to the source session;
- stamps every copy with `forkedFrom` and appends a `custom-title`.

**Why the SDK can do this:** the SDK bundle is built by Anthropic from Claude
Code's own source and released in lockstep. Its version file says "built for
Claude Code 2.1.319", and the bundle even contains Claude Code's full
environment-variable registry. The fork logic is Claude Code's internal
transcript code, compiled into the package. The transcript format is
**private and changes often**, and the SDK stays correct because it ships
with matching code. This is also why Toasty already downloads an SDK that
matches the installed `claude`.

So removing Node removes the only runtime that can run this code. Fork needs
its own answer.

## 6. Options for fork

### A. Rewrite `forkSession` in Swift

- Pros: no Node and no JavaScript; fast.
- Cons: Toasty would own a frozen copy of Claude Code's private transcript
  format, a few hundred lines of subtle logic covering compaction chains, ID
  remapping and special record types. When Claude Code changes the format,
  nothing tells us.
- **Failure mode: silent.** Forks come out subtly wrong (bad parent links,
  dangling IDs, wrong history), most likely on long, compacted conversations,
  which are exactly the ones people fork.
- Verdict: rejected as the riskiest option.

### B. Let `claude` fork itself

`claude --resume <id> --fork-session --resume-session-at <messageUuid>`

Tested: it forks correctly at the cut point. The fork remembered the turn
before the cut and not the turn after, and the original file was untouched.

- Pros: Claude Code's own code, always matching the installed version. No
  transcript editing in Toasty.
- Cons:
  - `--resume-session-at` is a **hidden flag**. It isn't in `claude --help`,
    though the SDK passes it to `claude` for its own `resumeSessionAt`
    option. `--fork-session` is documented.
  - **No file until the first message.** Started with no prompt, `claude`
    assigns a new session ID and accepts `rename_session`, but writes nothing
    to disk until a user message is sent. Toasty would have to show history
    from the source transcript, cut at the fork point, until then. A fork
    closed before typing is never saved.
  - **No `forkedFrom` entries.** The fork file `claude` writes has none, so
    Toasty would have to record the fork's origin itself (for example in
    workspace state).
  - It's a separate code path from the SDK's `forkSession`, so small
    differences are possible.
- **Failure mode: loud.** If the flag changes, the fork fails with an error.

### C. Keep Node only for fork

- Pros: zero risk to fork.
- Cons: defeats the purpose, since the user still installs Node. Possible
  only as a temporary step.

### D. Translation layer: run the SDK's own `forkSession` in JavaScriptCore

macOS ships JavaScriptCore, the engine Safari uses, as a system framework, so
there is nothing to install. The SDK bundle is loaded unmodified from disk.
At load time, its Node imports are rewritten to point at small stand-ins, and
Swift supplies the real work behind them.

#### POC 2 (completed)

The translation layer:
- **Node stand-ins (~250 lines of JavaScript):**
  - real implementations of the file functions fork needs: `fs`,
    `fs/promises` (read, write, append, `readdir`, `stat`, `lstat`, `mkdir`,
    `realpath`, `rename`, `open` for reading) and a buffered
    `createWriteStream`;
  - `path` (POSIX), a `Buffer` subset, `crypto` (`randomUUID`,
    `randomBytes`, `createHash` through CryptoKit), `os`, `events`
    (`EventEmitter`, `once`), `util`, `string_decoder`, `url`,
    `async_hooks.AsyncLocalStorage`;
  - `process`, timers, `TextEncoder`/`TextDecoder`, `AbortController`,
    `URL`, `DOMException`.
- **Stubs:** modules fork never uses (`child_process`, `net`, `readline`,
  `module.createRequire`) and web APIs it never calls (`fetch`, `Response`
  and so on) exist so the file loads. **Calling any of them throws a named
  error.** An unknown function on any stand-in module also throws when called.
- **Swift host (~250 lines):**
  - backs the stand-ins: file I/O, UTF-8 encoding and decoding, hashing,
    timers;
  - passes file bytes to JavaScript as `Uint8Array` without copying;
  - **refuses all writes outside an allowed root**, a safety guard for the
    test that would also be useful in the app.
- **Load-time rewrite** of the SDK file, done mechanically each load:
  - drop the `#!` line;
  - turn the 123 `import … from "<node module>"` statements, in three
    syntactic forms, into hoisted `const … = __node("<module>")` lookups;
  - turn the final `export{…}` into `globalThis.__sdk = {…}`;
  - replace `import.meta.url` with the file's own URL;
  - wrap everything in an async function.

#### Test

Three real sessions were copied into a scratch folder:

| Session | Size | Compactions |
|---|---|---|
| 1 | 85 MB, 5,895 lines | 2 |
| 2 | 13 MB | 1 |
| 3 | 2 MB | 1 |

Ten fork points were chosen: before a compaction, just after each
compaction, and near the end. The **Node SDK** and the **JavaScriptCore**
version each forked separate copies, with `HOME` and `CLAUDE_CONFIG_DIR`
pointed into the sandbox. Outputs were compared after replacing only the
newly created UUIDs, in order of first appearance, and newly created
timestamps. Everything else, including every timestamp that exists in the
source, had to match exactly.

#### Result

**10 of 10 forks were identical to Node's output.** The largest was a
77.6 MB, 2,685-line fork. `forkedFrom` entries were present.

| | Node | JavaScriptCore |
|---|---|---|
| Fork time | 14–356 ms | 24–280 ms |
| SDK load, once per app session | — | 370 ms |

No writes happened outside the sandbox, the real `~/.claude/projects` was
untouched, and the repo was clean.

During bring-up, three load-time problems appeared: the `#!` line, two
missing import forms, and missing `SharedArrayBuffer`/`DOMException`. Each
failed **immediately, with a clear error**, before any fork ran.

- Pros: runs **Anthropic's exact fork code**, matched to the installed
  `claude`. Behavior is unchanged: immediate file, `forkedFrom`, title, and
  the cut and compaction logic. Toasty's existing SDK download, checksum,
  manifest and `selftest` keep working and keep the code in step.
- Cons:
  - Toasty maintains a small fake Node. A future SDK might import or call
    something new and need another stand-in.
  - The import rewrite depends on the shape of the bundler's output (esbuild
    or Bun-style ES modules with named Node imports). A big change in how the
    SDK is bundled would need the rewrite updated.
  - 370 ms to load the SDK once. It can happen in the background, or lazily
    on the first fork.
  - Only one SDK version (0.3.319) has been tested so far.
- **Failure mode: loud,** and the existing `selftest` can catch it before a
  user-facing fork. For example, run a fork of a tiny fixture transcript as
  part of the selftest.

## 7. Current recommendation

1. **Conversations:** Swift talks to `claude` directly using the protocol in
   §4. Node and the SDK drop out of the per-tab path.
2. **Fork:** option D, the SDK's own `forkSession` in JavaScriptCore.
3. **Keep** `ClaudeSDK.swift`'s matching-SDK download and validation. Its
   job changes from "the code every tab runs" to "the code fork runs", and
   its `selftest` runs in JavaScriptCore instead of Node.
4. **Rollout without risk to the daily driver:**
   - build the new path behind a setting, keeping Node as the default;
   - add a parity harness that runs the same scripted conversation and the
     same forks through both paths and diffs the results;
   - dogfood, then flip the default, then delete the Node path;
   - rollback at every step is flipping the setting.

Resulting requirements for users: **macOS 26 and Claude Code.** Nothing else.

## 8. Open questions and things a reviewer might challenge

- **Protocol stability.** The control protocol is SDK-internal. Today a
  protocol change is absorbed by downloading a matching SDK. In Swift, we
  absorb it by hand. How do we detect drift early?
  - One idea: run the parity harness against each new `claude` version.
  - Another: also run the SDK's `query()` path inside JavaScriptCore, so the
    SDK still speaks the protocol and Swift only relays, as today. That
    requires stand-ins for `child_process.spawn` and streams, a much bigger
    fake Node, but it would cover protocol drift too. **Not tested.**
- **Is there an official, Node-free way?** For example, a future Claude Code
  command such as `claude session fork`, or a documented stream-json
  `fork_session` control request. Asking Anthropic, or watching for one,
  could make D unnecessary.
- **Hidden flag in B.** `--resume-session-at` works today and the SDK depends
  on it too, but it is undocumented.
- **Unknown environment-variable effects.** `CLAUDE_AGENT_SDK_VERSION`
  (which version should a Node-less Toasty report?) and
  `CLAUDE_CODE_SDK_READS_SESSION_STATE` are set by the SDK. Their exact
  effects on Claude Code aren't known.
- **Bun.** The native `claude` binary is a compiled Bun executable. Running
  JavaScript through it (`BUN_BE_BUN=1 claude script.mjs`) was tried and
  **doesn't work**: `claude` treated the path as a prompt.
- **Alternatives not explored:**
  - another embedded JavaScript engine (QuickJS and the like): more control,
    but more to ship;
  - asking `claude` itself to run the fork through some existing
    subcommand, if one exists.

## 9. Detailed test results

Environment for every test:
- macOS 27 (Darwin 27.0.0), Apple Silicon;
- Claude Code 2.1.321 (native install at `~/.local/bin/claude`);
- Agent SDK 0.3.319 (the vendored copy);
- Node 22.19.0 for the baselines;
- date: 2026-11-09.

Model calls used Haiku. Raw outputs are in
[`no-node-poc/`](no-node-poc/README.md).

### 9.1 Protocol capture (what the SDK actually does)

The real bridge was run with a logging wrapper in place of `claude`. Files:
`no-node-poc/0-protocol-capture/`.

- Arguments: see §4 (`sdk-claude-argv.txt`).
- Environment added by the SDK on a clean run (`sdk-added-env.txt`):
  `CLAUDE_AGENT_SDK_CLIENT_APP=toasty`,
  `CLAUDE_AGENT_SDK_VERSION=0.3.319`, `CLAUDE_CODE_ENTRYPOINT=sdk-ts`,
  `CLAUDE_CODE_SDK_READS_SESSION_STATE=1`. Nothing is removed.
- stdin for a session that started, changed the model, asked for context
  usage and sent one prompt was **4 lines**: `initialize`, `set_model`,
  `get_context_usage` and the `user` message (`sdk-to-claude-stdin.jsonl`).
  The SDK sends nothing else.

### 9.2 POC 1: Swift ↔ `claude`, no Node

Files: `no-node-poc/1-direct-protocol/`.

| # | Test | Expected | Observed | Pass |
|---|---|---|---|---|
| 1 | `initialize` | success with commands and models | success at 491 ms; 71 commands, 14 models; 23 response keys including `remote_control_auto_enable` and `current_permission_mode` | ✅ |
| 2 | `set_model haiku` | success | success; `init` then reports `model=claude-haiku-5-5` | ✅ |
| 3 | `set_permission_mode default` | success | success | ✅ |
| 4 | Permission round trip | `can_use_tool` request, our allow is honored | `can_use_tool` for `Write` arrived at 2,678 ms with `file_path` and `content`; allowed; `poc.txt` contained `toasted` | ✅ |
| 5 | Streaming | `stream_event` text deltas, then `assistant`, then `result` | first token at 4,250 ms; `result success end_turn` | ✅ |
| 6 | `get_context_usage` | totals and percentage | `26848/1000000 (3%)` | ✅ |
| 7 | `interrupt` mid-stream | stops promptly | request at 8,347 ms, ack at 8,360 ms; `result error_during_execution` (expected after an interrupt) | ✅ |
| 8 | Close stdin | `claude` exits | exited, status 1 after the interrupt run and 0 on other runs; not yet compared with the Node path | ⚠️ minor |
| 9 | `--resume` in a new process | remembers earlier turns | asked what word it wrote; answered `toasted` | ✅ |
| 10 | Prompt suggestion | `prompt_suggestion` message | `continue counting from 65` | ✅ |
| 11 | Image attachment (64×64 blue PNG, base64 `content` block) | model sees the image | answered `Blue.` | ✅ |
| 12 | Background task | `task_started` with an id | Bash `sleep 120` in the background; `task_started task_id=b1sp1desu` | ✅ |
| 13 | `stop_task` | task stops, process killed | `task_notification status=stopped` 13 ms after the request; 0 `sleep 120` processes left | ✅ |
| 14 | `remote_control` on | URLs returned | success; `session_url` and `connect_url` present | ✅ |
| 15 | `remote_control` off | success | success | ✅ |
| 16 | `set_permission_mode bypassPermissions` | refused without the launch flag (same as the SDK path) | refused: "session was not launched with --dangerously-skip-permissions" | ✅ (expected) |

Startup, from launch until the model list is available:

| Path | Runs |
|---|---|
| Node bridge | 570, 580, 568 ms |
| Swift direct | 491, ~465 ms |

The difference is about 100 ms per tab.

### 9.3 Option B: `claude` forks itself

File: `no-node-poc/results-cli-fork.txt`.

| Test | Observed |
|---|---|
| Fork with `--resume … --fork-session --resume-session-at <end of turn 1>`, then ask what came before | Listed only turn 1. Turns 2 and 3 were excluded, so the cut point was honored. |
| Original transcript after the fork | md5 unchanged |
| Same flags, stream-json mode, no user message | new session ID assigned; `rename_session` succeeds (emits `session_title_changed`); **no file written** |
| `forkedFrom` fields in the fork file | **none** |
| `claude --help` | lists `--fork-session`; does **not** list `--resume-session-at` |

### 9.4 POC 2: the SDK's `forkSession` in JavaScriptCore

Files: `no-node-poc/2-jsc-fork/`.

**Load:** 123 import statements rewritten; SDK loaded and initialized in
370 ms. Bring-up failures, each immediate and named:
1. `SyntaxError: Invalid character '#'`, from the `#!` line;
2. `Unexpected token '*'` and `Unexpected identifier 'Et'`, from two import
   forms not yet handled;
3. `Can't find variable: SharedArrayBuffer`;
4. `Can't find variable: DOMException`.

After those fixes there were no further errors, and no stub was called
during any fork.

**Sources:**

| Session | Lines | Size | Compactions |
|---|---|---|---|
| `1daaf8a2…` (Toasty) | 5,895 | 85 MB | 2 |
| `a02f388a…` (Toasty) | 3,158 | 13 MB | 1 |
| `b510a685…` (another project) | 733 | 2 MB | 1 |

**Parity:** after normalizing only new UUIDs and new timestamps,
`results-compare.txt` reports:

| Case | Fork lines | Fork size | Node | JSC | Result |
|---|---|---|---|---|---|
| 1daaf8a2 / before-compaction | 191 | 1.5 MB | 150 ms | 166 ms | IDENTICAL |
| 1daaf8a2 / after-compaction-1 | 392 | 15.1 MB | 165 ms | 172 ms | IDENTICAL |
| 1daaf8a2 / after-compaction-2 | 1,477 | 52.9 MB | 275 ms | 240 ms | IDENTICAL |
| 1daaf8a2 / near-end | 2,685 | 77.6 MB | 356 ms | 280 ms | IDENTICAL |
| a02f388a / before-compaction | 158 | 1.3 MB | 41 ms | 78 ms | IDENTICAL |
| a02f388a / after-compaction-1 | 341 | 2.0 MB | 41 ms | 77 ms | IDENTICAL |
| a02f388a / near-end | 1,398 | 12.1 MB | 78 ms | 122 ms | IDENTICAL |
| b510a685 / before-compaction | 169 | 0.9 MB | 14 ms | 24 ms | IDENTICAL |
| b510a685 / after-compaction-1 | 321 | 1.6 MB | 15 ms | 26 ms | IDENTICAL |
| b510a685 / near-end | 315 | 1.6 MB | 15 ms | 27 ms | IDENTICAL |

**What each fork contains** (`results-fork-files.txt`):
- every copied message carries `forkedFrom` (fork lines minus 3);
- there is 1 `custom-title`, 1 `atis-latch` and 1 `tools-used` record;
- `compact_boundary` records are carried over when the cut is past a
  compaction.

One observation: `b510a685 / near-end` has 0 compaction boundaries even
though its source has 1. Node's output is identical, so this is the SDK's
own behavior, not a translation-layer artifact.

**How strict the comparison is:** UUIDs that appear in the source
transcript must match exactly. Only UUIDs created by the fork are mapped to
placeholders (`NEW0`, `NEW1`, … in order of first appearance), so the link
structure is still compared. Timestamps that appear in the source must match
exactly; only new ones are blanked.

**Safety checks:**
- The Swift host refuses writes outside `TOASTY_WRITE_ROOT` (the scratch
  folder).
- `HOME` and `CLAUDE_CONFIG_DIR` pointed into the scratch folder for both the
  Node and JSC runs.
- After the runs there were no new files under the real
  `~/.claude/projects/` folders for these projects, the source copies' md5s
  were unchanged, and `git status` in the repo was clean.

### 9.5 Other attempts

- `BUN_BE_BUN=1 claude script.mjs` treats the path as a prompt, so the
  `claude` binary can't be used as a JavaScript runtime
  (`no-node-poc/results-bun-attempt.txt`).

## 10. Files

**In the app today** (affected by this proposal):

| File | Role |
|---|---|
| `Toasty/Claude/ClaudeAgent.swift` | process launch, environment resolution (finds `node`), `fork` |
| `Toasty/Claude/ClaudeSDK.swift` | download, validation and selection of the SDK matching `claude` |
| `Toasty/Claude/ClaudeConversation.swift` | the conversation model; reads transcripts and `forkedFrom` from disk |
| `Toasty/Resources/Bridge/toasty-agent.mjs` | the Node bridge |
| `Toasty/Resources/Bridge/claude-agent-sdk.mjs` | the vendored SDK |
| `scripts/update-claude-agent-sdk.sh` | updates the vendored SDK |
| `project.yml` | copies `Resources/Bridge` into the app bundle |

**POC sources and raw results:** `docs/no-node-poc/`. Its
[README](no-node-poc/README.md) lists every file and how to rerun the tests.
