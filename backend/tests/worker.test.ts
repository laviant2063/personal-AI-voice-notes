import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../src/index.ts";
import { chunkTranscript } from "../src/openai.ts";
import { readLimits, validateSummary, summarySchema } from "../src/contracts.ts";
import type { Env, StructuredSummary } from "../src/contracts.ts";
import type { Fetcher } from "../src/openai.ts";

// All accidental non-injected network access fails this suite.
mock.method(globalThis, "fetch", async () => { throw new Error("External network is forbidden in tests."); });
const appToken = "test-only-personal-token-000000000000";
const noteId = "00000000-0000-4000-8000-000000000001";
const summary: StructuredSummary = {
  title: "회의", summary: "민수는 금요일에 SDK 2.0 검토를 공유하기로 했다.",
  keyPoints: ["SDK 2.0 검토"], actionItems: [{ text: "민수: 금요일에 검토 공유" }],
};
function environment(overrides: Partial<Env> = {}): Env {
  return {
    APP_TOKEN: appToken,
    OPENAI_API_KEY: "unit-test-only-upstream-credential",
    OPENAI_MODEL: "test-model",
    SUMMARY_RATE_LIMITER: { limit: async () => ({ success: true }) },
    OPENAI_CALL_RATE_LIMITER: { limit: async () => ({ success: true }) },
    ...overrides,
  };
}
function request(transcript = "민수는 금요일에 SDK 2.0 검토를 공유한다.", extra: Record<string, unknown> = {}): Request {
  return new Request("https://backend.test/api/summarize", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${appToken}` },
    body: JSON.stringify({ noteId, transcript, transcriptRevision: 3, ...extra }),
  });
}
function upstream(result: unknown = summary, overrides: Record<string, unknown> = {}): Response {
  return Response.json({
    status: "completed",
    output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify(result) }] }],
    ...overrides,
  });
}
function setup(fetcher: Fetcher = async () => upstream()) {
  const logs: unknown[] = [];
  return { handler: createHandler({ fetcher, log: record => logs.push(record) }), logs };
}

test("one short operation returns all fields and the original revision, using strict Responses schema", async () => {
  const calls: { url: string; body: Record<string, unknown> }[] = [];
  const { handler } = setup(async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body as string) });
    assert.equal(init.redirect, "error");
    return upstream();
  });
  const response = await handler(request(), environment());
  assert.equal(response.status, 200);
  const value = await response.json() as Record<string, unknown>;
  assert.equal(value.transcriptRevision, 3);
  assert.equal(value.title, summary.title);
  assert.equal(value.summary, summary.summary);
  assert.deepEqual(value.keyPoints, summary.keyPoints);
  assert.deepEqual(value.actionItems, summary.actionItems);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.url, "https://api.openai.com/v1/responses");
  const sent = calls[0]!.body;
  assert.equal(sent.model, "test-model");
  assert.equal(sent.store, false);
  assert.equal(sent.max_output_tokens, 2000);
  assert.deepEqual(sent.text, { format: { type: "json_schema", name: "voice_note_summary", strict: true, schema: summarySchema } });
  assert.match(sent.instructions as string, /untrusted source data/);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.ok(response.headers.get("X-Request-ID"));
});

test("missing key/model/limiter never invokes upstream or returns a fake summary", async () => {
  for (const missing of [
    "OPENAI_API_KEY", "OPENAI_MODEL", "SUMMARY_RATE_LIMITER", "OPENAI_CALL_RATE_LIMITER",
  ] as const) {
    let calls = 0;
    const { handler } = setup(async () => { calls++; return upstream(); });
    const response = await handler(request(), environment({ [missing]: undefined }));
    assert.equal(response.status, 503);
    const body = await response.json() as { error: { code: string }; title?: unknown };
    assert.equal(body.error.code, "backend_not_configured");
    assert.equal(body.title, undefined);
    assert.equal(calls, 0);
  }
  const { handler, logs } = setup(async () => { throw new Error("must not call"); });
  const invalidModel = await handler(request(), environment({ OPENAI_MODEL: "sk-secret-shaped-model" }));
  assert.equal(invalidModel.status, 503);
  assert.equal((logs[0] as { model: string | null }).model, null);
});

test("readiness is authenticated and never calls OpenAI", async () => {
  const { handler } = setup(async () => { throw new Error("must not call"); });
  const status = () => new Request("https://backend.test/api/status", { headers: { Authorization: `Bearer ${appToken}` } });
  const ready = await handler(status(), environment());
  assert.equal((await ready.json() as { configured: boolean }).configured, true);
  const missing = await handler(status(), environment({ OPENAI_API_KEY: undefined }));
  assert.equal((await missing.json() as { configured: boolean }).configured, false);
  const unauthorized = await handler(new Request("https://backend.test/api/status"), environment());
  assert.equal(unauthorized.status, 401);
});

test("authentication rejects missing, incorrect, oversized, and OpenAI-like personal tokens", async () => {
  let calls = 0;
  const { handler } = setup(async () => { calls++; return upstream(); });
  for (const token of ["", "Bearer wrong", "Bearer " + "x".repeat(1100)]) {
    const req = request();
    req.headers.set("Authorization", token);
    assert.equal((await handler(req, environment())).status, 401);
  }
  assert.equal((await handler(request(), environment({ APP_TOKEN: undefined }))).status, 503);
  assert.equal((await handler(request(), environment({ APP_TOKEN: "sk-" + "x".repeat(40) }))).status, 503);
  assert.equal(calls, 0);
});

test("server limiter fails closed and uses one bucket across note IDs", async () => {
  const keys: string[] = [];
  let calls = 0;
  const { handler } = setup(async () => { calls++; return upstream(); });
  const env = environment({ SUMMARY_RATE_LIMITER: { limit: async ({ key }) => { keys.push(key); return { success: false }; } } });
  const limited = await handler(request(), env);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("Retry-After"), "60");
  await handler(request("text", { noteId: "00000000-0000-4000-8000-000000000002" }), env);
  assert.deepEqual(keys, ["personal-summary", "personal-summary"]);
  const broken = environment({ SUMMARY_RATE_LIMITER: { limit: async () => { throw new Error("secret backend details"); } } });
  assert.equal((await handler(request(), broken)).status, 503);
  assert.equal(calls, 0);
});

test("long requests reserve every planned upstream call before call one", async () => {
  let budgetChecks = 0;
  let upstreamCalls = 0;
  const { handler } = setup(async () => { upstreamCalls++; return upstream(); });
  const env = environment({
    DIRECT_TRANSCRIPT_CHARS: "512",
    OPENAI_CALL_RATE_LIMITER: {
      limit: async ({ key }) => {
        assert.equal(key, "personal-openai-call");
        budgetChecks++;
        return { success: budgetChecks < 3 };
      },
    },
  });
  const response = await handler(request("x".repeat(1200)), env);
  assert.equal(response.status, 429);
  assert.equal(budgetChecks, 3);
  assert.equal(upstreamCalls, 0);
});

test("request validation rejects invalid revisions, empty text, wrong IDs, and extra fields", async () => {
  const { handler } = setup();
  for (const extra of [
    { transcriptRevision: -1 }, { transcriptRevision: 1.2 },
    { transcriptRevision: Number.MAX_SAFE_INTEGER + 1 }, { transcriptRevision: "3" },
    { noteId: "../other" }, { model: "client-selected-model" }, { transcript: " \n" },
    { segments: [{ startTime: -1, text: "bad" }] },
    { segments: [{ startTime: 5, endTime: 1, text: "bad" }] },
  ]) {
    assert.equal((await handler(request("text", extra), environment())).status, 400);
  }
  const malformed = request();
  const req = new Request(malformed.url, { method: "POST", headers: malformed.headers, body: "not json" });
  assert.equal((await handler(req, environment())).status, 400);
});

test("streamed byte limit works without Content-Length; character limit is separate", async () => {
  const { handler } = setup();
  const bytes = new TextEncoder().encode(JSON.stringify({ noteId, transcript: "한".repeat(1000), transcriptRevision: 0 }));
  const body = new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(bytes.slice(0, 600)); controller.enqueue(bytes.slice(600)); controller.close(); },
  });
  const req = new Request("https://backend.test/api/summarize", {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${appToken}` },
    body, duplex: "half",
  } as RequestInit & { duplex: string });
  assert.equal((await handler(req, environment({ MAX_BODY_BYTES: "1024" }))).status, 413);
  assert.equal((await handler(request("x".repeat(513)), environment({ MAX_TRANSCRIPT_CHARS: "512" }))).status, 413);
});

