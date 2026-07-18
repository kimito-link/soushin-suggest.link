# 設計書: `/shindan/` — 診断JSONローカル変換ビューア

> 設計=Fable(claude-fable-5) ／ 対象: `soushin-suggest.link` (Cloudflare Pages静的サイト)
> 前提の正本: `_docs/SELF-DIAGNOSTIC-INSTRUMENTATION-DESIGN.md`（計器側・実装済み・変更しない）
> 踏襲思想: `web-ios-android/docs/ai-rules/04_SELF_VERIFICATION.md` パターン2「嘘をつかない診断」・パターン6「メタ診断」
> 日付: 2026-07-16

## A. 理想の体験フロー

1. ユーザー「スクショが履歴に残らない」→ AI（またはLPのサポート文言）「`soushin-suggest.link/shindan/` を開いてください」
2. ページ最上部の「はじめての方へ」が3ステップだけを示す:
   - **①** タスクトレイの送信サジェストのアイコンを**右クリック**→「**診断情報をコピー**」を押す
   - **②** このページの貼り付け枠をクリックして **Ctrl+V**
   - **③** 出てきた結果を見る（AIに相談するときは「この結果をコピーしてAIに相談」ボタンを押して貼るだけ）
3. Ctrl+V した**瞬間**に（変換ボタンを押さなくても）カードが描画される。最上部に色付きの総合判定バー:
   - 🔴「異常の証拠あり: スクショが自己抑制で破棄されています」
   - 🟡「注意: 画像が却下されています（理由: サイズ超過）」
   - 🟢「異常の証拠なし（履歴登録の成功が観測されています）」
   - ⚪「**判定不能**: まだ観測がありません。問題の操作を1回行ってから、もう一度『診断情報をコピー』→貼り付けしてください」
4. AI相談ルート: 「この結果をコピーしてAIに相談」ボタン → 総合判定＋赤黄カードの文言＋元JSONが1テキストになってクリップボードへ。AIは人間可読の判定文と生カウンターの両方を1枚で受け取る。
5. 差分プロトコル（計器設計書A-5と同じ運用）: 同じページに**2回目を貼る**と、前回貼り付け（メモリ内のみ保持）との差分Δが各カードに小さく出て、「その1操作がどの経路を通ったか」が確定する。ページを閉じれば全部消える。

人間は色と日本語文で読む。AIはボタン1つで判定＋生JSONを受け取る。**同じ1ページが両方の目になる。**

## B. 統合アーキテクチャ（コンポーネント4個・全部1ファイル内）

```
/shindan/index.html（自己完結・依存ゼロ・外部通信ゼロ）
[1] 入力: <textarea> + pasteイベント
     extractJson(): 貼り付けテキストからJSONオブジェクトを寛容に抽出
     → DiagSnapshot(生オブジェクト)
[2] 知識: KEY_REGISTRY(計測点C-2表の写し) + RULES(判定関数の配列)
     → Card[]{id,label,value,level,message} + Verdict
[3] 描画: 総合判定バー + セクション別カードグリッド
     (状態/画像経路/スクショ直行便/テキスト経路/その他)
[4] 出力: 「AIに相談」ボタン = 判定テキスト+元JSONを整形してコピー

外部への矢印: ゼロ本（fetch/XHR/sendBeacon/WS/外部タグ不使用、
CSPメタタグで機械的にも遮断）
```

- **[1]→[2]→[3]** は純関数の一方通行。`prevSnapshot` 変数（JSファイルスコープのみ、localStorage不使用）が差分Δの材料。
- **[2] KEY_REGISTRY** が本設計の心臓。計器側C-2表の全キーを「ラベル・所属セクション・ファネル段」のメタ付きで持つ。JSONに**現れなかった既知キーは「未観測」**として必ずグレーカードで出す（後述D）。
- サーバー側コンポーネントは**ゼロ**。Cloudflare Pagesは `/shindan/index.html` を置くだけで配信する（`_routes.json` は `/api/*` のみFunctionsに回す設定なので追加設定不要）。

## C. 具体機構

