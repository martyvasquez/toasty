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
