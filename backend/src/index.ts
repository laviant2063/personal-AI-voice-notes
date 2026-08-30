import { APIError, readLimits, validateRequest } from "./contracts.ts";
import type { Env } from "./contracts.ts";
import { aborted, planSummary, readBounded, summarize, withAbort } from "./openai.ts";
import type { Fetcher } from "./openai.ts";

export interface RequestLog {
  requestId: string;
  status: number;
  latencyMs: number;
  inputChars: number;
  model: string | null;
  errorCategory: string | null;
}

function validModel(model: string | undefined): model is string {
  return Boolean(model && !model.startsWith("sk-")
    && /^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,119}$/.test(model));
}

function configured(env: Env): boolean {
  return Boolean(env.OPENAI_API_KEY?.trim()
    && validModel(env.OPENAI_MODEL)
    && env.SUMMARY_RATE_LIMITER
    && env.OPENAI_CALL_RATE_LIMITER);
}

async function reserveRateTokens(
  limiter: NonNullable<Env["SUMMARY_RATE_LIMITER"]>, count: number,
  key: string, signal: AbortSignal,
): Promise<void> {
  try {
    for (let index = 0; index < count; index += 1) {
      const allowed = await withAbort(limiter.limit({ key }), signal);
      if (!allowed.success) {
        throw new APIError(429, "rate_limited", "The personal request limit was reached.");
      }
    }
  } catch (error) {
    if (error instanceof APIError) throw error;
    throw new APIError(503, "rate_limit_unavailable", "The request limiter is unavailable.");
  }
}

async function authenticate(request: Request, env: Env): Promise<void> {
  if (!env.APP_TOKEN || !/^[A-Za-z0-9._~+/=-]{32,512}$/.test(env.APP_TOKEN) || env.APP_TOKEN.startsWith("sk-")) {
    throw new APIError(503, "backend_not_configured", "Backend authentication is not configured.");
  }
  const authorization = request.headers.get("authorization") ?? "";
  if (authorization.length > 1024 || !authorization.startsWith("Bearer ")) {
    throw new APIError(401, "unauthorized", "A valid personal backend token is required.");
  }
  const encoder = new TextEncoder();
  const [actual, expected] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(authorization.slice(7))),
    crypto.subtle.digest("SHA-256", encoder.encode(env.APP_TOKEN)),
  ]);
  const a = new Uint8Array(actual);
  const b = new Uint8Array(expected);
  let difference = 0;
  for (let i = 0; i < a.length; i += 1) difference |= a[i]! ^ b[i]!;
  if (difference !== 0) throw new APIError(401, "unauthorized", "A valid personal backend token is required.");
}

function json(value: unknown, status: number, requestId: string): Response {
  return Response.json(value, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Request-ID": requestId,
      "X-Content-Type-Options": "nosniff",
      ...(status === 429 ? { "Retry-After": "60" } : {}),
    },
  });
}

/** Dependency injection is for tests, never an environment-controlled demo mode. */
export function createHandler(options: {
  fetcher?: Fetcher;
  log?: (record: RequestLog) => void;
} = {}): (request: Request, env: Env) => Promise<Response> {
  const fetcher: Fetcher = options.fetcher ?? ((url, init) => fetch(url, init));
  const log = options.log ?? (record => console.log(JSON.stringify(record)));
  return async (request, env) => {
    const requestId = crypto.randomUUID();
    const started = Date.now();
    let status = 500;
    let inputChars = 0;
    let errorCategory: string | null = null;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const controller = new AbortController();
    const cancel = () => controller.abort(new APIError(499, "cancelled", "The request was cancelled."));
    request.signal.addEventListener("abort", cancel, { once: true });
    if (request.signal.aborted) cancel();
    try {
      const pathname = new URL(request.url).pathname;
      if (pathname !== "/api/summarize" && pathname !== "/api/status") {
        throw new APIError(404, "not_found", "Endpoint not found.");
      }
      if ((pathname === "/api/summarize" && request.method !== "POST")
          || (pathname === "/api/status" && request.method !== "GET")) {
        throw new APIError(405, "method_not_allowed", "Method not allowed.");
      }
      const limits = readLimits(env);
      timer = setTimeout(() => controller.abort(
        new APIError(504, "timeout", "AI processing exceeded the request time limit.")), limits.timeoutMs);
      if (controller.signal.aborted) throw aborted(controller.signal);
      await withAbort(authenticate(request, env), controller.signal);
      if (pathname === "/api/status") {
        status = 200;
        return json({ configured: configured(env), requestId }, status, requestId);
      }
      if (!configured(env)) {
        throw new APIError(503, "backend_not_configured", "Backend AI settings or rate limiting are not configured.");
      }
      // One ingress token per logical request, independent of user-controlled note IDs or IPs.
      await reserveRateTokens(env.SUMMARY_RATE_LIMITER!, 1, "personal-summary", controller.signal);
      if ((request.headers.get("content-type") ?? "").split(";")[0]?.trim().toLowerCase() !== "application/json") {
        throw new APIError(415, "unsupported_media_type", "Use application/json.");
      }
      const length = request.headers.get("content-length");
      if (length !== null && (!/^\d+$/.test(length) || Number(length) > limits.bodyBytes)) {
        throw new APIError(413, "body_too_large", "Request body exceeds the safety limit.");
      }
      const body = await readBounded(request.body, limits.bodyBytes, controller.signal);
      let value: unknown;
      try { value = JSON.parse(body); }
      catch { throw new APIError(400, "invalid_json", "The request is not valid JSON."); }
      const payload = validateRequest(value, limits);
      inputChars = payload.transcript.length;
      const plan = planSummary(payload, limits);
      // Reserve the entire planned upstream-call budget before making call one.
      await reserveRateTokens(
        env.OPENAI_CALL_RATE_LIMITER!, plan.upstreamCalls,
        "personal-openai-call", controller.signal);
      const result = await summarize(payload, env, limits, fetcher, controller.signal, plan);
      if (controller.signal.aborted) throw aborted(controller.signal);
      status = 200;
      return json({
        transcriptRevision: payload.transcriptRevision,
        ...result,
        model: env.OPENAI_MODEL,
        generatedAt: new Date().toISOString(),
        requestId,
      }, status, requestId);
    } catch (error) {
      const safe = error instanceof APIError ? error
        : new APIError(500, "internal_error", "The backend could not complete the request.");
      status = safe.status;
      errorCategory = safe.code;
      return json({ error: { code: safe.code, message: safe.message }, requestId }, status, requestId);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
      request.signal.removeEventListener("abort", cancel);
      // No transcript, body, note ID, headers, tokens, prompts, or provider error bodies.
      log({
        requestId, status, latencyMs: Date.now() - started, inputChars,
        model: validModel(env.OPENAI_MODEL) ? env.OPENAI_MODEL : null,
        errorCategory,
      });
    }
  };
}

export default { fetch: createHandler() };
