// Cloudflare Pages Function — returns the most recent diagnostic snapshot for a token.
// See _docs/SHINDAN-AUTO-SEND-DESIGN.md. Never cached: the whole point is "what's true now".

interface Env {
  DIAG_KV: KVNamespace;
}

const TOKEN_RE = /^[0-9a-f]{32}$/;

export const onRequestGet: PagesFunction<Env> = async (context) => {
  const { request, env } = context;

  if (!env.DIAG_KV) {
    return new Response(null, { status: 503 });
  }

  const url = new URL(request.url);
  const token = url.searchParams.get("t") || "";
  if (!TOKEN_RE.test(token)) {
    return new Response(null, { status: 400 });
  }

  const stored = await env.DIAG_KV.get(`diag:${token}`);
  if (!stored) {
    return new Response(null, { status: 404, headers: { "Cache-Control": "no-store" } });
  }

  return new Response(stored, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
};
