// Cloudflare Pages Function — Stripe webhook receiver.
// On checkout.session.completed, emails the buyer their download link via Resend.
//
// Required environment variables (set in Cloudflare Pages project settings):
//   STRIPE_SECRET_KEY     — same key used to create the payment link
//   STRIPE_WEBHOOK_SECRET — from the webhook endpoint in the Stripe dashboard
//   RESEND_API_KEY        — Resend API key with sending access
//   MAIL_FROM             — verified sender, e.g. "君斗りんくの送信サジェスト <noreply@best-trust.biz>"

import Stripe from "stripe";

const DOWNLOAD_URL =
  "https://github.com/kimito-link/soushin-suggest.link/releases/download/v1.1.2/soushin-suggest-v1.1.2.zip";
const SITE_URL = "https://soushin-suggest.link";
const KIMITO_LINK_COM_URL = "https://kimito-link.com";
const BRAND_LOGO_URL = "https://soushin-suggest.link/assets/email/kimitolink-logo.png";
const PRODUCT_ICON_URL = "https://soushin-suggest.link/assets/email/logo.png";

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
      subject: "【君斗りんくの送信サジェスト】ダウンロードのご案内｜ご購入ありがとうございます",
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
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;">ダウンロードリンクと、3ステップのかんたん導入手順をご案内します。</div>

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f8fafc;">
<tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#ffffff;border-radius:16px;overflow:hidden;">

  <tr><td align="center" style="padding:36px 32px 8px;">
    <a href="${KIMITO_LINK_COM_URL}" style="text-decoration:none;">
      <img src="${BRAND_LOGO_URL}" alt="kimito link" width="160" style="display:block;width:160px;height:auto;">
    </a>
  </td></tr>

  <tr><td style="padding:8px 40px 0;font-family:'Hiragino Kaku Gothic ProN','Yu Gothic',Meiryo,sans-serif;color:#1e293b;">
    <h1 style="margin:0 0 16px;font-size:22px;line-height:1.5;text-align:center;">ご購入ありがとうございます</h1>
    <p style="margin:0;font-size:15px;line-height:1.9;">
      このたびは「君斗りんくの送信サジェスト」をお迎えいただき、ありがとうございます。<br>
      毎日の「送るまでのひと手間」を、今日からこのツールが引き受けます。<br>
      まずは下のボタンから、インストーラーをダウンロードしてください。
    </p>
  </td></tr>

  <tr><td align="center" style="padding:28px 40px 8px;">
    <a href="${DOWNLOAD_URL}"
       style="background:#1d4ed8;color:#ffffff;text-decoration:none;padding:16px 48px;border-radius:999px;font-weight:bold;font-size:16px;display:inline-block;font-family:'Hiragino Kaku Gothic ProN','Yu Gothic',Meiryo,sans-serif;">
      ダウンロードする
    </a>
    <p style="margin:12px 0 0;font-size:12px;color:#64748b;font-family:sans-serif;word-break:break-all;">
      ボタンが開けない場合はこちら:<br>
      <a href="${DOWNLOAD_URL}" style="color:#1d4ed8;">${DOWNLOAD_URL}</a>
    </p>
  </td></tr>

  <tr><td style="padding:20px 40px 0;font-family:'Hiragino Kaku Gothic ProN','Yu Gothic',Meiryo,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f1f5f9;border-radius:12px;">
      <tr><td style="padding:20px 24px;color:#334155;">
        <p style="margin:0 0 10px;font-size:14px;font-weight:bold;">導入はかんたん3ステップ（管理者権限は不要です）</p>
        <p style="margin:0;font-size:14px;line-height:2.0;">
          1. ダウンロードした zip を右クリック →「すべて展開」<br>
          2. 展開したフォルダの <b>soushin-suggest.exe</b> をダブルクリック<br>
          3. これだけで動き始めます。詳しくは同梱の README.txt をどうぞ
        </p>
      </td></tr>
    </table>
    <p style="margin:14px 0 0;font-size:13px;color:#64748b;line-height:1.8;">
      使い方・よくある質問は製品ページへ:
      <a href="${SITE_URL}" style="color:#1d4ed8;">${SITE_URL}</a>
    </p>
  </td></tr>

  <tr><td style="padding:28px 40px 0;"><div style="border-top:1px solid #e2e8f0;"></div></td></tr>

  <tr><td style="padding:24px 40px 0;font-family:'Hiragino Kaku Gothic ProN','Yu Gothic',Meiryo,sans-serif;">
    <p style="margin:0;font-size:13px;line-height:2.0;color:#475569;">
      送信サジェストは、株式会社ベストトラストの「君斗りんく」プロジェクトが作ったツールのひとつです。
      私たちは<b>「クリエイターとファンをつなぐ確かな絆」</b>を合言葉に、発信や返信にかかる手間を減らして、
      創る時間・届ける時間を1分でも増やすための道具づくりを続けています。
      このツールで浮いた時間が、あなたの次の一作につながればうれしいです。
    </p>
  </td></tr>

  <tr><td style="padding:24px 40px 0;font-family:'Hiragino Kaku Gothic ProN','Yu Gothic',Meiryo,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e2e8f0;border-radius:12px;">
      <tr><td style="padding:18px 22px;">
        <p style="margin:0 0 6px;font-size:12px;color:#94a3b8;font-weight:bold;">「送る」の次は「返す」も</p>
        <p style="margin:0 0 10px;font-size:14px;line-height:1.8;color:#334155;">
          届いたリプやDMへの返信文をAIが提案する
          <b>「AI返信サジェスト」</b>もあります。送信サジェストと同じ感覚で使えます。
        </p>
        <a href="https://reply-suggest.link" style="font-size:13px;color:#1d4ed8;font-weight:bold;">reply-suggest.link を見てみる &rarr;</a>
      </td></tr>
    </table>
  </td></tr>

  <tr><td style="padding:28px 40px 0;font-family:'Hiragino Kaku Gothic ProN','Yu Gothic',Meiryo,sans-serif;">
    <p style="margin:0 0 4px;font-size:12px;font-weight:bold;color:#64748b;">君斗りんくのサービス一覧</p>
    <p style="margin:0 0 10px;font-size:11px;color:#94a3b8;">創る人と支える人がつながる場所を、少しずつ増やしています。</p>
    <p style="margin:0;font-size:12px;line-height:2.1;color:#64748b;">
      <a href="https://kimito-link.com" style="color:#1d4ed8;">kimito-link.com</a> — プロジェクトの理念と、全ツールを紹介する「工房」<br>
      <a href="https://kimito.link" style="color:#1d4ed8;">kimito.link</a> — プロフィールリンクまとめ<br>
      <a href="https://soushin-suggest.link" style="color:#1d4ed8;">soushin-suggest.link</a> — 送信サジェスト（本製品）<br>
      <a href="https://reply-suggest.link" style="color:#1d4ed8;">reply-suggest.link</a> — AI返信サジェスト<br>
      <a href="https://henshin-hisho.link" style="color:#1d4ed8;">henshin-hisho.link</a> — AI返信秘書
    </p>
  </td></tr>

  <tr><td align="center" style="padding:28px 40px 36px;font-family:'Hiragino Kaku Gothic ProN','Yu Gothic',Meiryo,sans-serif;">
    <img src="${PRODUCT_ICON_URL}" alt="" width="32" height="32" style="border-radius:50%;display:inline-block;">
    <p style="margin:10px 0 0;font-size:11px;color:#94a3b8;line-height:1.9;">
      君斗りんくの送信サジェスト ／ 株式会社ベストトラスト<br>
      このメールはご購入時のご案内として自動送信しています。心当たりがない場合は破棄してください。
    </p>
  </td></tr>

</table>
</td></tr>
</table>`.trim();
}