test("unknown routes, wrong methods and content types never reach upstream", async () => {
  const { handler } = setup(async () => { throw new Error("must not call"); });
  assert.equal((await handler(new Request("https://backend.test/unknown"), environment())).status, 404);
  assert.equal((await handler(new Request("https://backend.test/api/summarize"), environment())).status, 405);
  const req = request();
  req.headers.set("Content-Type", "text/plain");
  assert.equal((await handler(req, environment())).status, 415);
});

test("long transcripts preserve all text and use bounded chronological partials then synthesis", async () => {
  const transcript = "first ".repeat(90) + "중간😀".repeat(130) + " last".repeat(100);
  const parts = chunkTranscript({ noteId, transcript, transcriptRevision: 0 }, 512);
  assert.equal(parts.join(""), transcript);
  assert.ok(parts.every(part => part.length <= 512 && !/[\uD800-\uDBFF]$/.test(part)));
  const inputs: string[] = [];
  const { handler } = setup(async (_url, init) => {
    const sent = JSON.parse(init.body as string);
    inputs.push(sent.input[0].content[0].text);
    return upstream({ ...summary, title: "part " + inputs.length });
  });
  let budgetChecks = 0;
  assert.equal((await handler(request(transcript), environment({
    DIRECT_TRANSCRIPT_CHARS: "512",
    OPENAI_CALL_RATE_LIMITER: {
      limit: async () => { budgetChecks++; return { success: true }; },
    },
  }))).status, 200);
  assert.deepEqual(inputs.slice(0, -1), parts);
  assert.equal(inputs.length, parts.length + 1);
  assert.equal(budgetChecks, inputs.length);
  const final = JSON.parse(inputs.at(-1)!);
  assert.deepEqual(final.chronologicalPartialSummaries.map((part: StructuredSummary) => part.title),
    parts.map((_part, index) => "part " + (index + 1)));
});

