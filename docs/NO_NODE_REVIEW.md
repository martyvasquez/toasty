# Removing Node: independent review

Reviewed 2026-11-10 against [`NO_NODE.md`](NO_NODE.md) and the proofs of concept in
[`no-node-poc/`](no-node-poc/README.md).

Versions tested: `claude` 2.1.322, Agent SDK 0.3.319 (the bundled
`Toasty/Resources/Bridge/claude-agent-sdk.mjs`), Node 22.19.0.

Every claim is marked **V** (verified in this review), **I** (inferred from code,
not run) or **S** (speculative). Citations into the SDK are minified snippets,
because the bundle has no stable line numbers.

## Outcome

**Keep Node for now.** The review found nothing wrong with the Node path. Removing
it is feasible, but it swaps a one-line install requirement for hand-written
protocol code and a fake Node that both need checking on every `claude` release.

Two small improvements to the Node path are worth making regardless:

- **Check for Node at launch.** Today a missing Node only surfaces as `.noNode`
  when a conversation starts (`Toasty/Claude/ClaudeAgent.swift:213-217`).
- **Make the selftest test something.** It only checks
  `typeof query === "function" && typeof forkSession === "function"`
  (`Toasty/Resources/Bridge/toasty-agent.mjs:31-35`). Forking a small bundled
  fixture and comparing it to a stored result would catch a bad SDK download.

### When to revisit

- Toasty is distributed to people who don't have Node. Claude Code's own
  installer no longer needs it, so this is likely for non-developers.
