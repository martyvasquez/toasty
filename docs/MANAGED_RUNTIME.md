# A Claude Code runtime that Toasty manages

Status: **proposal.** Nothing here is implemented. Written 2026-11-22 after a
friend's first install got stuck at the setup check.

This document is written for someone who hasn't seen the codebase or the
conversation that produced it. Claims are marked **V** (verified while writing
this), **I** (inferred from code or documentation, not run) or **S**
(speculative).

---

## 1. The problem

A friend installed Toasty and couldn't get past the setup check. The sheet
said Claude Code 2.1.301 was too old and Toasty needed 2.1.319 or later. He
ran Fix in Terminal, then `claude update` in his own Terminal, which reported
2.1.330 and "up to date". The sheet still said 2.1.301.

He had everything Toasty needs: Claude Code, Node and a signed-in account.
What went wrong was **which copy** Toasty looked at (**V**, from his
command output):

- He uses **fnm** to manage Node. His home folder names Node 23.10.0, so a
  Terminal window, which starts in the home folder, uses Node 23 and the
  `claude` installed with it (2.1.330).
- Toasty asked his login shell for its PATH from **`/`**, the app's own
  folder. fnm doesn't apply the home folder's version there, so it fell back
  to its default, Node 22.22.0, which has no `claude` of its own.
- The first `claude` on that PATH was **Homebrew's**,
  `/opt/homebrew/bin/claude`, at 2.1.301. That's the one the check reported.
- Fix in Terminal runs in the home folder, so `claude update` updated the
  Node 23 copy, which the check never looked at. Changing fnm's default didn't
  help either: the `/` shell still came up on Node 22.
- Separately, `claude update` in the sheet's terminal failed with "Unable to
  fetch latest version from npm registry". It worked in his own Terminal a
  moment later. Cause unknown.

He got through with `brew upgrade claude-code`. That's not something a new
user should have to work out by texting the developer.

## 2. How Toasty finds Claude Code and Node today

