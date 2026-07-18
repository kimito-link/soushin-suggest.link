// Cloudflare Pages Function — returns the most recent diagnostic snapshot for a token,
// or (with no token, but a valid password) the single most recent snapshot from any
// client. See _docs/SHINDAN-AUTO-SEND-DESIGN.md. Never cached: the whole point is
// "what's true now".
//
// 2026-07-18: no-token access requires DIAG_VIEW_PASSWORD (set in Cloudflare Pages
// project env vars) so opening the bare URL isn't enough — an explicit, user-requested
// tradeoff between "just works by visiting the domain" and "not wide open to anyone
// who knows the URL".

interface Env {
  DIAG_KV: KVNamespace;
  DIAG_VIEW_PASSWORD?: string;
}

const TOKEN_RE = /^[0-9a-f]{32}$/;

export const onRequestGet: PagesFunction<Env> = async (context) => {
  const { request, env } = context;

  if (!env.DIAG_KV) {
    return new Response(null, { status: 503 });
  }

  const url = new URL(request.url);
  const token = url.searchParams.get("t") || "";

  let key: string;
  if (token !== "") {
    if (!TOKEN_RE.test(token)) {
      return new Response(null, { status: 400 });
    }
    key = `diag:${token}`;
  } else {
    if (!env.DIAG_VIEW_PASSWORD) {
      return new Response(null, { status: 503 }); // not configured — fail closed, not open
    }
    const password = request.headers.get("x-diag-password") || "";
    if (password !== env.DIAG_VIEW_PASSWORD) {
      return new Response(null, { status: 401 });
    }
    key = "diag:latest";
  }

  const stored = await env.DIAG_KV.get(key);
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