test("segment boundaries are used when they match; edited/mismatched segment text never replaces input", () => {
  const segments = [{ startTime: 0, text: "a".repeat(400) }, { startTime: 2, text: "b".repeat(400) }];
  const transcript = segments.map(segment => segment.text).join("\n");
  const parts = chunkTranscript({ noteId, transcript, transcriptRevision: 0, segments }, 512);
  assert.equal(parts.join(""), transcript);
  assert.equal(parts.length, 2);
  const edited = chunkTranscript({ noteId, transcript: "edited ".repeat(100), transcriptRevision: 1, segments }, 512);
  assert.equal(edited.join(""), "edited ".repeat(100));
});

test("exact threshold stays one call; exceeding the chunk budget fails before any call", async () => {
  let calls = 0;
  const { handler } = setup(async () => { calls++; return upstream(); });
  assert.equal((await handler(request("x".repeat(512)), environment({ DIRECT_TRANSCRIPT_CHARS: "512" }))).status, 200);
  assert.equal(calls, 1);
  calls = 0;
  assert.equal((await handler(request("x".repeat(1537)),
    environment({ DIRECT_TRANSCRIPT_CHARS: "512", MAX_CHUNKS: "2" }))).status, 413);
  assert.equal(calls, 0);
});

test("invalid AI JSON, schema, extra properties, refusal and incomplete output cannot become success", async () => {
  const cases: [() => Response, number][] = [
    [() => new Response("not JSON"), 502],
    [() => upstream({ title: "missing fields" }), 502],
    [() => upstream({ ...summary, actionItems: ["not an object"] }), 502],
    [() => upstream({ ...summary, extra: true }), 502],
    [() => upstream({ ...summary, title: "" }), 502],
    [() => upstream(summary, { status: "incomplete" }), 502],
    [() => upstream(summary, { output: [{ type: "message", content: [{ type: "refusal", refusal: "private text" }] }] }), 422],
    [() => upstream(summary, { output: [] }), 502],
    [() => new Response("x".repeat(256 * 1024 + 1)), 502],
  ];
  for (const [make, expected] of cases) {
    const { handler } = setup(async () => make());
    const response = await handler(request(), environment());
    assert.equal(response.status, expected);
    assert.equal((await response.json() as { title?: string }).title, undefined);
  }
  assert.doesNotThrow(() => validateSummary({ title: "No tasks", summary: "An observation.", keyPoints: [], actionItems: [] }));
});

test("upstream auth, rate limit, server and network failures are sanitized", async () => {
  for (const code of [401, 403, 429, 500, 503]) {
    const { handler } = setup(async () => new Response("secret-provider-body", { status: code }));
    const result = await handler(request(), environment());
    assert.equal(result.status, code === 429 ? 429 : 502);
    assert.ok(!(await result.text()).includes("secret-provider-body"));
  }
  const { handler } = setup(async () => { throw new TypeError("DNS with secret context"); });
  assert.equal((await handler(request(), environment())).status, 502);
});

test("overall timeout ends hung upstream without retrying", async () => {
  let calls = 0;
  const { handler } = setup(async () => { calls++; return new Promise<Response>(() => undefined); });
  const result = await handler(request(), environment({ REQUEST_TIMEOUT_MS: "50" }));
  assert.equal(result.status, 504);
  assert.equal(calls, 1);
});

test("cancelled requests do not call upstream, and cancellation during generation returns no result", async () => {
  let calls = 0;
  const { handler } = setup(async () => { calls++; return new Promise<Response>(() => undefined); });
  const pre = new AbortController();
  pre.abort();
  const cancelled = new Request(request(), { signal: pre.signal });
  assert.equal((await handler(cancelled, environment())).status, 499);
  assert.equal(calls, 0);
  const active = new AbortController();
  const pending = handler(new Request(request(), { signal: active.signal }), environment());
  setTimeout(() => active.abort(), 20);
  assert.equal((await pending).status, 499);
});

test("production logs contain only safe metadata, never transcripts or credentials", async () => {
  const secretTranscript = "PRIVATE-TRANSCRIPT-UNIQUE-123";
  const { handler, logs } = setup();
  await handler(request(secretTranscript), environment());
  const rendered = JSON.stringify(logs);
  assert.ok(!rendered.includes(secretTranscript));
  assert.ok(!rendered.includes(appToken));
  assert.ok(!rendered.includes("unit-test-only-upstream-credential"));
  assert.ok(!rendered.includes(noteId));
  assert.deepEqual(Object.keys(logs[0] as object).sort(),
    ["requestId", "status", "latencyMs", "inputChars", "model", "errorCategory"].sort());
});

test("invalid backend limits fail closed", () => {
  for (const value of ["-1", "0", "NaN", "500000000", "90.5"]) {
    assert.throws(() => readLimits(environment({ REQUEST_TIMEOUT_MS: value })));
  }
});
