# Personal Cloudflare Worker

This Worker accepts an edited transcript, calls the OpenAI Responses API, and returns one structured result. It has no database, transcript cache, demo mode, or production mock path.

## Local checks without credentials

~~~bash
npm ci
npm run typecheck
npm test
npm run build
~~~

Tests inject outbound fetch and globally block accidental external fetches. No real OpenAI request is made.

## Configuration

Set all three values directly in your own Cloudflare Worker:

~~~bash
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put OPENAI_MODEL
npx wrangler secret put APP_TOKEN
~~~

- Choose OPENAI_MODEL from the current [OpenAI model catalog](https://developers.openai.com/api/docs/models). It must support Responses and Structured Outputs.
- Use a high-entropy APP_TOKEN of 32–512 supported characters. This provides basic endpoint protection, not strong identity.
- The committed rate-limit namespace IDs were generated independently for this personal Worker. Generate new distinct positive IDs if this config is reused in another Cloudflare account.
- The config declares all three secret names as required, so deployment fails closed when a required binding is missing.
- Never put real values in examples, source, app code, logs, or fixtures.

For local manual testing later, use ignored backend/.dev.vars and keep its values out of terminal output and screenshots.

## Deploy

~~~bash
npm run build
npx wrangler deploy
~~~

After deploying, enter the Worker HTTPS origin and the same APP_TOKEN in iOS Settings. A readiness check sends no transcript and makes no OpenAI call.

## API

**GET /api/status** requires Authorization: Bearer APP_TOKEN and returns configured plus a request ID.

**POST /api/summarize**

~~~json
{
  "noteId": "00000000-0000-4000-8000-000000000001",
  "transcript": "saved edited transcript",
  "transcriptRevision": 4,
  "segments": [{ "startTime": 0, "endTime": 4.2, "text": "optional original segment" }]
}
~~~

Segments are optional and used only when their ordered text exactly matches the transcript. Edited text cannot be replaced by stale segment text.

~~~json
{
  "transcriptRevision": 4,
  "title": "Concise title",
  "summary": "Useful summary",
  "keyPoints": [],
  "actionItems": [],
  "model": "configured-model",
  "generatedAt": "2026-08-28T10:20:30.123Z",
  "requestId": "server-generated-id"
}
~~~

## Safeguards

- Constant-work SHA-256 APP_TOKEN comparison
- Separate fail-closed Cloudflare limits for logical requests and planned OpenAI calls
- 512 KiB streamed body and 120,000 transcript-character limits
- UUID, revision, JSON, segment ordering, and extra-key validation
- 90-second deadline/cancellation; 2,000 output-token cap per call
- 256 KiB bounded upstream response reader
- Strict JSON Schema plus independent output validation
- Refusal, incomplete, upstream, timeout, and malformed JSON handling
- store: false; no tools, cloud STT, or provider fallback
- No redirects; no transcript/provider-body/secret logs

Inputs beyond 16,000 characters use at most eight chronological partial calls plus one synthesis. The Worker reserves one OpenAI-call limiter token for every planned partial/synthesis call before starting. Exceeding either budget returns an error without a partial result or dropped text.

Cloudflare says its limiter is per location and eventually consistent. Also configure OpenAI project budgets/limits.

Logs contain only requestId, status, latencyMs, inputChars, model, and errorCategory. Stored observability and Wrangler telemetry are disabled by default.
