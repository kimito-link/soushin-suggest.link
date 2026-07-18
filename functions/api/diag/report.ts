// Cloudflare Pages Function — receives a diagnostic snapshot from the desktop app and
// stores it under an anonymous token with a short TTL. See _docs/SHINDAN-AUTO-SEND-DESIGN.md.
//
// Deliberately minimal: no logging beyond the platform's own access log, no aggregation,
// no cross-token linkage. The KV entry expires on its own (expirationTtl) — there is no
// delete code path to forget to run.

interface Env {
  DIAG_KV: KVNamespace;
}

const TOKEN_RE = /^[0-9a-f]{32}$/;
const MAX_BODY_BYTES = 8 * 1024;
const TTL_SECONDS = 6 * 60 * 60; // 6 hours

export const onRequestPost: PagesFunction<Env> = async (context) => {
  const { request, env } = context;

  if (!env.DIAG_KV) {
    return new Response(null, { status: 503 });
  }

  const contentType = request.headers.get("content-type") || "";
  if (!contentType.includes("application/json")) {
    return new Response(null, { status: 400 });
  }

  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) {
    return new Response(null, { status: 413 });
  }

  let body: { token?: unknown; diag?: unknown };
  try {
    body = JSON.parse(raw);
  } catch {
    return new Response(null, { status: 400 });
  }

  const token = body.token;
  const diag = body.diag as { app?: unknown } | undefined;
  if (
    typeof token !== "string" ||
    !TOKEN_RE.test(token) ||
    !diag ||
    typeof diag !== "object" ||
    diag.app !== "soushin-suggest"
  ) {
    return new Response(null, { status: 400 });
  }

  await env.DIAG_KV.put(
    `diag:${token}`,
    JSON.stringify({ receivedAt: Date.now(), diag }),
    { expirationTtl: TTL_SECONDS },
  );

  return new Response(null, { status: 204 });
};