- Anthropic makes `fork_conversation` work locally (see [Fork](#fork-without-node)).
  That removes the hardest part of the plan.
- The roughly 100 ms per-tab start cost or the extra process per tab becomes a
  real complaint.

If it is revisited, the recommended shape is in
[If we remove Node later](#if-we-remove-node-later).

## What was reproduced

### Fork in JavaScriptCore (POC 2): matches, and holds on a wider set

The original 10 cases were widened to 261 across 5 copied sessions:

- first entry, last entry, no cut point, no title, a Unicode title, a bad id
- two cut points for every record kind present
- every entry from 2 before to 3 after each compaction boundary
- a session with a `subagents` directory, and a fork of a fork

| Result | |
|---|---|
| Successful forks identical between Node and JavaScriptCore | 256 of 256 (**V**) |
| Bad-id cases | 5, same error text in both (**V**) |
| File mode of every output | 0600 in both (**V**) |
| SDK load time in JavaScriptCore | 390 ms (**V**) |

Cost of one fork of the 85 MB session (**V**):

| | Time | Peak resident memory |
|---|---|---|
| Node | 0.48 s | 319 MB |
| JavaScriptCore | 0.70 s | 531 MB |

### Direct protocol (POC 1): not rerun

POC 1 makes model calls, which needs the logged-in config and would write to the
real `~/.claude`. A no-token probe in a scratch config was run instead
([`no-node-poc/3-review/probe.py`](no-node-poc/3-review/probe.py)) (**V**):

- `initialize` is answered at 492 ms with the same 23 keys the SDK receives.
- `get_context_usage` works before any prompt.
- An unknown control subtype gets an error response.
- `rename_session` emits `session_title_changed`.
- Closing stdin exits with status 0.
- No transcript is written until the first user message.

## Claims in NO_NODE.md that don't hold

| Claim | Finding |
|---|---|
| `b510a685 / near-end` has 0 compaction boundaries because of an SDK quirk | The case is mislabeled. Its cut is entry 311 and the boundary is entry 316, so it is a "just before compaction" case. (**V**) |
| The fork logic is Claude Code's internal transcript code | Partly. The CLI's own branch code keeps the original UUIDs (`{...f,sessionId:r,parentUuid:P,isSidechain:!1,forkedFrom:{...}}`, near "No messages to branch"). The SDK's `forkSession` remaps them. They are two implementations. (**V**) |
| Option D fails loudly | Only for missing functions. Options the fake Node doesn't understand are dropped silently; see [Fork risks](#fork-in-javascriptcore-option-d). (**V**) |
| The selftest protects against a broken SDK | It checks two function types and nothing else. (**V**) |
| `compare.py` shows the fork is correct | It shows Node and JavaScriptCore agree. It never checks that `claude` can load the result. (**V**) |

## Risks NO_NODE.md missed

### Swift speaking the protocol directly

The SDK does more than relay lines. A Swift replacement has to copy each of
these, all read from the bundled SDK (**V** in code, live impact **I**):

- **Requests it deliberately leaves unanswered.** `remote_tool_call`,
  `remote_plumbing_call`, `remote_tools_probe` and `remote_tools_reannounce`
  get no reply, and neither does `request_user_dialog` without a handler.
  `elicitation` without a handler gets `{action:"decline"}`. The POC replies
  `error` to everything (`no-node-poc/1-direct-protocol/poc.swift`, the
  non-`can_use_tool` branch), which is wrong when Remote Control is on.
- **Cancelled prompts.** `control_cancel_request` aborts the pending callback,
  which is what produces Toasty's `permission_cancel`
  (`toasty-agent.mjs:70-75`). The POC only logs it.
- **`toolUseID` on every permission reply.**
  `return{...r,toolUseID:e.request.tool_use_id}`. The example in `NO_NODE.md`
  omits it.
- **Prompt redelivery.** The `initialize` response can carry
  `pending_permission_requests` and `pending_user_dialog_requests`, which the
  SDK re-dispatches.
- **Duplicate guard.** A second `control_request` with an in-flight
  `request_id` is skipped.
- **Filtered frames.** `keep_alive`, `transcript_mirror`, and
  `session_state_changed` with `sdk_host_only` never reach the app. Low risk:
  `ClaudeConversation.swift` ignores unknown message types.
- **Environment.** The SDK deletes `NODE_OPTIONS`, sets or deletes `DEBUG`, and
  sets `CLAUDE_CODE_ENTRYPOINT=sdk-ts`, `CLAUDE_AGENT_SDK_VERSION` and
  `CLAUDE_CODE_SDK_READS_SESSION_STATE=1`. `poc.swift:27-29` sets only two of
  these (`poc2.swift` sets the full set).
- **Shutdown.** End stdin, SIGTERM after 2 s, SIGKILL 5 s later, and kill
  tracked children on exit.
- **Error text.** A non-zero exit becomes
  `Claude Code process exited with code N. stderr: …`, and an error `result`
  takes priority over it. The POC's exit status 1 after an interrupt would show
  as a fatal error unless mapped the same way.

The SDK defines 60 control subtypes; Toasty uses about 10 (**V**).

### Fork in JavaScriptCore (option D)

- **Memory.** 531 MB peak for the largest session would land inside Toasty if
  the fork ran in-process. (**V**)
- **Dropped options.** `prelude.js` `writeFileSync` honors only `flag: "a"`, so
  an exclusive-create `wx` would overwrite. Its write stream ignores `mode`;
  the Swift host happens to hardcode 0600. Every `stat` failure is reported as
  `ENOENT`. None of these bite on SDK 0.3.319, but a future SDK that relies on
  one would misbehave quietly. (**V**)
- **Non-atomic write.** The SDK writes the fork with
  `createWriteStream(path,{mode:384,flags:"w"})`, and the fake stream buffers
  the whole file in memory before writing. (**V**)
- **Untested branches.** None of the 205 local sessions between 0.2 and 40 MB
  has a `progress` or `isSidechain:true` entry in its main file, so those fork
  paths have not run in either engine. (**V**)

### Fork behavior that exists today

A fork cut just before a compaction restores the full uncompacted history. For
session `b510a685` at entry 311 that is 246,319 tokens, against 36,038 for the
source session resumed as-is. This can exceed a 200k context window. It is how
the SDK behaves under Node too. (**V**)

### Transcript storage

Both the SDK and the `claude` binary contain an alternate transcript store
gated by `CLAUDE_CODE_HOVER_REST`. If it reaches local installs, anything that
reads `.jsonl` files directly breaks, including Toasty's transcript reading,
whatever happens to Node. (**S**)

## Fork without Node

| Route | Finding |
|---|---|
| `fork_conversation` control request | Present in `claude` 2.1.322 (`target_message_uuid`, `title`) but answers `{"forked":false,"error":"unsupported"}` without a Remote Control server. Not in SDK 0.3.319. (**V**) |
| Option B: `--resume --fork-session --resume-session-at` | Fails for a cut point before a compaction: `No message found with message.uuid of: 1b4d356b-…`. Toasty shows pre-compaction history, so "Fork from here" would break there. (**V**) |
| Option B, context loaded | Differs from the SDK fork. Just after the boundary: 4,500 message tokens against the SDK's 5,168. At entry 311: 18,221 total against 246,319. Equal only at the last entry. (**V**) |
| Option B with `--session-id` | Accepted together with the fork flags, so the new id can be chosen up front. Still no file before the first message. (**V**) |
| `rewind_conversation` after a plain fork | Inconclusive: no response captured. |
| Whole SDK in JavaScriptCore | Needs `child_process`, streams and `readline` stand-ins. Bugs would be hangs or lost final messages, and the per-tab speed gain goes away. (**I**) |
| `claude` binary as a JavaScript runtime (`BUN_BE_BUN=1`) | Ignored; the binary starts Claude Code as normal. (**V**) |

## If we remove Node later

Ranking against the constraints in `NO_NODE.md`:

1. Swift speaks the protocol, fork runs the SDK's `forkSession` in a
   **helper process**, hardened as below.
2. Swift speaks the protocol, fork uses option B with `--session-id`. Loses
   forks before a compaction and loads a different context.
3. Whole SDK in JavaScriptCore.
4. Node only for fork. Doesn't meet the goal.
5. Fork rewritten in Swift. Drifts from Claude Code.

Changes to the original recommendation:

- **Helper process, not in-app.** Isolates the memory spike, crashes and
  downloaded JavaScript.
- **Strict stand-ins.** Throw on any option or flag the fake Node doesn't
  implement, not only on unknown functions.
- **Check every fork before opening it.** Every `parentUuid` resolves, one
  `sessionId` throughout, no source UUID reused, `custom-title` last. Write to
  a temporary file and rename.
- **Responder that mirrors the SDK.** Every rule under
  [Swift speaking the protocol directly](#swift-speaking-the-protocol-directly).
- **Never fall back to option B silently.** It is a different fork.
- **Keep downloading the SDK** as the reference for drift checks.

### Validation still needed

Fork:

- Node against the helper on every local session over 200 KB, same cut-point
  scheme as this review.
- Sessions interrupted mid-tool-call, resumed many times, and the largest
  available.
- Synthetic fixtures for `progress` chains (including a cycle), sidechain
  entries, `content-replacement` and `relocated`.
- Have `claude` load each fork: `--resume <fork>` followed by
  `get_context_usage` costs no tokens and writes no transcript. Totals must
  match the Node fork's.

Protocol:

- Record `claude`'s stdout for scripted sessions through both paths and compare
  what reaches `ClaudeConversation`.
- Cover permission allow, deny and cancel; interrupt mid-tool; closing a tab
  mid-tool with a check for orphaned processes; an MCP elicitation; Remote
  Control with a remote prompt; images; resume; a failing hook.

Drift, on each new `claude` or SDK version:

- Compare the SDK bundle's control subtypes and `claude` arguments against a
  stored list of the ones Toasty depends on.
- Run the no-token handshake: `initialize`, `get_context_usage`, one unknown
  subtype expecting an error. About half a second.
- Fork a bundled fixture and compare it to the stored result.
- On any failure, show a clear error and use the Node path if Node is present.

## Not tested in this review

- POC 1 with model calls.
- Closing stdin in the middle of a turn.
- Any Remote Control request handled live.
- Option B at more cut-point kinds (the helper script crashed and was not
  rerun; only the three points above were measured).

## Questions for Anthropic

- Is the stream-json control protocol supported for hosts that aren't the SDK,
  and what should they send for `CLAUDE_CODE_ENTRYPOINT` and
  `CLAUDE_AGENT_SDK_VERSION`?
- Will `fork_conversation`, or a fork subcommand, work locally and write
  `forkedFrom`?
- Is `--resume-session-at` stable, and is refusing targets before a compaction
  intended?
- Which fork is canonical: the SDK's (new UUIDs) or the CLI's branch (same
  UUIDs)?
- Will local transcripts stay plain `.jsonl`?

## Review files

In [`no-node-poc/3-review/`](no-node-poc/3-review/):

- `cases.json`: the 261 fork cases. Session ids are from the reviewer's
  machine; the cut-point scheme is what carries over.
- `run-node.mjs`: the Node baseline, taking each case's options as given.
- `probe.py`: the no-token protocol probe. Arguments are a scratch config
  directory, a scratch home and a working directory; extra control requests go
  in the `PROBE` environment variable as a JSON list.

The JavaScriptCore side used `no-node-poc/2-jsc-fork/jscfork.swift` with one
line changed to pass each case's `opts` through unchanged.
