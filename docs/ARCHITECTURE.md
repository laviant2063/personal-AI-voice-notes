# Architecture and invariants

## Components

| Layer | Component | Responsibility |
|---|---|---|
| UI | NotesListView, RecorderSheet, NoteDetailView, SettingsView | User actions and disclosure |
| Coordination | RecorderViewModel, AIController | Recording/STT and one logical AI operation |
| Services | WhisperEngine, AISummaryService, BackendAPIClient | Local C inference and backend transport |
| Storage | NoteStore, AppFolders, Keychain | Atomic metadata, app-owned files, APP_TOKEN |
| Backend | Cloudflare Worker | Authentication, validation, cost controls, Responses API |

## Data invariants

1. Note ID and app-owned WAV URL are persisted before microphone capture.
2. rawTranscript is captured once and cannot be edited or regenerated over.
3. User edits change only editedTranscript and increment transcriptRevision.
4. AI uses the immutable edited-text snapshot in AIRequestContext.
5. Request token, response revision, and current note revision must all match.
6. Starting regeneration clears none of the prior generated fields.
7. Only complete validated success replaces generated fields atomically.
8. Loading, editing, relaunching, and reconnecting are not upload events.
9. Only a newly persisted local STT result may invoke opt-in automatic AI.
10. Local notes never depend on AI success.

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