`ClaudeEnvironment` (`Toasty/Claude/ClaudeAgent.swift`) runs the user's shell
as an interactive login shell (`$SHELL -i -l -c 'env -0'`), so `.zprofile` and
`.zshrc` are read the way a terminal tab would read them. It keeps that
environment and takes the first `node` and the first `claude` on its PATH,
then a few fixed folders (`~/.local/bin`, `~/.claude/local`,
`/opt/homebrew/bin`, `/usr/local/bin`, and nvm's versions for Node).
`ClaudeSetup` checks their versions and `claude auth status --json`, and the
setup sheet blocks the window until everything passes.

Conversation tabs then run the bundled Node bridge (`toasty-agent.mjs`) with
that `node`, and the Agent SDK runs that `claude`. `ClaudeSDK` keeps the
bundled SDK matched to the installed `claude`, downloading newer SDKs from npm
in the background.

### Where this breaks

- **Version managers** (fnm, nvm, asdf, mise) choose a version based on the
  folder the shell starts in. A shell started from `/` can get a different
  Node, and a different `claude`, from the one the user's terminal gets.
  Fixed in a83e9a818: the lookup now starts in the home folder.
- **Several copies.** It's common to have two or more `claude` installs: the
  native installer's (`~/.local/bin`), Homebrew's, and one per Node version
  from `npm install -g`. Toasty takes the first. The user usually doesn't know
  which one that is. Fixed in a83e9a818: the "too old" row shows the path,
  and says when a newer `claude` comes later on the PATH.
- **Updating the wrong copy.** Fix in Terminal ran `claude update`, which
  updates whichever `claude` comes first on *its* PATH. Fixed in a83e9a818:
  it runs the checked copy by its full path, and a Homebrew copy is updated
  with `brew upgrade`.
- **Node itself.** Anyone without Node has to install it only so Toasty's
  bridge can run. Claude Code's own native installer doesn't need Node (**V**:
  `install.sh` downloads a single binary).
- **Every Mac is different.** Each of these is a fix for one setup. The next
  setup may break in a way nobody has seen yet.

## 3. Options

### A. Keep looking on the user's PATH, with the fixes

What ships today: the fixes above, released in a83e9a818.

- **For:** small, no new download code, uses exactly the `claude` the user
  runs in their terminal.
- **Against:** stays dependent on each user's shell setup. Still needs Node.
  Every new kind of setup is a new bug report.

### B. Bundle Claude Code and Node inside the app

- **Size (V):** the native Claude Code binary for Apple silicon is 364 MB
  (2.1.330, from Anthropic's release manifest). Node is about 120 MB. Together
  that's close to half a gigabyte added to the app and to every Sparkle
  update.
- **Release cadence:** Claude Code releases almost daily. A bundled copy goes
  stale within days, so either Toasty ships an update for each Claude Code
  release or the bundled copy needs its own updater, which is option C anyway.
- **Verdict:** not worth it for Claude Code. Possible for Node (stable,
  MIT-licensed), but see §6: the plan is to replace Node rather than ship it.

### C. Toasty manages its own runtime (recommended)

Toasty downloads the official Claude Code build from Anthropic into its own
folder, checks it, keeps it updated in the background and uses it for
conversation tabs. This is the same pattern `ClaudeSDK` already uses for the
Agent SDK.

How Anthropic's installer gets the binary (**V**, read from
`https://claude.ai/install.sh`):

- `https://downloads.claude.ai/claude-code-releases/latest` and `…/stable`
  name the current versions (2.1.330 and 2.1.323 when this was written).
- `…/<version>/manifest.json` gives each platform's SHA-256 and size.
- `…/<version>/darwin-arm64/claude` is the binary. A zstd-compressed
  `claude.zst` is listed in `manifest.zst.json` with its own checksum and is
  **124 MB** for 2.1.330, about a third of the uncompressed size.
- The installer then runs `claude install`, which sets up `~/.local/bin` and
  shell integration. **Toasty must not do this step.** It would change the
  user's own install. Toasty only keeps the binary in its own folder.

Policy for which copy conversations use:

1. **Always Toasty's own copy (recommended).** Most predictable: the version
   is always one Toasty has been tested with, and the setup check shrinks to
   signing in.
2. **The user's copy when it's fine, otherwise Toasty's.** Respects people who
   pin a version, but keeps the PATH discovery that failed in §1.

Under option 1, people who want their own `claude` can choose it in Settings
under Advanced. That brings back today's lookup, for them only.

- **For:** works the same on every Mac. No PATH, version manager or Homebrew
  questions. Nothing for a new user to install except signing in.
- **Against:** a 124 MB download on first launch. Two copies of Claude Code on
  most Macs, both using `~/.claude` (see §7). New download, update and
  rollback code to maintain.

## 4. Anthropic's terms

From Anthropic's [Claude Code legal and compliance
page](https://code.claude.com/docs/en/legal-and-compliance), read 2026-11-22:

> Unless we've mutually agreed otherwise, preinstalling or running Claude
> Code in your products or services (e.g. in hosted sandboxes or other agent
> infrastructure) requires agreeing to our Commercial Terms of Service and
> complying with the conditions below:

1. **"The Claude Code binary must not be modified."** It must be "installed
   and run as published by Anthropic", and no sign-in method may be removed,
   disabled or restricted.
2. **"Customers may not pay for, resell, or intermediate Claude usage on
   their end users' behalf."** Each user authenticates with their own API key,
   subscription or cloud-provider credentials and is billed directly.

What that means for Toasty:

- Option C meets both conditions: the official build, unchanged, and each user
  signs in to their own account.
- "Preinstalling **or running**": Toasty already runs Claude Code, so this
  section arguably applies today, whether or not Toasty manages the copy.
- The developer needs to accept the Commercial Terms (for example through a
  Claude Console account). Users stay on their own terms.
- Toasty may say in plain text that it runs Claude Code. It may not use the
  Claude Code or Anthropic names or logos in a way that suggests Anthropic
  built, endorses or partners with it.
- **Sign-in must stay Anthropic's own flow.** The page says developers "may
  not collect, store, or intermediate Claude.ai credentials or session
  tokens". Toasty runs `claude auth login` and reads `claude auth status`, and
  never handles tokens. Keep it that way.

The same page says developers building on the Agent SDK "should use API key
authentication" and that third parties may not route requests through users'
plan credentials. It also says this doesn't prevent "an end user from signing
in to the unmodified Claude Code binary with their own Claude subscription".
**On 2026-11-22 Toasty's lawyers reviewed this and said signing in with the
user's own subscription shouldn't be a problem.**

## 5. Recommendation

1. **Keep option A's fixes** (released in a83e9a818) until option C ships.
   They help today's users whatever happens next.
2. **Build option C**, with conversations always on Toasty's own copy and the
   user's own `claude` available under Advanced in Settings.
3. **Do it together with replacing Node** (§6), so the setup check ends up as
   one step, signing in, instead of shrinking in two rounds.

Resulting requirements for users: **macOS 26 and a Claude account.**

Terminal tabs are unaffected. They run the user's shell, and typing `claude`
there runs the user's own copy, as it does today.

## 6. Relation to `NO_NODE.md`: replace Node in the same overhaul

[`NO_NODE.md`](NO_NODE.md) proposes removing Node: Swift talks to `claude`
directly, and fork runs the SDK's own `forkSession` outside Node.
[`NO_NODE_REVIEW.md`](NO_NODE_REVIEW.md) (2026-11-10) concluded **keep Node
for now**, and listed when to revisit. Its first trigger was "Toasty is
distributed to people who don't have Node." That's now happening.

**When we do this overhaul, we will likely try to replace Node** rather than
bundle or download it. The two changes fit together:

- Option C removes the need to find the user's `claude`. Replacing Node
  removes the need to find the user's `node`. With both, `ClaudeEnvironment`
  no longer looks for tools at all, only the user's environment variables.
- Pinning the Claude Code version (option C) makes the no-Node path safer.
  The review's main worry was hand-written protocol code drifting from each
  new `claude` release. With Toasty choosing the version, a release can be
  tested against the new path before any user gets it.
- `ClaudeSDK`'s download, checksum and self-test code is the model for
  downloading Claude Code, and per the review it stays anyway, as the
  reference for fork.

The shape to start from is "If we remove Node later" in `NO_NODE_REVIEW.md`:
Swift speaks the protocol, and fork runs the SDK's `forkSession` in a helper
process.

If replacing Node turns out to be too much for one round, the fallback is to
download a pinned Node the same way as Claude Code. That keeps the setup down
to signing in, at the cost of another background download.

## 7. To verify before building

- **Shared sign-in.** Claude Code keeps its credentials in a Keychain item
  named `Claude Code-credentials` (**V**: present on the development Mac).
  Does a second copy of the binary, in a different folder, read the same item
  without a Keychain prompt? (**I**: likely, if Claude Code reads it through
  `/usr/bin/security`, but untested.) And after `claude auth login` in
  Toasty's copy, is the user's terminal copy signed in too?
- **Two versions sharing `~/.claude`.** Settings, sessions, plugins and
  history live there. What happens when Toasty's copy is newer or older than
  the user's, for example a session written by one and resumed by the other?
- **Where the copy lives**, probably
  `~/Library/Application Support/Toasty/claude/<version>/`, and how many old
  versions to keep for rollback.
- **Channel.** Follow `latest` or `stable`, and how far behind Toasty's tested
  version it may run.
- **Updates and rollback.** Download in the background, verify the checksum,
  run a self-test, switch only new tabs, and fall back to the previous version
  if the new one dies before Claude Code says anything (the rule `ClaudeSDK`
  already uses).
- **First launch.** A 124 MB download before the first conversation. It needs
  a progress indicator, resuming after an interrupted download, and a clear
  message when the download fails, offline or in a region where
  `downloads.claude.ai` isn't available (the installer warns about this).
- **Code signing and quarantine.** Whether a binary Toasty downloads runs
  without Gatekeeper prompts, and whether Toasty's sandbox or hardened-runtime
  settings allow launching it.
- **Commercial Terms.** Accept them before shipping, per §4.
- **The sheet's npm failure** in §1. Probably moot once Toasty downloads
  Claude Code itself, but worth noting if it shows up again.

## 8. Files

- `Toasty/Claude/ClaudeAgent.swift`: `ClaudeEnvironment`, the login-shell
  lookup.
- `Toasty/Claude/ClaudeSetup.swift`: the setup check and its sheet.
- `Toasty/Claude/ClaudeSDK.swift`: the SDK download and matching, the model
  for downloading Claude Code.
- `Toasty/Resources/Bridge/toasty-agent.mjs`: the Node bridge.
- [`NO_NODE.md`](NO_NODE.md), [`NO_NODE_REVIEW.md`](NO_NODE_REVIEW.md): the
  Node removal work.