### C-1. HTML構造（骨格）

```html
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<!-- 送信機能の機械的封印: 接続先ゼロ・外部スクリプトゼロをブラウザに強制させる -->
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; form-action 'none'; base-uri 'none'">
<meta name="robots" content="noindex">
<title>送信サジェスト 診断ビューア</title>
<style>/* 全CSSインライン(下記C-5) */</style>
</head>
<body>
  <header>
    <h1>送信サジェスト 状態</h1>
    <span id="verMeta">— 貼り付けるとバージョンが表示されます —</span>
  </header>

  <section id="intro" class="card intro"><!-- はじめての方へ(3ステップ) -->
    <p>🔒 このページは貼り付けた内容を<b>どこにも送信しません</b>。
       送信するコードそのものが入っていません（詳しくは下の「プライバシー」）。</p>
  </section>

  <section id="input">
    <textarea id="paste" placeholder='ここに Ctrl+V（例: {"app":"soushin-suggest",...}）'></textarea>
    <button id="btnRender">表示する</button><!-- pasteイベントで自動描画するが保険で置く -->
  </section>

  <div id="verdict" class="verdict gray">まだ何も貼り付けられていません</div>
  <button id="btnShare" class="share" hidden>この結果をコピーしてAIに相談（原因が全部わかる1枚）</button>

  <main id="cards">
    <section data-sec="state"><h2>いまの状態</h2><div class="grid"></div></section>
    <section data-sec="imgFunnel"><h2>画像の通り道（コピー→履歴）</h2><div class="grid funnel"></div></section>
    <section data-sec="shot"><h2>スクショ直行便（サイドボタン）</h2><div class="grid"></div></section>
    <section data-sec="textFunnel"><h2>テキストの通り道</h2><div class="grid"></div></section>
    <section data-sec="other"><h2>その他の観測値</h2><div class="grid"></div></section>
  </main>

  <section id="privacy" class="card"><!-- プライバシー説明(C-6) --></section>
  <script>/* 全JSインライン(C-2〜C-4) */</script>
</body>
</html>
```

君斗りんく状態ページの視覚言語の翻案:
- **タイトルバーのver表示** → `#verMeta` に貼り付け後 `v1.12.0・稼働 2時間3分・監視ON・履歴5件` を出す（自動更新は無い製品なので「最終更新/2秒ごと」は**コピー時刻基準の注記**に置換: 「※すべての数値は『診断情報をコピー』を押した瞬間のスナップショットです」）
- **グラデーションの共有ボタン** → `#btnShare` をそのまま踏襲（貼り付け成功時のみ表示）
- **総合判定バー** → `#verdict`（赤/黄/緑/グレーの4状態）
- **カードグリッド+色分け** → セクション別グリッド。画像ファネルだけは横並びの**段付きカード**（`evtImage → capImage → pushImage` を→つなぎ、却下系はその下にぶら下げる）にして「どの段で消えたか」を形で見せる
- **タブ複数・2秒自動更新** → 採用しない（F参照）

### C-2. 入力の寛容パース

```js
function extractJson(text) {
  // AIチャット等から前後の文章ごと貼られても救う: 最初の '{' から括弧バランスで切り出す
  const s = text.indexOf('{');
  if (s < 0) return { err: 'JSONが見つかりません。トレイメニューの「診断情報をコピー」を押してから貼り付けてください。' };
  let depth = 0;
  for (let i = s; i < text.length; i++) {
    if (text[i] === '{') depth++;
    else if (text[i] === '}' && --depth === 0) {
      try { return { obj: JSON.parse(text.slice(s, i + 1)) }; }
      catch (e) { return { err: 'JSONの形が崩れています。もう一度コピーし直してください。' }; }
    }
  }
  return { err: 'JSONが途中で切れています。全文をコピーし直してください。' };
}
// 受入ガード: obj.app === 'soushin-suggest' でなければ「送信サジェストの診断JSONではないようです」
```

### C-3. KEY_REGISTRY（計器C-2表の写し。**この一覧が唯一の正**）

