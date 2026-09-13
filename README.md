# Personal AI Voice Notes

A personal iPhone/iPad voice-note app based on [WalkWrite](https://github.com/lbacaj/WalkWrite-opensource). It records audio locally, transcribes with an installed multilingual whisper.cpp model, lets you edit and search transcripts, and optionally sends the edited text to your own Cloudflare Worker for one structured AI result.

> Development status: the source and backend mock path are implemented. GitHub Actions Run #1 compiled and linked an unsigned arm64 device Release archive with Xcode 16.4. Simulator tests, signed installation, and physical-device validation have **not** been performed yet.

## Architecture

```text
                    one AVAudioEngine microphone tap
                         ↙                     ↘
           app-owned WAV                 on-device Apple Speech
                 ↓                        live draft (optional)
        durable Note metadata                    ↓
                 ↓                          local checkpoint
       bounded 16 kHz mono conversion
                 ↓
       installed whisper.cpp GGML model
                                  ↓
                raw transcript + segments (immutable)
                                  ↓
                    edited transcript + revision
                                  ↓ explicit request or opt-in event
SwiftUI → AIController → AISummaryService → BackendAPIClient
                                  ↓ HTTPS + APP_TOKEN
Cloudflare Worker → OpenAI Responses API + strict JSON Schema
                                  ↓
       title + summary + key points + action items
                                  ↓ revision/request-token guard
                     atomic local JSON persistence
```

The iOS client never receives or stores `OPENAI_API_KEY`. The Worker has no note database and does not permanently store transcripts.

## What works offline

- Recording, Pause, Resume, Stop, WAV storage, and playback
- Best-effort live text when the selected language supports Apple on-device recognition
- Installed-model whisper.cpp transcription
- Raw/edited transcript storage and editing
- Note persistence, deletion, action-item completion, lexical search
- Search over AI title, edited transcript, summary, and key points
- Opening notes after relaunch

First-time model provisioning may require internet. After a multilingual GGML model is imported, final transcription uses the local whisper.cpp runtime. Live text is provisional and requires Speech Recognition permission plus an on-device recognizer/language asset; the app never falls back to network Speech. If live text is unavailable, audio recording and final local Whisper continue.

Online-only functionality is limited to AI title, summary, key points, and action items. There is no cloud STT, account, payment, analytics, cloud note sync, semantic search, speaker diarization, translation pipeline, or local LLM.

## Safety behavior

- Note metadata is written before microphone capture starts. Stop finalizes it before STT.
- The same microphone buffer feeds WAV storage and optional live text; only successfully written audio is offered to live recognition.
- Live partial text is stored separately from raw/edited transcripts and cannot trigger AI processing.
- Audio remains available when STT, networking, backend, or AI fails.
- A corrupt note index becomes read-only; it is never silently replaced by an empty list.
- Atomic writes keep the previous readable index as `notes.backup.json`.
- Raw STT is captured once. Editing changes only `editedTranscript` and increments its revision.
- An AI response must match the active request token and transcript revision.
- Regeneration replaces old AI fields only after the entire new result validates.
- Turning AI on does not upload past notes. Network reconnection has no upload callback.
- Automatic AI Summary is OFF by default and applies only after a new local transcription is durably saved.
- APP_TOKEN is stored in Keychain and is scoped to the configured HTTPS origin.

See [Architecture and invariants](docs/ARCHITECTURE.md).

## Requirements

- macOS with Xcode 16.3+ and command-line tools
- iOS/iPadOS 17.6+
- CMake
- Git submodules
- A physical iPhone/iPad for final microphone, interruption, memory, and Whisper testing
- Node.js 24+ for backend work

The included framework/model LFS placeholders are not runtime assets. The app excludes them and reports a missing model instead of crashing.

## Xcode setup

```bash
git submodule update --init --depth 1 -- whisper.cpp
./build-whisper-xcframework.sh
cp Config.xcconfig.template Config.xcconfig
open WalkWrite.xcodeproj
```

Edit the ignored `Config.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PRODUCT_BUNDLE_IDENTIFIER_PREFIX = com.yourname
```

Then build the `WalkWrite` scheme. The generated XCFramework is placed under the ignored `.build/whisper/` directory and is never overwritten by the script.

Recommended verification commands on macOS:

```bash
swift test
xcodebuild -project WalkWrite.xcodeproj -scheme WalkWrite \
  -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

A simulator does not validate microphone routing, background/interruption behavior, Neural Engine/Metal memory pressure, or real-device performance.

The repository also includes **.github/workflows/ios-validation.yml**. It
performs the pinned framework build, portable core tests, simulator app build,
and iOS unit tests on a macOS runner. It has not been run from this uncommitted
local checkout.

### GitHub unsigned IPA artifact

After these changes are committed to a writable GitHub repository:

1. Open **Actions → Build unsigned IPA → Run workflow**.
2. Enter a bundle identifier prefix such as **com.yourname.personal**.
3. Download **PersonalVoiceNotes-unsigned.ipa** from the completed run.

The workflow builds an arm64 device Release archive, verifies that it is
unsigned, packages a standard Payload directory, validates the ZIP structure,
records its SHA-256 in the job summary, and uploads the IPA directly for 14
days. An unsigned IPA cannot be installed directly on an iPhone; re-sign it
with AltStore, Sideloadly, or your own Apple certificate/profile. This workflow
does not verify installation, microphone behavior, or Whisper performance.

## Whisper model installation

1. Download a multilingual GGML `.bin` model from the official [whisper.cpp model repository](https://huggingface.co/ggerganov/whisper.cpp).
2. Save it in Files on the device.
3. Open **Settings → Local Speech-to-Text → Import Whisper Model**.
4. Confirm **STT Model Status: Installed**.
5. Record a short sample in Korean, English, Japanese, and Spanish.

The importer copies into the app container without replacing an existing good model. It rejects Git LFS pointers, truncated headers, and English-only model headers. Header validation is not an inference, quality, or memory test. A smaller multilingual model is the safer first device test.

## Language policy

Final local Whisper supports Auto Detect, Korean, English, Japanese, and Spanish selections. Live Speech uses Korean (`ko-KR`), English (`en-US`), Japanese (`ja-JP`), Spanish (`es-ES`), or the device's preferred language for Auto Detect. Availability depends on Apple on-device language support. AI output is instructed to follow the transcript's primary language and preserve useful mixed-language terminology. No separate translation pipeline exists. No language-quality test was performed in this Windows environment.

## Backend

The personal backend lives in [backend](backend/README.md) and exposes:

- `GET /api/status`: authenticated configuration readiness; no transcript and no OpenAI call
- `POST /api/summarize`: one logical operation returning title, summary, key points, and action items

Short transcripts make one OpenAI Responses API call. Inputs beyond the configured threshold are split chronologically, summarized in bounded chunks, and synthesized only when needed.

Required Worker secrets/environment:

- `OPENAI_API_KEY`
- `OPENAI_MODEL`
- `APP_TOKEN`

No model name is hard-coded as the runtime default. Consult the current [OpenAI model catalog](https://developers.openai.com/api/docs/models) when configuring `OPENAI_MODEL`.

## Privacy

Audio never goes to the AI backend. Apple Speech requests are started only when the selected recognizer reports on-device support, and every request sets `requiresOnDeviceRecognition = true`; unsupported live recognition is disabled instead of using a network fallback. Only the saved edited Whisper transcript is sent to the personal AI backend, either after tapping **Generate AI Summary** or after enabling Automatic AI Summary and creating a new transcription.

The Worker sets `store: false`, logs only request ID/status/latency/input character count/model/error category, and never logs the transcript. OpenAI platform data controls and retention are separate from this app; review the current [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data) before use.

## Verification performed on Windows

```text
backend TypeScript typecheck: passed
backend Node mock tests: 18 passed
Cloudflare Worker dry-run bundle: passed
npm audit: 0 vulnerabilities
Swift tree-sitter syntax scan: 32 files, 0 syntax-error nodes
Xcode project OpenStep parse: passed
plist parse: passed
Whisper build script bash syntax: passed
IPA packaging script Bash parser: 0 syntax-error nodes
GitHub workflows actionlint: 2 passed
GitHub Xcode 16.4 unsigned device archive: passed
Downloaded IPA structure and SHA-256 verification: passed
Git diff whitespace check: passed
```

The local syntax scan is not compilation; GitHub Run #1 separately verified device Release compilation and linkage. See [Verification status](docs/VERIFICATION.md) for exact scope and remaining tests.

## Known limitations

- Device Release compilation/linkage passed on GitHub macOS; simulator and unit/UI tests remain unverified.
- Physical recording, live Speech partials, Speech language assets, interruptions, route changes, playback, model import, multilingual STT, long recordings, and memory use remain unverified.
- The Cloudflare rate-limit bindings are per location and eventually consistent, so also configure OpenAI project budgets/limits.
- The current recovery path preserves orphaned WAV audio but may not know its precise duration until playback opens it.
- There is no model downloader; import is a deliberate user action.

## License

WalkWrite is MIT licensed. The pinned whisper.cpp submodule is also MIT licensed. See [LICENSE](LICENSE) and [whisper.cpp/LICENSE](whisper.cpp/LICENSE).
