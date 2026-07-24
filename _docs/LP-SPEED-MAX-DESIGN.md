# soushin-suggest.link 表示速度最大化 設計書

- 設計＝Fable（claude-fable-5サブエージェント） / 素材集め＝会議ハーネス（groq/qwen/nvidia等5体、成功3/5） / 裏取り＝司令塔Claude
- 日付: 2026-07-24
- 3段構えワークフロー（[COUNCIL-HOWTO.md](../../COUNCIL-HOWTO.md) / [FABLE-3STEP-HOWTO.md](../../FABLE-3STEP-HOWTO.md)）の**手順2の産物**
- 実装は行っていない。実装手順は [LP-SPEED-MAX-IMPLEMENTATION-HANDOFF.md](LP-SPEED-MAX-IMPLEMENTATION-HANDOFF.md) を参照

## 司令塔による裏取りメモ（設計採用前に必ず読む）

Fableの設計はファイルパス・行数・数値を含めて概ね正確だったが、以下は司令塔が実地確認した結果、**訂正または補足**が必要:

- ✅ `index.html` 実測 1,376,609 bytes、`<img>` 44個、`loading="lazy"` 6箇所（すべて6コマ漫画パネル）— Fableの数値と一致。
- ⚠️ **6コマ漫画パネルは「既にファイル参照になっているのにbase64でも二重埋め込み」ではなく、`assets/comic/panel-N-web.jpg` と同一内容のJPGが `<img src="data:image/jpeg;base64,...">` として埋め込まれているのみ**。index.html内に `panel-1-web.jpg` 等へのファイル参照は0件（`grep -c "panel-\d" index.html` → 0）。実質的な結論（「既存ファイルをsrcにするだけで済む」）はFableの言う通りで有効だが、「二重埋め込み」という表現はミスリード。正しくは「原本ファイルは既にリポジトリにあるのでbase64を消してsrc参照に切り替えるだけでよい」。
- ⚠️ 行番号（L1497-1498＝brand-symbol/brand-logo、L1543-1551＝ヒーロー3キャラ、L2342-2357＝漫画パネル）はFableの実行時点のものと若干ズレる可能性がある（実測ではbrand-symbol/brand-logoのCSS定義がL82-83、data URI実体はL1497/1498/3186）。**実装時は行番号ではなくクラス名・`alt`属性・DOM構造で対象を特定すること**。
- ✅ `functions/api/diag/latest.ts` は既に `Cache-Control: no-store` 設定済み。`functions/api/diag/report.ts` と `functions/api/stripe-webhook.ts` は未設定（Fableの「確認して無ければ追加」という指摘どおり、対応が必要）。
- ✅ `_headers` ファイルは現状不存在。`wrangler.toml` は `pages_build_output_dir = "."` で全リポジトリが公開下（`assets/*.b64.txt` 台帳も含め実害なしとFableが判断、司令塔も同意）。
- ✅ `assets/konta-s.b64.txt` 等、base64生成元の台帪ファイルが実在することを確認済み（外部化スクリプトの突合先として使える）。
- 🔴→✅ **【一度誤った訂正をし、さらに裏取りして正しい結論に戻した】** 実装直後、GitHub Deployments APIで直近のデプロイが`vercel[bot]`によるものと出たため「本番はVercelだ」と誤判断し、`_headers`を`vercel.json`に置き換えた。ところが`vercel.json`をデプロイしても一切効果がなく（目印ヘッダーで検証、`x-lp-speed-test`が本番レスポンスに一度も現れなかった）、不審に思い本番レスポンスヘッダーを直接調べたところ `server: cloudflare` / `cf-cache-status` / `cf-ray` / `nel`（Cloudflare Network Error Logging）が揃って返ってきた。**実際に`soushin-suggest.link`ドメインを配信しているのはCloudflare Pagesであり、`wrangler.toml`の記述が正しかった。** GitHub上の`vercel[bot]`デプロイは、カスタムドメインには紐付いていない別経路（誤って有効化されたVercel連携か、未使用のプレビュー環境）だったと推測される。**教訓: デプロイ基盤の特定は「どのボットがGitHubにデプロイを記録しているか」ではなく「本番ドメインへの実リクエストのレスポンスヘッダー（server, cf-*, x-vercel-*等）」で判定すること。** `vercel.json`は削除し、`_headers`を復元して正式採用した（コミット参照は本ファイル末尾）。

---

## A. 理想の体験フロー

### 判断の前提: 会議の批判役（groq/gpt-oss-120b）が刺した反証への正面回答