```js
const KEY_REGISTRY = {
  // sec: 表示セクション / label: 人間向け名 / kind: 'ok'(伸びてよい) | 'rej'(却下) | 'info'
  selfSuppress: { sec:'imgFunnel', label:'自己書込の抑制',        kind:'info' },
  evtImage:     { sec:'imgFunnel', label:'画像コピーを検知',       kind:'ok', stage:1 },
  capImage:     { sec:'imgFunnel', label:'画像の取り込み実行',     kind:'ok', stage:2 },
  pushImage:    { sec:'imgFunnel', label:'画像が履歴に登録',       kind:'ok', stage:3 },
  rejUserImage: { sec:'imgFunnel', label:'却下: 操作なしコピー',   kind:'rej' },
  rejSource:    { sec:'imgFunnel', label:'却下: 除外アプリから',   kind:'rej' },
  rejDib:       { sec:'imgFunnel', label:'却下: 画像データ取得失敗', kind:'rej' },
  rejSize:      { sec:'imgFunnel', label:'却下: サイズ上限超過',   kind:'rej' },
  rejMinPx:     { sec:'imgFunnel', label:'却下: 画像が小さすぎ',   kind:'rej' },
  shotDirect:   { sec:'shot',      label:'スクショ直接登録 成功',  kind:'ok' },
  shotDirectRej:{ sec:'shot',      label:'スクショ直接登録 却下',  kind:'rej' },
  shotFail:     { sec:'shot',      label:'スクショ撮影 失敗',      kind:'rej' },
  evtText:      { sec:'textFunnel',label:'テキストコピーを検知',   kind:'ok', stage:1 },
  capText:      { sec:'textFunnel',label:'テキストの取り込み実行', kind:'ok', stage:2 },
  pushText:     { sec:'textFunnel',label:'テキストが履歴に登録',   kind:'ok', stage:3 },
  rejUserText:  { sec:'textFunnel',label:'却下: 操作なしコピー',   kind:'rej' },
  rejEmptyLong: { sec:'textFunnel',label:'却下: 空または長すぎ',   kind:'rej' },
  evtClear:     { sec:'other',     label:'クリップボードのクリア', kind:'info' },
  watchOff:     { sec:'other',     label:'監視オフ中に捨てた数',   kind:'info' },
  ignoreFormat: { sec:'other',     label:'パスワード形式を除外',   kind:'info' },
};
```

JSONの `counters` にあってREGISTRYに無いキー → 「その他の観測値」にグレーで**そのまま表示**（新しいアプリ版が新カウンターを増やしても壊れない前方互換。エラーにしない）。

### C-4. カード判定表（実キー名に対する具体ロジック）

カードの色は4値: `red`（異常の証拠）/ `yellow`（注意）/ `green`（正常動作の**証拠**）/ `gray`（未観測=判定材料なし）。
表記規約: `c(k)` = counters[k] が存在すればその `{n, agoMs}`、無ければ `null`。`RECENT = 10000`(ms)。

