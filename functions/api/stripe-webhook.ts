// Cloudflare Pages Function — Stripe webhook receiver.
// On checkout.session.completed, emails the buyer their download link via Resend.
//
// Required environment variables (set in Cloudflare Pages project settings):
//   STRIPE_SECRET_KEY     — same key used to create the payment link
//   STRIPE_WEBHOOK_SECRET — from the webhook endpoint in the Stripe dashboard
//   RESEND_API_KEY        — Resend API key with sending access
//   MAIL_FROM             — verified sender, e.g. "送信サジェスト <noreply@kimito.link>"

import Stripe from "stripe";

const DOWNLOAD_URL =
  "https://github.com/kimito-link/soushin-suggest.link/releases/download/v1.0.0/soushin-suggest-v1.0.0.zip";

interface Env {
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  RESEND_API_KEY: string;
  MAIL_FROM: string;
}

export const onRequestPost: PagesFunction<Env> = async (context) => {
  const { request, env } = context;

  if (!env.STRIPE_SECRET_KEY || !env.STRIPE_WEBHOOK_SECRET) {
    // Not configured yet — acknowledge so Stripe doesn't retry, but do nothing.
    return new Response(JSON.stringify({ skipped: true }), { status: 200 });
  }

  const stripe = new Stripe(env.STRIPE_SECRET_KEY, {
    apiVersion: "2025-08-27.basil",
  });

  const signature = request.headers.get("stripe-signature");
  const rawBody = await request.text();

  let event: Stripe.Event;
  try {
    if (!signature) throw new Error("missing stripe-signature header");
    event = await stripe.webhooks.constructEventAsync(
      rawBody,
      signature,
      env.STRIPE_WEBHOOK_SECRET
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: `signature verification failed: ${String(err)}` }),
      { status: 400 }
    );
  }

  if (event.type !== "checkout.session.completed") {
    return new Response(JSON.stringify({ ignored: event.type }), { status: 200 });
  }

  const session = event.data.object as Stripe.Checkout.Session;
  const email = session.customer_details?.email;

  if (!email) {
    // Nothing to send to — acknowledge, don't make Stripe retry forever.
    return new Response(JSON.stringify({ error: "no customer email on session" }), {
      status: 200,
    });
  }

  try {
    await sendDownloadEmail(env, email);
  } catch (err) {
    // Let Stripe retry — this is a genuine delivery failure.
    return new Response(JSON.stringify({ error: `email send failed: ${String(err)}` }), {
      status: 500,
    });
  }

  return new Response(JSON.stringify({ ok: true }), { status: 200 });
};

async function sendDownloadEmail(env: Env, to: string): Promise<void> {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: env.MAIL_FROM,
      to,
      subject: "【送信サジェスト】ダウンロードのご案内",
      html: renderEmailHtml(),
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`resend api ${res.status}: ${body}`);
  }
}

function renderEmailHtml(): string {
  return `
<div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; color: #1e293b;">
  <h2>ご購入ありがとうございます</h2>
  <p>送信サジェストをお買い上げいただき、ありがとうございます。<br>
  下のボタンからインストーラーをダウンロードしてください。</p>
  <p style="text-align: center; margin: 32px 0;">
    <a href="${DOWNLOAD_URL}"
       style="background:#1d4ed8;color:#fff;text-decoration:none;padding:14px 28px;border-radius:999px;font-weight:800;display:inline-block;">
      ダウンロードする
    </a>
  </p>
  <p style="font-size: 13px; color: #64748b;">
    導入方法: ダウンロードしたzipを展開し、soushin-suggest.exe をダブルクリックするだけです（管理者権限は不要です）。<br>
    詳しくは同梱の README.txt をご覧ください。
  </p>
  <p style="font-size: 13px; color: #64748b; margin-top: 24px;">
    このメールに心当たりがない場合は、破棄していただいて問題ありません。
  </p>
</div>`.trim();
}
