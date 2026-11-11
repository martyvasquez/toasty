# No-Node proofs of concept

These are the source files and raw results behind [`../NO_NODE.md`](../NO_NODE.md).
None of this is part of the app build: there is no Xcode target and nothing
here is referenced by `project.yml`. Every test ran outside the app.

## Layout

```
0-protocol-capture/        What the real Node SDK sends to `claude` (captured with a logging wrapper)
  sdk-claude-argv.txt        the arguments the SDK starts `claude` with
  sdk-added-env.txt          environment variables the SDK adds (clean run, Claude session vars stripped)
  sdk-to-claude-stdin.jsonl  every line the SDK wrote to claude's stdin in a short session
                             (claude's stdout is not included: it holds account and session data)

1-direct-protocol/         POC 1: Swift talks to `claude` directly, no Node, no SDK
  poc.swift                  initialize, set_model, set_permission_mode, permission round trip,
                             streaming, get_context_usage, interrupt, --resume
  poc2.swift                 image attachment, background task + stop_task, Remote Control on/off,
                             the full SDK env var set
  results-poc1-run1.txt      raw output, first run
  results-poc1-resume.txt    raw output, resume in a new process, plus startup timing vs Node
  results-poc2.txt           raw output, poc2

2-jsc-fork/                POC 2: the SDK's own forkSession running in JavaScriptCore
  prelude.js                 the Node stand-ins ("fake Node")
  jscfork.swift              the Swift host: loads + rewrites the SDK, backs fs/crypto/utf8/timers,
                             refuses writes outside TOASTY_WRITE_ROOT
  run-node.mjs               the baseline: same forks through real Node + the SDK
  compare.py                 parity check (normalizes only newly created UUIDs and timestamps)
  cases.json                 the 10 fork points (session id, project dir, upToMessageId); not in the repo
  results-node.json          Node: new session id + time per case
  results-jsc.json           JavaScriptCore: new session id + time per case
  results-compare.txt        parity output: 10/10 IDENTICAL
  results-fork-files.txt     what each fork file contains (line counts, forkedFrom, compactions, record types)

3-review/                  Independent review, written up in ../NO_NODE_REVIEW.md
  cases.json                 261 fork cases across 5 sessions; not in the repo
  run-node.mjs               Node baseline that passes each case's options through
  probe.py                   no-token protocol probe against a scratch config

results-cli-fork.txt       Option B: `claude --fork-session --resume-session-at` test
results-bun-attempt.txt    Attempt to run JS through the claude binary's embedded Bun (doesn't work)
```

The session transcripts used for the fork tests are the user's private
conversations and are **not** included, and neither are the `cases.json`
files that list them (gitignored). To rerun the fork test, use any sessions
from your own `~/.claude/projects` and write your own `cases.json` (see
below).

## Running

All runs below use a scratch directory. None of them write to `~/.claude`.

### POC 1 (direct protocol)

Needs `claude` at `~/.local/bin/claude`, logged in. It makes real, cheap
model calls (Haiku), around $0.01 per run.

```sh
mkdir -p /tmp/nn/proj && cd /tmp/nn
swiftc -swift-version 5 -O path/to/poc.swift -o poc
./poc /tmp/nn/proj                 # prints SESSION <id> at the end
./poc /tmp/nn/proj <id>            # resume test

# poc2 reads blue.b64 (a base64 PNG) from the current directory.
python3 -c "import zlib,struct,base64
w=h=64; raw=b''.join(b'\0'+bytes([30,90,230])*w for _ in range(h))
ch=lambda t,d: struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
open('blue.b64','w').write(base64.b64encode(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw))+ch(b'IEND',b'')).decode())"
swiftc -swift-version 5 -O path/to/poc2.swift -o poc2 && ./poc2 /tmp/nn/proj
```

Note: `poc2` turns Remote Control on for a few seconds, then off.

### POC 2 (JavaScriptCore fork parity)

```sh
J=/tmp/nn/jsc; mkdir -p $J/base/projects && cd $J
# 1. Copy some sessions into the sandbox, keeping the project folder names:
#      $J/base/projects/<project-key>/<session>.jsonl
# 2. Write cases.json: [{name, sessionId, dir (the project's real path), upToMessageId}]
# 3. Baseline with Node:
cp -R base run-node; mkdir home-node
env -i PATH=/usr/bin:/bin HOME=$J/home-node CLAUDE_CONFIG_DIR=$J/run-node \
  node run-node.mjs <repo>/Toasty/Resources/Bridge/claude-agent-sdk.mjs cases.json > node-result.json
# 4. The same forks in JavaScriptCore (writes allowed only under $J):
swiftc -swift-version 5 -O jscfork.swift -o jscfork
cp -R base run-jsc; mkdir home-jsc
env -i PATH=/usr/bin:/bin HOME=$J/home-jsc CLAUDE_CONFIG_DIR=$J/run-jsc TOASTY_WRITE_ROOT=$J \
  ./jscfork <repo>/Toasty/Resources/Bridge/claude-agent-sdk.mjs prelude.js cases.json \
  | sed '/^SDK loaded/d' > jsc-result.json
# 5. Compare:
python3 -I compare.py $J
```

`compare.py` expects `node-result.json`, `jsc-result.json`, `cases.json`,
`base/`, `run-node/` and `run-jsc/` under the directory you pass it.

## Known limitations of the POC code

These are throwaway programs, not production code:
- force-unwraps everywhere and hard-coded paths (`~/.local/bin/claude`);
- `poc.swift` is not thread-safe around its pending-request table beyond a
  lock;
- the fake Node in `prelude.js` covers exactly what `forkSession` needs in
  SDK 0.3.319 and nothing more;
- `fs.open` is read-only, `createWriteStream` buffers in memory, and stubs
  throw when called.