| # | 判定名 | 条件（実キー） | 出すカード/文言 |
|---|---|---|---|
| R1 | **スクショ自己抑制の疑い** | `c(selfSuppress)` があり `agoMs < RECENT`、かつ `c(shotDirect)` と `c(pushImage)` のどちらも「無い or `agoMs` がそれより古い」 | 🔴 selfSuppressカード:「直近のクリップボード書込が自己抑制で破棄され、履歴に載っていません。サイドボタンのスクショが履歴に残らない典型症状です」 |
| R2 | **撮影失敗** | `c(shotFail).n > 0` | 🔴 shotFailカード:「スクリーンショットの撮影自体が {n}回 失敗しています（マルチモニタ構成の変更直後などに発生）」 |
| R3 | **監視オフ** | ルート `watchOn === 0` | 🔴 状態カード:「クリップボード監視がオフです。トレイメニューから監視を再開してください（履歴に載らない直接原因）」 |
| R4 | **理由なき消失（計測漏れ/未知経路）** | `c(capImage).n > 0` かつ `c(pushImage)` が無い、かつ画像系 `rej*`（rejUserImage/rejSource/rejDib/rejSize/rejMinPx）が**すべて無い** | 🔴 合成カード:「取り込みは実行されたのに、履歴登録も却下理由も記録されていません。**計測漏れか未知の経路**の可能性があります（このページやアプリのバグとして報告してください）」※04文書パターン2「内訳ゼロの失敗＝呼び出し自体が起きていない」の適用 |
| Y1 | **ガード却下（スクショ）** | `c(shotDirectRej).n > 0` | 🟡 shotDirectRejカード:「スクショが {n}回、サイズ制限（上限 {cfg.imgMaxMB}MB・最小 {cfg.imgMinPx}px）で履歴に登録されませんでした。クリップボードには載っています」 |
| Y2 | **却下が主流** | 画像系: `rejUserImage/rejSource/rejDib/rejSize/rejMinPx` のいずれか `n > 0` かつ (`c(pushImage)` 無し or `pushImage.n` が却下合計より小さい) | 🟡 各rejカード:「画像が『{label}』の理由で {n}回 却下されています」＋rejSourceには「除外元アプリの設定(sites.ini)を確認」等の一言 |
| Y3 | **テキスト経路の同型** | `rejUserText` / `rejEmptyLong` で Y2 と同型 | 🟡 同型文言 |
| Y4 | **バージョン差** | ルート `ver` がこのページの `KNOWN_VER`（実装時に固定）より新しい | 🟡 verメタ横:「このページが知らない新しい版です。未知のカウンターは『その他』に生表示します」 |
| G1 | **成功の証拠** | `c(pushImage).n > 0` / `c(pushText).n > 0` / `c(shotDirect).n > 0` | 🟢 各カード:「{n}回 履歴に登録済み（最後はコピーの {agoMs→秒} 前）」 |
| G2 | **抑制は正常動作でもある** | `c(selfSuppress)` があるが R1 非成立（`shotDirect` が同等以上に新しい） | 🟢 selfSuppressカード:「自己書込の抑制 {n}回 — 貼り付け・診断コピー由来の正常な動作です」 |
| N1 | **未観測** | REGISTRYの既知キーが `counters` に**存在しない** | ⚪ グレーカード: 値欄は「—」、下に小さく「**まだ観測なし**（0回とは限りません。D参照の文言）」 |
| N2 | **info系** | `evtClear`/`watchOff`/`ignoreFormat` は存在すれば数値表示のみ | ⚪→数値ありなら無色（白）カード。ただし `watchOff.n > 0` かつ `watchOn===1` は 🟡「過去に監視オフの期間があり {n}件 取りこぼしています」 |

ファネル不等式の扱い（計器設計書D-4の継承）: `evtImage ≧ capImage` はデバウンス合流で**恒常的に成立する正常**。等式チェックは実装しない。「`evtImage.n` と `capImage.n` の差」は表示するがそれ自体を異常判定に使わない（カードに「※検知は連打で合流するため取り込みより多くて正常」と注記1行）。

### C-5. 総合判定バーの集約ルール（明示）

```js
function aggregate(cards, snapshot) {
  const reds    = cards.filter(c => c.level === 'red');
  const yellows = cards.filter(c => c.level === 'yellow');
  const greens  = cards.filter(c => c.level === 'green');
  if (reds.length)    return { cls:'red',    text:`異常の証拠あり: ${reds.map(c=>c.short).join('・')}` };
  if (yellows.length) return { cls:'yellow', text:`注意: ${yellows.map(c=>c.short).join('・')}` };
  if (greens.length)  return { cls:'green',  text:'異常の証拠なし（履歴登録の成功が観測されています）' };
  // 全カードが未観測 → 絶対に緑にしない
  return { cls:'gray', text:'判定不能: まだ観測がありません。問題の操作（スクショ等）を1回行ってから、もう一度「診断情報をコピー」して貼り直してください。' };
}
```