批判役の主張は「Cloudflare Pagesのエッジキャッシュは短期（目安2h）なので、リピート訪問の多くがキャッシュミスになり、毎回1.4MBのHTMLを再取得する」。この主張は機構の説明としては半分不正確だが、結論としては正しい。設計はこの結論を受け入れ、外部化を採用する。

1. **エッジキャッシュの短期性そのものは主犯ではない。** Pagesの静的アセットはETag付きで配信され、ブラウザ側キャッシュが生きていれば条件付きGET→304で本文再転送は起きない。エッジからの追い出しはCloudflare内部のオリジン再取得（TTFB微増）に留まる。
2. **本当の穴は「デプロイ結合の全損無効化」である。** ETagはデプロイごとに変わる。このリポはLPの文言・CSSを高頻度で更新しており、**テキスト1文字の修正でも1.4MB全体（1年間変わっていないキャラ画像を含む）のキャッシュが無効化され、全再取得になる**。さらにiOS Safari等はブラウザキャッシュの追い出しが早く、304前提も安全側に立てない。つまり「単一HTML＝リクエスト数ゼロで有利」という擁護は、(a) 初回訪問は無条件に1.4MBのダウンロード完了を待ってからしか画像が出ない、(b) リピート訪問もデプロイを1回でも跨げば全額払い直し、の二重の意味で成立しない。
3. **したがってbase64維持案は棄却、外部ファイル化＋`_headers`長期キャッシュを採用する。** HTML（差分だけ変わる部分）と画像（ほぼ不変の部分）のキャッシュ寿命を分離でき、デプロイ無効化の爆風半径がHTML約210KB（Brotli後 推定40〜50KB）に縮む。画像はファイル名を内容変更のたびに変える運用にして「実質リクエストすら発生しない」状態にする。

### 初回訪問（改善後）

1. HTML本文 約210KB（Brotli圧縮後 推定40〜50KB）が届く。ダウンロード・パース開始が大幅に前倒し。
2. CSSはインラインのままなのでFCP（テキスト・レイアウト描画）は即時。現状の長所を維持。
3. above-the-fold画像5枚（ヘッダーロゴ2枚＋ヒーロー3キャラ、計 推定約120KB）が `fetchpriority` と `preload` で並列取得され、LCP確定。
4. 残り38枚（漫画6枚含む）は `loading="lazy"` でスクロールに応じて取得。初回の必須転送量は「1.37MB一括」から「約50KB＋above-fold画像約120KB」へ。

### リピート訪問（改善後）

- デプロイを跨がない場合: HTMLは304（ヘッダのみ）、画像は `immutable` によりネットワークリクエスト自体が発生しない。
- **デプロイを跨いだ場合（このリポでは高頻度）**: HTMLのみ約40〜50KB再取得。画像はファイル名が変わらない限り全てブラウザキャッシュヒット。**ここが批判役の穴を塞ぐ核心**: エッジ追い出しもデプロイも、画像バイトの再転送を引き起こさない。

---

## B. 統合アーキテクチャ（コンポーネント4個）

```
[1] HTML本体 (index.html)
    テキスト・インラインCSS/JSのみ、約210KBに減量。短寿命キャッシュ(must-revalidate)。
      │ <img src="/assets/..."> 参照
      ▼
[2] 画像配信層 (assets/**)
    既存の原本PNG/JPGをそのまま正とする。内容変更時はファイル名も変える運用。長期キャッシュ(immutable)。
      ▲
      │ キャッシュ方針を宣言
[3] キャッシュ層 (_headers ＋ Pagesデフォルト)
    /assets/* = 1年immutable ／ HTML = max-age=0 must-revalidate ／
    /api/* はFunctionsコード側でno-store（_headersはFunctions応答に効かない）。

[4] 変換・検証工程 (scripts/ 単発スクリプト＋目視ゲート)
    一度きりのbase64→ファイル参照置換スクリプト＋前後のピクセル差分検証。
    ビルドツールは導入しない。デプロイフローは現状のまま（git push）。
```

[4]は継続的なビルド工程ではなく**一度実行して捨てる移行ツール**。実行後の運用は今まで通り「HTML1ファイルを直接編集してpush」であり、会議の「素のHTML1ファイル運用を崩さない」判断に適合する。

---

## C. 具体機構

### C-1. 画像の外部参照化

45枚の優先順位付き扱い:

| 層 | 対象 | 処置 |
|---|---|---|
| LCP/above-fold（5枚） | ヘッダー `brand-symbol`/`brand-logo`、ヒーロー3キャラ | 外部化。`loading`属性は付けない（eager維持）。`decoding="async"`付与。ヒーロー中央キャラのみ`fetchpriority="high"`＋`<head>`に`<link rel="preload" as="image" href="...">` |
| 6コマ漫画（6枚） | `.comic-panel img`（見出し「6コマで見る」の直後） | `src`を既存の`/assets/comic/panel-N-web.jpg`に置換するだけ。**新規ファイル作成ゼロ・バイト同一**。`loading="lazy"`は既に付与済みなので変更不要 |
| below-the-fold（34枚） | 残る全キャラ・UIプレビュー | 外部化＋`loading="lazy" decoding="async"`付与 |
| favicon/apple-touch-icon（2個） | `<head>`内のdata URI | 既存ファイル参照に置換（無ければ`assets/`から書き出す） |

置換の機械化（一度きりの移行スクリプト、Node製・PowerShell日本語問題を回避）:

```
scripts/externalize-inline-images.mjs
```

処理: (1) `index.html`から`data:image/...;base64,`を全抽出しSHA-1化 → (2) `assets/**/*.b64.txt`（生成元台帳が既に実在）と突合して原本ファイルを特定 → (3) 台帳に無い分だけ`assets/inline/<意味名>-<hash8>.png`として書き出し → (4) `--write`指定時にsrc置換と`loading`/`decoding`属性付与を実施、置換対応表を`scripts/externalize-map.json`に出力。実行は`node scripts/externalize-inline-images.mjs --write`の1回。以後このスクリプトは運用に登場しない。

**必須の同時処置（CLS防止）**: 外部化した全`<img>`に原寸`width`/`height`属性を付与する（表示サイズはCSSが握っているのでレイアウトは不変、遅延到着時の枠確保のみが目的）。

### C-2. `_headers`ファイル（Cloudflare Pages採用・確定）

> 実装中に一度「本番はVercel」と誤判断し`vercel.json`に置き換えたが、本番レスポンスヘッダー（`server: cloudflare`等）で実機検証した結果、実際の配信元はCloudflare Pagesと確定。`_headers`が正しい実装手段。上記「司令塔による裏取りメモ」参照。

リポジトリ直下に新規作成:

```
# _headers — Cloudflare Pages カスタムヘッダ
# 画像・静的アセット: 内容を変えるときは必ずファイル名を変える運用とセット
/assets/*
  Cache-Control: public, max-age=31536000, immutable

# HTML(トップ): デプロイ即時反映を維持しつつブラウザに条件付き再検証させる
/
  Cache-Control: public, max-age=0, must-revalidate
/index.html
  Cache-Control: public, max-age=0, must-revalidate
```

注意点:
- **`_headers`はFunctions（`/api/*`）の応答には適用されない**（Cloudflare仕様）。動的APIのno-storeはTSコード側の責務。現状 `functions/api/diag/latest.ts` は設定済み、**`functions/api/diag/report.ts`と`functions/api/stripe-webhook.ts`は未設定なので追加が必要**（司令塔裏取りで確認済みの実タスク）。

### C-3. immutable運用ルール

`immutable`を付ける以上、**画像の内容を変えるときはファイル名を変える**（例: `link-s.png` → `link-s-v2.png`）。キャラ画像は事実上不変なので運用負荷はほぼゼロだが、このルールを`_headers`のコメントと`HANDOFF-next-session.md`に明記する。

### C-4. CSS/JSの軽量化

**minify・バンドルはやらない**。テキスト部は計約85KBで、Cloudflare Pagesが自動でBrotli圧縮するため転送量は既に推定20KB前後。minifyで削れるのは圧縮後数KBであり、ソース可読性（AIと人間が直接編集する運用の生命線）を失う代償に見合わない。全体重量の95%以上は画像であり、テキスト最適化はこのLPでは誤った戦場。やるのは属性付与（`decoding="async"`、`fetchpriority`、`width`/`height`）のみ。

### C-5. WebP化（第2フェーズ・任意）

MVP完了後に効果測定してから判断。やる場合は**PNGはロスレスWebPのみ**（ピクセル完全一致＝見た目リスクゼロ）。漫画JPGの非可逆WebP化は視覚差分が原理上ゼロにならないため優先度を下げる（E参照）。`srcset`/`<picture>`は導入しない（キャラ画像は表示サイズ固定・小サイズで出し分けの利得がない）。

---

## D. MVP

**MVP = 「6コマ漫画6枚のbase64を既存`/assets/comic/panel-N-web.jpg`参照に置換」＋「`_headers`新設」＋「未設定APIエンドポイント2件へのno-store追加」。**

選定理由:
- HTML 1.37MB → 約0.69MB（**50%減**）が、新規ファイル作成ゼロ・スクリプト不要・手作業6行の置換で得られる。参照先は既にリポ内にあり、埋め込みbase64の生成元そのものなのでバイト同一＝視覚差分は原理的にゼロ。
- 該当6枚は既に`loading="lazy"`済みなので、属性変更すら不要。CLS対策の`width`/`height`付与だけ行う。
- `_headers`は6行程度のテキストファイル追加のみで、以後の全外部化施策の受け皿になる。
- 工数: 30分以内。ロールバックは`git revert`一発。

