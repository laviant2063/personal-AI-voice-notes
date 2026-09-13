# Architecture and invariants

## Components

| Layer | Component | Responsibility |
|---|---|---|
| UI | NotesListView, RecorderSheet, NoteDetailView, SettingsView | User actions and disclosure |
| Coordination | RecorderViewModel, AIController | Recording/live draft/final STT and one logical AI operation |
| Services | AudioCaptureEngine, LiveSpeechRecognizer, WhisperEngine, AISummaryService, BackendAPIClient | Single microphone capture, optional on-device live text, local C inference, and backend transport |
| Storage | NoteStore, AppFolders, Keychain | Atomic metadata, app-owned files, APP_TOKEN |
| Backend | Cloudflare Worker | Authentication, validation, cost controls, Responses API |

## Data invariants

1. Note ID and app-owned WAV URL are persisted before microphone capture.
2. One AVAudioEngine input tap feeds authoritative WAV storage and optional live text; live Speech never owns a second microphone path.
3. Live Speech runs only when on-device recognition is supported and every request requires on-device processing.
4. liveTranscriptDraft is provisional, cannot become AI input, and never fires the automatic-AI callback.
5. rawTranscript is captured once and cannot be edited or regenerated over.
6. A nonempty final Whisper result replaces the live draft at revision zero. An empty result retains the draft only as a clearly marked fallback.
7. User edits change only editedTranscript and increment transcriptRevision.
8. AI uses the immutable edited-text snapshot in AIRequestContext.
9. Request token, response revision, and current note revision must all match.
10. Starting regeneration clears none of the prior generated fields.
11. Only complete validated success replaces generated fields atomically.
12. Loading, editing, relaunching, and reconnecting are not upload events.
13. Only a newly persisted local Whisper result may invoke opt-in automatic AI.
14. Local notes never depend on AI success.

## Stale response

~~~text
revision 3 snapshot → request token A
user saves revision 4
revision 3 response arrives
token A retired → response discarded → previous result retained
~~~

Cancellation retires the token immediately, so an uncooperative transport cannot save later.

## Failure boundaries

| Failure | Persistent state |
|---|---|
| Recorder setup/start | Explicit error; no success state |
| Interruption/route loss | Paused; no automatic resume |
| Live Speech denied/unsupported/fails | WAV continues; final local Whisper still runs |
| Live Speech task duration | Rotated while WAV capture continues; draft remains provisional |
| Termination | Incomplete note/audio recovered |
| Missing/bad Whisper model | Audio retained; STT retryable |
| STT cancellation/failure | Audio/existing text retained |
| Corrupt note index | Original retained; store read-only |
| Offline/cellular blocked | Waiting; no reconnect upload |
| HTTP/timeout/invalid AI | Note and prior AI result retained |

## Migration

Legacy transcript initializes raw and edited text at revision zero. Legacy LLM cleanup never becomes raw STT. Legacy summary/key ideas remain marked legacy-local-llm rather than new OpenAI results.

Legacy absolute URLs ending in an app Notes directory are remapped by safe filename. Delete removes only a direct, non-symlink audio child of the managed folder.

## Network and privacy

NWPathMonitor is UI/preflight information only. URLSession outcomes are authoritative. The ephemeral session uses no cookies/cache, refuses redirects, caps response bytes, and can forbid cellular/metered access.

The Worker uses separate Cloudflare buckets for logical requests and upstream OpenAI calls. For a long transcript, it computes the complete chunk/synthesis plan and reserves every upstream-call token before starting call one, so a budget failure cannot leave a partial AI result.

Keychain stores APP_TOKEN per HTTPS origin. The client rejects sk- values to reduce the chance of storing an OpenAI key. OPENAI_API_KEY is backend-only.