- **1つでも赤→全体赤**。赤ゼロで黄あり→黄。赤黄ゼロでも、**緑になるのは成功カウンター(G1)が1つ以上あるときだけ**。
- `uptimeMs < 60000` のときはバーの直下に注記:「起動から{秒}秒しか経っていません。カウンターが少ないのは自然です」。

### C-6. プライバシー明示（ページ内文言 + コードレベル保証）

ページ下部の固定セクション（3行で言い切る）:

> **🔒 プライバシー**
> - 貼り付けた内容は**このブラウザの中だけ**で処理されます。サーバーへの送信は行いません——このページには**送信するコード自体が存在しません**（通信を全面禁止するCSP設定入り。開発者ツールのNetworkタブで検証できます）。
> - 保存もしません。ページを閉じれば消えます（Cookie・localStorage不使用）。
> - そもそも診断JSONにはカウンターと設定値しか入っておらず、コピーした文章・画像・アプリ名は含まれません（アプリ側の仕様）。

コードレベル保証（実装チェックリスト）:
1. `fetch` / `XMLHttpRequest` / `navigator.sendBeacon` / `WebSocket` / `EventSource` を1箇所も書かない
2. 外部 `<script src>` / `<link href>` / Webフォント / 画像URLゼロ（画像が要るなら `data:` URI）
3. C-1のCSPメタタグ: `default-src 'none'; connect-src 'none'; form-action 'none'` — **将来の編集ミスや、Cloudflare側のスクリプト自動注入（Web Analytics等）もブラウザが遮断**する二重ロック
4. `<form>` タグ不使用（誤送信経路の物理排除）、`<meta name="robots" content="noindex">`（診断ページは検索流入不要）
5. 検証手順として「デプロイ後にDevTools Networkタブを開いて貼り付け→リクエスト0件を確認」をreality-checkerの手順に入れる

### C-7. 「AIに相談」ボタンの出力形式

```
[送信サジェスト診断 v1.12.0 / 稼働2時間3分 / 監視ON / 履歴5件]
総合判定: 異常の証拠あり: スクショ自己抑制の疑い
🔴 自己書込の抑制: 直近のクリップボード書込が自己抑制で破棄され…
⚪ 画像が履歴に登録: まだ観測なし
--- 生データ ---
{"app":"soushin-suggest","ver":"1.12.0", ...元JSONそのまま... }
```

人間可読の判定文＋生JSONを常に**両方**含める（AIが判定文を鵜呑みにせず生カウンターで裏取りできる＝ビューア自身の判定バグに対する保険）。

## D. 偽陽性潰し — 「0=正常」と「0=計測漏れ」の区別設計

計器側の実装事実が味方になる: `DiagBump()` されたキーだけが `ClipDiag` に入るため、**`BuildDiagText()` のJSONに `n:0` は絶対に現れない**。つまりページが受け取る状態は2値しかない:

| JSON上の状態 | 意味 | ページの扱い |
|---|---|---|
| キーが存在し `n ≥ 1` | その分岐は少なくとも1回**実際に**通った | 判定表C-4を適用（緑になれるのはここだけ） |
| キーが存在しない | 「1回も起きていない」**または**「その版に計測点が無い/計測漏れ」— 区別不能 | ⚪グレー「まだ観測なし」。**緑にも赤にも塗らない** |

この上に3枚の防壁を置く:

1. **緑は加点式**: 「悪い証拠が無いから緑」を全面禁止し、緑は `pushImage`/`pushText`/`shotDirect` 等の**成功の実在**だけが作れる（C-5）。全滅グレーのときの総合判定は「正常」ではなく「判定不能＋次にやること（操作1回→再コピー）」を出す。これが04文書パターン2「試みたでなく実際に起きただけを数える」のビューア側の対応物。
2. **内訳ゼロの失敗検出（R4）**: `capImage` はあるのに `pushImage` も画像系 `rej*` も無い、という「理由なき消失」を専用の赤カードにする。これは症状の診断ではなく**計器そのものの穴（計測漏れ・未知経路）の検出**であり、「診断が黙って嘘をつく」ことを構造的に防ぐ。
3. **文脈による0の重み付け**: `uptimeMs` と `ver` を必ず読み、(a) 起動直後なら「未観測は自然」と注記、(b) ページの `KNOWN_VER` とアプリ `ver` が食い違うなら「この版に該当カウンターが無い可能性」を未観測カードの注記に加える。未観測の解釈をユーザー任せにせず、ページが候補を言語化する。

