# Dictation

Hold a key, speak, and the text appears in Claude's message box, written the
way a developer would type it. Everything runs on your Mac: no account, no
network, no audio ever leaves the machine.

- [Using it](#using-it)
- [What you can say](#what-you-can-say)
- [Vocabulary](#vocabulary)
- [How it works](#how-it-works)
- [Setup (building from a clone)](#setup-building-from-a-clone)
- [Tuning](#tuning)
- [Troubleshooting](#troubleshooting)
- [Testing and debugging](#testing-and-debugging)
- [Decisions and their reasons](#decisions-and-their-reasons)
- [Limits and ideas](#limits-and-ideas)

## Using it

With Toasty in front:

| To | Do |
|---|---|
| Dictate | Hold **Right Option**, speak, release. |
| Dictate hands-free | **Double-tap** Right Option; press it once more to finish. |
| Cancel | **Esc** or **⌘.** while listening. |
| Use the mouse | Click the **mic button** next to Send to start; click again to finish. |
| Get the last text back | Edit ▸ Dictation ▸ **Insert Last Dictation** / **Copy Last Dictation**. |
| Edit your vocabulary | Toasty ▸ **Settings…** (⌘,) ▸ Dictation, or Edit ▸ Dictation ▸ Vocabulary…. |

- Text goes in at the cursor of the message box, joined to what's already
  there (a space where one belongs, a capital after a full stop).
  Dictation **never sends**: it never presses Return.
- If the cursor is somewhere else (the terminal, the sidebar), the text goes
  to the visible conversation's message box, and the cursor moves there.
- Nothing happens for a tap shorter than 0.3 s, or when you use Right
  Option as a modifier (any other key while holding it). The key still
  types as usual.
- The mic button doubles as the indicator: blue with a halo that follows
  your voice while listening, a small spinner while transcribing, a
  warning sign for a moment if something failed.
- Sounds: a soft rising pair when listening starts, a falling pair when it
  stops, a low pair on failure, and a light tick if text arrives more than
  2 s after you stopped.
- VoiceOver announces "Listening", "Transcribing" and "Dictation failed".
- The first time you dictate, macOS asks for microphone access.

**The microphone** opens when you press (macOS shows its orange indicator)
and stays open for 15 s after a dictation, so a follow-up starts
instantly. It closes as soon as Toasty isn't the active app. Because a
closed mic takes about 0.12 s to start, the very start of a word can be
lost if you speak the instant you press after a pause; within the 15 s,
Toasty keeps the 0.45 s before your press, so nothing is lost.

## What you can say

Words and phrases below are matched as whole words, any capitalization.

**Line breaks and quotes**

| Say | Get |
|---|---|
| new line, line break | a line break |
| new paragraph | a blank line |
| open quote … close quote | `"…"` |
| quote … unquote | `"…"` (needs at least one word between) |

**Symbols**

| Say | Get | Example |
|---|---|---|
| underscore | `_` | user underscore id → `user_id` |
| dot | `.` | main dot swift → `main.swift` |
| slash | `/` | src slash models → `src/models` |
| backslash | `\` | C colon backslash temp → `C:\temp` |
| hyphen | `-` | well hyphen known → `well-known` |
| dash dash | `--` | dash dash verbose → `--verbose` |
| tilde | `~` | tilde slash Development → `~/Development` |
| hashtag, hash sign | `#` | hashtag release → `#release` |
| at sign | `@` | at sign home → `@home` |
| comma, colon, semicolon | `,` `:` `;` | the list colon apples → `the list: apples` |
| equals sign | ` = ` | x equals sign five → `x = five` |
| pipe symbol, pipe sign | ` \| ` | log pipe symbol grep → `log \| grep` |
| open/close paren | `(` `)` | foo open paren close paren → `foo()` |
| open/close bracket | `[` `]` | |
| open/close brace | `{` `}` | |

- An empty bracket pair attaches to the word before it (`foo()`); with words
  inside it's spaced like prose (`note (see docs)`).
- "dots", "dotted", "commas" and the like are left alone. Plain "pipe" is too
  ("pipe the output to grep" is ordinary speech); say "pipe symbol".
- **Paths become real paths.** In a git repo, a spoken path is matched to
  the repo's actual files and folders: "source slash temp" → `src/tmp`,
  "source slash model slash user dot rs" → `src/models/user.rs`,
  "project dot yaml" → `project.yml`. Each part may differ in case, by a
  common abbreviation (source/src, temp/tmp, library/lib,
  documentation/docs, configuration/config…), by singular/plural, or by
  one letter in longer names. The extension must match (yaml/yml and
  jpeg/jpg count as the same). The path is only rewritten when exactly one
  real spelling fits best; otherwise it stays as you said it.

**Removed:** the fillers um, umm, uh, uhh, erm, er, ah (whole words only,
so "umbrella", "ER" and "uh-huh" stay).

## Vocabulary

The speech engine writes common English well, but names like `MicCapture`,
Supabase or `Context7` need help. Toasty uses four layers, in this order
(earlier wins):

1. **This project's vocabulary**: yours, in
   `<project>/.toasty/vocabulary.txt`. Commit it to share it with a team,
   or add `.toasty/` to `.gitignore` to keep it personal.
2. **Your vocabulary everywhere**: in
   `~/Library/Application Support/Toasty/vocabulary.txt` (`Toasty Debug/`
   for the Debug build).
3. **What Toasty picks up from your work**, rebuilt on every dictation
   while you speak and never written anywhere:
   - code names in the current conversation, newest first;
   - files you're changing (git status) and files in the last 30 commits;
   - names the project declares (`project.yml`, `Package.swift`,
     `package.json`, `Cargo.toml`).
4. **Built-in developer vocabulary** (`DevVocabulary.swift`), about 140 names:
   - a few always offered to the engine (Claude Code, Claude Agent SDK,
     GitHub, TypeScript, JavaScript, MCP server);
   - tools offered only when the repo uses them (Supabase when there's a
     Supabase dependency or folder, Prisma, Next.js, XcodeGen, Docker
     Compose…);
   - capitals and known mishearings for everything (superbase → Supabase,
     type script → TypeScript, clawed code → Claude Code, context 7 →
     Context7, json → JSON, macos → macOS).

Edit layers 1 and 2 in **Settings ▸ Dictation** (they're saved straight to
those files, so editing by hand works too; changes apply on the next
dictation). Settings also lists what layers 3 and 4 contain for the current
project.

**Entry types** (the file format; Settings writes the same lines):

```
Claude Code                         a term
libghostty = lib ghostty            a term plus how it may be heard
nimblest -> Nimbalyst               a replacement (always applied to the text)
Codex!                              "!" also fixes the capitals of an ordinary word
# a comment
```

- **Terms** make the speech engine favour that name when the audio fits
  (it checks the sound, so it doesn't fire on unrelated words). They also
  fix capitals in the text: `pty` → `PTY`. For an ordinary English word
  (Codex, Node), capitals are only fixed if you mark it with `!`.
- **Replacements** rewrite the text after transcription, whole words only.
  The words may also appear run together or hyphenated ("CloudCode",
  "cloud-code"). Use them for names the engine can't produce at all
  ("nimblest -> Nimbalyst"). An empty right-hand side deletes the phrase.
- **Prefer longer names.** A single ordinary word as a term can turn
  speech into the name ("cloud" → "Claude"). Settings marks such entries
  with ⚠. "Claude Code" is safe; "Claude" alone isn't.
- At most **64 terms** reach the engine per dictation (its limit), filled
  in the layer order above. Replacements and capital fixes have no limit.

## How it works

```
Right Option ──► TriggerMonitor ──► DictationController ──► MicCapture (mic, 10 s buffer)
                 (key events)       (state, jobs, order)          │
                                                                  ▼
                       composer ◄── TextPipeline ◄── SpeechEngine ◄── CaptureClip
                       (insert)     (symbols, paths,  (Parakeet on    (frame, resample,
                                     vocabulary)       Metal)          silence/VAD gates)
```

1. **Press.** `TriggerMonitor` (a local key monitor: Toasty's own events
   only, no Accessibility permission) feeds `TriggerStateMachine`, which
   decides hold / double-tap lock / chord / cancel from the key events'
   own timestamps. The controller picks the target composer, schedules the
   start tone, and starts gathering the context vocabulary in the
   background.
2. **Capture.** `MicCapture` runs an `AVAudioEngine` input tap at the
   device's own rate, with no voice processing, mixed to mono. Each buffer
   is placed on a 10 s `CaptureTimeline` by its capture time (the same
   clock as key events). The recording starts 0.45 s before the press
   (pre-roll) and ends 0.2 s after the release (tail). Gaps of 50–250 ms are
   filled with silence; longer ones fail the dictation. A Bluetooth
   default input is skipped for the built-in or a wired mic.
3. **Gates.** `CaptureClip` resamples to 16 kHz and drops silent clips
   (loudest 30 ms below −50 dBFS) and clips the Silero speech detector finds
   no speech in, so the model never "hears" a "Thank you." in a quiet room.
4. **Transcribe.** `SpeechEngine` runs Parakeet TDT 0.6B v2 on Metal through
   transcribe.cpp, on its own thread, with that dictation's vocabulary
   (up to 64 terms, rescoring boost 2.5). Short clips are padded to 1.5 s.
   The model is loaded and warmed up at launch.
5. **Text.** `TextPipeline`: spoken formatting → symbols → fillers → repo
   paths (`RepoPaths`) → replacements → capitals (`Vocabulary`) → joining
   at the caret.
6. **Insert.** One undoable edit at the caret. Several dictations can be
   in flight; they're always inserted in the order you made them.

**Files** (`Toasty/Dictation/`):

| File | Does |
|---|---|
| `DictationConfig.swift` | Every tunable constant, with where it came from |
| `TriggerMonitor.swift` | Key events → hold / lock / chord / cancel |
| `DictationController.swift` | The flow above, ordering, Edit ▸ Dictation menu |
| `MicCapture.swift` | Microphone, device choice, open/close, stalls |
| `CaptureClip.swift` | Timeline, framing, resampling, silence gates |
| `SpeechEngine.swift` | The only file that talks to transcribe.cpp |
| `SpeechModels.swift` | Finds the bundled models |
| `TextPipeline.swift` | Formatting, symbols, fillers, replacements, joining |
| `RepoPaths.swift` | Spoken paths → real repo paths |
| `Vocabulary.swift` | Vocabulary files, parsing, layering, capitals |
| `ContextVocabulary.swift` | Names from the conversation, git and project files |
| `DevVocabulary.swift` | The built-in developer vocabulary |
| `DictationIndicator.swift` | The mic button / indicator |
| `DictationTones.swift` | The sounds (synthesized, nothing bundled) |
| `DictationSettings.swift` | Settings ▸ Dictation |

**Speed** (M1 Max): about 0.1 s to transcribe a 7 s clip (0.2 s with
vocabulary), so text lands about 0.3–0.4 s after release; most of that is
the deliberate 0.2 s tail. Idle CPU about 0.3%. The 730 MB model is
memory-mapped: its pages are clean and macOS can reclaim them; a dictation
adds no lasting memory.

## Setup (building from a clone)

The engine and models are not in git (they're large); scripts fetch them at
pinned versions:

```sh
scripts/build-transcribe.sh      # builds Vendor/CTranscribe.xcframework
scripts/fetch-speech-models.sh   # downloads the models, checks size + sha256
xcodegen generate
```

`scripts/release.sh` runs both when they're missing.

| Component | Version |
|---|---|
| transcribe.cpp (Hex's fork) | `2778ae4bf5ca5f394d129a39467f4ad9552dc34f`, cloned privately to `~/Library/Caches/Toasty/transcribe.cpp` |
| Parakeet TDT 0.6B v2, Q8_0 GGUF | `handy-computer/parakeet-tdt-0.6b-v2-gguf` @ `07cee061…`, 729,574,912 bytes, sha256 `f0d0e99c…` |
| Silero VAD v6.2, F32 GGUF | `handy-computer/silero-vad-v6.2-gguf` @ `a9b2d61c…`, 1,241,056 bytes, sha256 `0d871a80…` |

The models go in `Toasty/Resources/SpeechModels/` and ship inside the app
(about +730 MB). Toasty never downloads anything at runtime. The framework is
dynamic and is embedded and signed. The app needs
`NSMicrophoneUsageDescription` and the `com.apple.security.device.audio-input`
entitlement (both in `project.yml`). Requires Apple silicon (Metal); on
other Macs a dictation fails with a message saying so.

## Tuning

All constants are in `DictationConfig.swift`. The ones you're most likely to
want:

| Constant | Default | Effect |
|---|---|---|
| `triggerKeyCode` | 61 (Right Option) | The dictation key |
| `keepMicWarmWhileActive` | `false` | `true`: mic open whenever Toasty is active (orange indicator always on, no lost start) |
| `micLinger` | 15 s | How long the mic stays open after a dictation |
| `releaseTail` | 0.2 s | Audio kept after release (shorter = faster, but may clip your last word) |
| `preRoll` | 0.45 s | Audio kept before the press when the mic is open |
| `minimumHold` | 0.3 s | Shorter taps are ignored |
| `doubleTapWindow` | 0.3 s | Second tap within this locks |
| `playTones` | `true` | All dictation sounds on/off |
| `vocabularyBoost` | 2.5 | How strongly the engine favours terms (Hex measured 4.0 as too strong) |
| `silenceThresholdDBFS` | −50 | Quieter clips are dropped as silence |

## Troubleshooting

- **Nothing happens on Right Option.** Toasty must be the active app, and a
  Claude conversation must be visible (dictation types into the message box
  only). Check that you aren't holding another modifier.
- **The warning sign shows "Microphone access is off".** Turn on Toasty in
  System Settings ▸ Privacy & Security ▸ Microphone.
- **My AirPods aren't used.** On purpose: opening a Bluetooth mic switches
  the headset to low-quality call audio for everything. Toasty uses the
  built-in or a wired mic, and the Bluetooth one only if nothing else exists.
- **The first word is cut off.** The mic was closed (more than 15 s since
  the last dictation, or Toasty was in the background). Start speaking a
  beat after pressing, or set `keepMicWarmWhileActive`.
- **A name keeps coming out wrong.** Add it as a term in Settings ▸
  Dictation. If it still doesn't come out (a made-up word the engine can't
  spell), add a replacement from what it writes instead.
- **Something I said became a name.** A term is too close to an ordinary
  word. Use a longer form, or remove it.
- **What did it hear?** In the Debug build, `dictationState` shows the last
  raw and final text; `dictationDumpLastClip` saves the last recording as a
  WAV.

## Testing and debugging

- **Unit tests:** `xcodebuild -project Toasty.xcodeproj -scheme Toasty
  -derivedDataPath build test`. 104 Swift Testing tests in
  `Tests/DictationTests/`, hosted in the Debug app (which starts nothing
  else under tests). They include every Hex text-processing case, the
  trigger timing edges (299/300 ms), framing, gates, device choice,
  vocabulary layering and the engine itself on synthetic `say` fixtures
  (`Tests/Fixtures/`, never a person's recording).
- **Debug commands** (Debug build, over the control channel):
  `dictationState`, `dictationTranscribeFile {path, project?, vocabulary?}`,
  `dictationSimulate {path, press, release, gapAt?, gapMs?}` (a file
  through the capture path), `dictationSimulateKeys {path, press, release,
  lock?}` (end to end into the composer), `dictationPress` /
  `dictationRelease` (live mic), `dictationVocabulary {project?}` (the
  engine list with each term's source), `dictationDumpLastClip {path}`,
  `dictationIndicator {phase}` (for screenshots).
- **Accuracy:** recorded clips with their true text can be scored by
  transcribing each with `dictationTranscribeFile` and comparing. On the
  author's 16 dev-prompt recordings, word errors went from 15.2% with plain
  transcription to 8.3% with Toasty's built-in and project vocabulary, with
  no words changed in the plain-English and "trap" sentences (cloud bill,
  hex colors).

## Decisions and their reasons

| Decision | Why |
|---|---|
| Parakeet TDT 0.6B v2 via transcribe.cpp (Hex's fork) | The fully local option with acoustic vocabulary rescoring; MIT engine; CC BY 4.0 model that can be bundled. Apple's speech framework was rejected on quality and because it downloads models. |
| Models bundled, fetched at build time with pinned hashes | Self-contained: no network at runtime, ever. |
| Right Option, hold + double-tap | Left Option is used constantly in a terminal app; Fn is taken by macOS. |
| Only inside Toasty, into the message box | No Accessibility permission, no clipboard tricks; the terminal isn't a target. |
| Never presses Return | Dictated text is reviewed before it's sent. |
| Mic on demand, 15 s linger | An always-on orange indicator was unwelcome; the linger keeps follow-ups instant. |
| Esc cancels (and is swallowed) | Hex ignores Esc; here a reflex Esc while dictating shouldn't also interrupt Claude. |
| Silence + speech-detector gates | Models invent "Thank you." on silence and noise. |
| Vocabulary in layers, built-in list tiered | 64 engine slots per dictation: give them to what's relevant; a single ordinary word never reaches the engine. |
| No persistent history | Privacy; Insert/Copy Last Dictation covers lost text. |
| One Settings window for the vocabulary | Toasty otherwise has no settings; added at the user's request. |
| Port Hex's behaviour, not its code | Toasty is Swift; Hex's constants and tests are the spec. |

Credits and licences: `Toasty/Resources/Acknowledgements.txt` (shown from
the About panel).

## Limits and ideas

- English only. No live text while speaking (the model can't stream).
- Names that are ordinary words (Toasty, Node, Portal) stay lowercase unless
  you add them with `!`.
- Numbers in names ("Swift Six") aren't turned into digits yet.
- Path matching scans the whole file list per dictation; fine for normal
  repos, possibly slow for very large monorepos.
- More in `TODO.md` › Dictation.