残り39枚の外部化（C-1のスクリプト実施）は第2段。効果測定（PageSpeed Insightsの前後比較）でMVPの成果を確認してから進める。

**やらなくていい過剰施策**: minify／バンドル、Service Workerプリキャッシュ、Critical CSS抽出、`srcset`レスポンシブ画像、AVIF、HTTP/2 Server Push系の小細工。

---

## E. 捨てた案と理由

| 案 | 理由 |
|---|---|
| base64維持＋HTML長期キャッシュ | 批判役の指摘どおり不成立。デプロイ高頻度のリポでHTMLを長期キャッシュすると文言修正が反映されず、短期キャッシュだと毎デプロイ1.4MB全損。分離不能な構造自体が欠陥 |
| ビルドツール（Vite/webpack）導入 | 会議判断に同意。「HTML1ファイルを直接編集」という運用がこのプロジェクトの編集速度の源泉であり、ビルド工程の常設はデプロイ事故の新しい面を開く |
| Cloudflare Polish / Cloudflare Images | Polishは有料プラン依存かつHTML内のdata URIには効かない。外部化後なら効き得るが、ロスレスWebP自前変換で足りる範囲に外部サービス依存を増やさない |
| ハイブリッド案（LCP1枚だけ外部化、残りbase64維持） | 折衷の利点がない。残したbase64がHTML本文に居座る限り「デプロイごとに全画像分を再転送」する構造欠陥が解消されない |
| CSS/JS minify | C-4のとおり。Brotli後の削減数KBに対し可読性喪失の代償が大きい |
| Service Worker precache | 静的LPに対して過剰。更新伝播バグ（stale表示）という新種の「見た目が壊れた」を持ち込むリスクが本末転倒 |

---

## F. 地雷と回避策

1. **CLS（レイアウトガタつき）の新規発生 — 最大の見た目リスク。** base64は本文と同時に届くためガタつかないが、外部化するとlazy画像の遅延到着で枠が潰れて→開く挙動が出得る。回避: 外部化する全`<img>`に原寸`width`/`height`を必ず付与（C-1）。合格基準: Lighthouse CLSが施策前後で悪化ゼロ。
2. **above-foldへの`loading="lazy"`誤付与。** ヒーロー画像に付けるとLCPが逆に悪化する。回避: brand-symbol/brand-logo・ヒーロー3キャラには付けない。スクリプトの置換対象からこの5枚を明示的に除外リスト化する。
3. **「見た目revert文化」への防衛線。** 本設計の第1〜2段は全てバイト同一の画像を参照方式だけ変えるため視覚差分は原理的にゼロだが、証拠を残す: ブランチ＋Pagesプレビューデプロイでbefore/afterのフルページスクリーンショットをピクセル比較し、reality-checkerに判定させてからmainへ。**唯一視覚差分があり得るのは第3フェーズの漫画JPG非可逆WebP化であり、これは「視覚リスクあり」と明示の上、単独コミット・単独判断とする**（MVPには含めない）。
4. **`immutable`＋ファイル名据え置き更新。** 画像を差し替えたのにファイル名を変えないと、リピーターに最長1年古い画像が出続ける。回避: C-3の改名ルール。
5. **`_headers`がFunctionsに効かない誤解。** `/api/*`のno-storeはTSコード側の責務（C-2）。`report.ts`と`stripe-webhook.ts`への追加が実タスクとして残っている（司令塔裏取りで確認）。
6. **`pages_build_output_dir = "."`の全公開。** `assets/**/*.b64.txt`（移行の突合台帳）も公開下にあるが実害はない。移行完了後も台帳は削除しない（置換対応の監査証跡として残す）。
7. **Windows/OneDrive環境。** 日本語パス上での一括置換はPowerShell経由にしない。移行スクリプトはNode（`fs`直読み書き・UTF-8明示）で書き、実行後に`git diff --stat`で`index.html`の減量幅（期待値: 約1.15MB減）を必ず確認する。
8. **効果の過大約束をしない。** 「304で再転送ゼロ」はブラウザキャッシュ生存が前提であり、iOS Safariの積極的追い出しでは初回相当になる。それでも改善後の初回コストは約50KB＋可視画像分であり、現状の1.37MB一括より常に優位。測定はPageSpeed Insights（モバイル）のLCP/CLS/転送量を施策前に1回採取してから着手する（beforeの証拠がないと改善を証明できない）。