加えて**メタ診断（パターン6の縮小適用）**: `scripts/check-shindan-keys.mjs`（約30行・任意だが推奨）を置き、`dist/soushin-suggest.ahk` から `DiagBump("...")` のキーを正規表現抽出して `shindan/index.html` 内の `KEY_REGISTRY` と集合比較する。アプリに計測点を足したのにページの一覧を更新し忘れる事故（＝新カウンターが永久に「その他」に落ちる）を機械検出できる。ランタイムコストゼロ。

## E. MVP（1つだけ作るなら）

**`shindan/index.html` 1ファイル**（新規・自己完結・依存ゼロ・想定500行前後）に以下だけ:

- はじめての方へ3ステップ ＋ 貼り付け欄（pasteイベントで即描画）
- KEY_REGISTRY全キー分のカードグリッド（既知キーは未観測でも必ずグレーで出す）
- 判定ルール R1〜R4 / Y1 / G1 / N1 と総合判定バー（C-5の集約そのまま）
- プライバシー3行＋CSPメタタグ
- 「AIに相談」コピーボタン

**入れない**: 差分Δ表示（2回貼りは「上書き描画」でも運用上は目視比較できる。Δは次の増分）、テキスト経路の細分判定（Y3は文言だけ雑でよい）、メタ診断スクリプト（推奨だがMVP外）、LP `index.html` からのリンク追記（1行なので実装時についでに、程度）。

## F. 捨てた案と理由

> **2026-07-18追記**: 下記「アプリ→サーバーへ診断を自動送信」の却下判断は、ユーザーの明示同意により
> 覆された。現行の正本は `_docs/SHINDAN-AUTO-SEND-DESIGN.md`。本ページのオフライン完結・非永続の
> 説明・貼り付けUIは、後方互換の入口として引き続き有効(自動送信は追加の入口であり置き換えではない)。

| 案 | 捨てた理由 |
|---|---|
| アプリ→サーバーへ診断を自動送信し `/shindan/` がライブ表示 | ~~合意済みの却下。オフライン完結・非永続という製品の看板に反する。アプリにネットワークコードが1行でも入ると「軽量・安心」の説明が崩れる~~ (2026-07-18: 却下を覆し `SHINDAN-AUTO-SEND-DESIGN.md` として再設計) |
| 君斗りんく型のフル移植（タブ複数・2秒自動更新・更新ms表示） | データ源が「手動コピーの静止スナップショット」なので自動更新は意味を持たない。タブで見せ分けるほどの情報量もない（カウンター約20個）。過剰設計の典型 |
| 既存 `index.html`（668KB）内にセクション/モーダルとして追加 | 巨大単一ファイルの編集リスクと668KBのロードを診断ユーザーに払わせる。LPのCSP方針とも絡む。URLで「ここを開いて」と言える独立性が診断導線の価値そのもの |
| URLフラグメント共有（`/shindan/#<base64 JSON>`） | フラグメントはサーバーに飛ばないが、履歴・共有・スクショ経由で漏れる面が増える。「URLに個人データを載せない」原則にも接触。貼り付けで足りる |
| JSON以外の入力（.jsonファイルのドラッグ&ドロップ） | クリップボード管理アプリの診断がクリップボード経由で完結するのは導線として同型で美しい。入力面を増やすとテスト面も増える |
| チャートライブラリ/フレームワーク（Chart.js, Vue等） | 描くのは色付きカードと数字だけ。外部依存は「外部と通信しない」保証の検証コスト（サプライチェーン監査）を無限に増やす。vanillaで十分 |
| localStorageに前回分を保存して恒久差分 | 「保存しません」というプライバシー宣言を単純に保つ方が価値が高い。差分はページ滞在中のメモリ変数で足りる |
| ページ内でカウンターの等式検証（evt=cap+rej…） | 計器設計書G-5の地雷の再来。デバウンス合流で恒常的に破れ、常時鳴る警告は信頼を失う。不等式と「理由なき消失(R4)」だけに絞る |

## G. 地雷と回避策

1. **「0=緑」への回帰圧力** — 実装中「グレーばかりで寂しいから緑にしよう」という誘惑が必ず来る。緑の条件を `kind:'ok' && n>0` にコード上で固定し、集約関数(C-5)に「greenはgreensの実在時のみ」とコメントで根拠を書き残す。
2. **貼り付けテキストの汚れ** — チャットからの再コピーで前後に文章・コードフェンスが付く。C-2の括弧バランス抽出で救い、失敗時は「何をすればよいか」を含むエラー文（コピーし直し手順）を出す。`console.error` に黙って落とさない。
3. **`agoMs` の時制誤読** — `agoMs` は**コピーした瞬間**からの遡りであり、ページで `Date.now()` と混ぜて再計算してはいけない。表示は必ず「コピー時点で◯秒前」と書く。判定(R1)も `agoMs` 同士の比較のみで行う。
4. **CSPメタタグが自分のインラインJSを殺す** — `script-src 'unsafe-inline'` を欠くと真っ白ページになる。デプロイ後にDevToolsでConsoleエラー0件＋Network0件の両方を確認する（reality-checker手順に明記）。Cloudflare Web Analyticsの自動注入が有効な場合、CSPが遮断してConsoleに警告が出るのは**正常**（遮断こそ仕様）。
5. **バージョンスキュー** — アプリが先に進んでカウンターが増える/名前が変わる。未知キーは「その他」に生表示（エラーにしない）、既知キー欠落は「未観測」扱いなので、**どちら向きのズレでもページは壊れない**。恒久対策はDのメタ診断スクリプト。
6. **差分プロトコルとアプリ再起動の混線**（Δを実装する場合）— 2枚目の `uptimeMs` が1枚目より小さければアプリが再起動しておりカウンターはリセット済み。Δ表示せず「アプリが再起動されています。もう一度2枚とも取り直してください」と出す。
7. **文字化け** — 日本語UIなので `<meta charset="utf-8">` 必須、ファイルはUTF-8(BOMなし)で保存。Windows側エディタのShift-JIS事故（グローバルルール既知の地雷）に注意。
8. **導線の孤立** — ページを作っても知られなければ存在しない。実装時に (a) LP `index.html` のサポート/FAQ近辺に1行リンク、(b) 将来のアプリ側 `Flash()` 文言（「診断情報をコピーしました。AIチャットまたは soushin-suggest.link/shindan/ に貼り付けてください」）への追記を別チケットとして起票。アプリ側変更は本設計のスコープ外なので**同時にやらない**。
9. **スコープ侵食** — `functions/api/`（Stripe）と `_routes.json` には触れない。`/shindan/` は静的配信のみで完結し、既存ルーティングに影響しないことを実装PRの説明に明記する。

## 実装後の検証手順（reality-checker向け）

1. ローカルで `shindan/index.html` を直接ブラウザで開く（file://でも動く=オフライン完結の証明）
2. 実機で「診断情報をコピー」→貼り付け→カード描画・総合判定の妥当性を目視
3. DevTools Network: 貼り付け前後を通してリクエスト0件（ドキュメント自身のGET以外）
4. XButton2短押し1回→再コピー→再貼り付けで `shotDirect`/`selfSuppress` カードが期待の色に変わること
5. わざと壊したJSON・無関係テキスト・他アプリのJSONを貼り、4パターンのエラー/拒否文言が出ること
6. 何も操作していない起動直後のJSONで総合判定が**グレー（判定不能）**であり、緑にならないこと

**新規ファイル**: `C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link\shindan\index.html`（必須・1ファイル完結）／ `scripts\check-shindan-keys.mjs`（推奨・メタ診断）。既存ファイルの変更はLPへのリンク1行のみ（任意）。
