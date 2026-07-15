# 設計書: 「操作の流れは、ひと筆書き。」セクション — マウス操作の統合フロー説明

> 設計=Fable(claude-fable-5) / 素材収集=会議ハーネス(汎用会議、5体召集・4/5成功) / 裏取り・事実訂正=司令塔Claude
> 日付: 2026-07-15 ／ council-fable 3段構えワークフローの手順2〜3の産物

## 背景

soushin-suggest.link（Windows常駐アプリ「送信サジェスト」）のLPで、マウス操作（右クリック長押し・
Ctrl+Enter・なぞってコピー）を、キャラクター（りんく・こん太・たぬ姉）を使って初心者でも迷わず
理解できるように再設計する。ユーザーからの「操作を試すとき迷う瞬間がある」というフィードバックが
出発点。既存の [`SIDEBUTTON-CLARITY-DESIGN.md`](SIDEBUTTON-CLARITY-DESIGN.md)（サイドボタン単体の
説明改善）とは別の、3操作の**統合フロー**を扱う新規セクション。

## 【重要】実装前に確定した事実訂正

Fableへの設計依頼時、司令塔が投げたお題文には
「①右クリック長押し=送信 ②Ctrl+Enter ③なぞって選択→自動コピー→**右クリックで貼り付け→
右クリック長押しで送信**」という**2アクション**の前提を書いてしまっていた。

しかし実際のindex.html本文（L1734, L1746, L2306）を確認したところ、
**「右クリック長押し」1回で「貼り付け＋送信（実行）」が同時に完了する**、が正しい挙動。
右クリックの単発クリックと長押しは別動作ではなく、「長押し」だけで完結する。

**→ 以下の設計は、この正しい挙動（2ステップ構成）に基づいて確定させたもの。**
Fableの原設計は3カード構成（なぞる／右クリック貼り付け／長押し送信を別カード）で出力されたが、
司令塔が2カード構成（なぞる／長押しで貼り付け+送信）に統合し直している。

## A. 理想の体験フロー

訪問者（マウス操作に不慣れな非エンジニア含む）の理解が、次の順で積み上がる。

1. **既存 `#features`「マウス1つに、4つの役割。」** で各ボタンの「役割表（what）」を見る
2. **新セクション（本設計）** で「その役割がどう繋がるか（how）」を、上から下へ1本の線として読む
   - STEP 1「なぞる＝コピー完了」→ 因果直結。「Ctrl+Cは押さない」がここで腑に落ちる
   - STEP 2「長押し＝貼り付けて送信」→ 終点。1アクションで完結することを明示。脇道チップで「Ctrl+Enterでも同じ」を知る
3. スクロールを続けると既存「how it feels」の before/after で「なぜ嬉しいか（why）」を追認する

各STEPにキャラクター1人が1行だけ添う（りんく=進行、たぬ姉=不安代弁）。読者は「操作名＝機能」の
等式を2つ覚えるだけで離脱できる。物理的な位置の説明（「ここを押す」）は一切登場しない。

## B. 統合アーキ（セクション構成・既存との関係）

- **新規セクション1つを追加**。既存セクションの置き換え・改修はしない。
- **挿入位置**: `#features`（mouse map）セクションの閉じ `</section>` 直後、「safety」（`効かせる場所は、選んでいます。`）セクションの直前。
  - grepアンカー: `grep -n '効かせる場所は、選んでいます' index.html` → その `<h2>` を含む `<section>` 開始タグの直前に挿入。
- **id**: `<section id="mouse-flow">`、eyebrow は `one stroke`（既存の英小文字eyebrow規約: mouse map / safety / how it feels に準拠）。
- 役割分担の明文化:
  - `#features` mouse map = ボタンごとの役割表（静的・辞書）— 触らない（`#side-button` アンカーと過去の修正を壊さないため）
  - `#mouse-flow`（新規）= 2操作の一筆書きの流れ（順序・因果）
  - 「how it feels」story = 効果の before/after — 触らない
- Ctrl+Enterは、STEP 2カード内の「べつルート」チップ（破線・muted色）として合流表示。独立STEPには昇格させない。

## C. 具体機構（文言・セリフ・レイアウト、実装可能な粒度）

### C-1. HTML（新規セクション全文。クラスは新規 `flow-*` 系で名前空間を分離）

```html
<section id="mouse-flow">
  <div class="wrap">
    <div class="section-head">
      <div class="section-eyebrow">one stroke</div>
      <h2>操作の流れは、ひと筆書き。</h2>
      <p class="lede">文章をなぞって、送り先で右クリック長押し。コピーも貼り付けも送信も、この一本の線の上にあります。</p>
    </div>
    <div class="flow-steps">

      <div class="flow-card">
        <div class="flow-num">1</div>
        <h3>なぞる＝コピー完了</h3>
        <p>文章をドラッグでなぞって離すだけ。その瞬間、コピーは終わっています。</p>
        <div class="flow-badges">
          <span class="story-hand-badge"><span class="emoji">🖱️</span>なぞる</span>
          <span class="flow-badge-skip"><span class="emoji">⌨️</span>Ctrl + C</span>
        </div>
        <p class="flow-note">Windows標準では「選択→Ctrl+C」の2段階。送信サジェストでは、なぞった時点でコピー済みです。</p>
        <div class="flow-char"><span class="who">りんく</span>なぞって離した瞬間、もうコピーされてるよ。</div>
      </div>

      <div class="flow-card">
        <div class="flow-num">2</div>
        <h3>長押し＝貼り付けて送信</h3>
        <p>送り先の入力欄で右クリックを0.35秒長押し。貼り付けと送信がこの1回で同時に終わります。</p>
        <div class="flow-badges">
          <span class="story-hand-badge"><span class="emoji">🖱️</span>右クリック長押し</span>
        </div>
        <div class="flow-alt"><span class="emoji">⌨️</span>キーボード派は Ctrl + Enter でも同じ送信ができます。</div>
        <div class="flow-char"><span class="who">たぬ姉</span>短い右クリックはいつものメニューのまま。長押しだけの反応だから誤爆しないの。</div>
      </div>

    </div>
  </div>
</section>
```

文言の要点:
- 2つの `<h3>` を **「操作＝機能」の等式形**に統一（なぞる＝コピー完了／長押し＝貼り付けて送信）。因果直結の会議収束点をそのまま見出し構造にする。位置説明ゼロ。
- 「長押し＝貼り付けて送信」は、実際のアプリ挙動（1アクションで完結）を正確に反映。
- `flow-badge-skip` は打ち消し線付きチップ。「いつものCtrl+Cは不要」を視覚対比で示す（Windows標準との対比＝アプリ固有機能の明示）。
- キャラは2カード構成に合わせ、りんく（STEP1・因果の言い切り）→たぬ姉（STEP2・不安代弁と解消）の2人体制。こん太は本セクションでは非登場（他セクションで既に役割を持っているため、無理に3人揃えない）。

### C-2. CSS（`</style>` 手前、または既存 `/* steps — 導入の流れ STEP 01-03 */` コメント直前に追記）

```css
/* one-stroke flow — 2 mouse ops as vertical step cards with connectors */
.flow-steps { display: flex; flex-direction: column; gap: 0; margin-top: 24px; max-width: 560px; }
.flow-card { position: relative; background: var(--panel-soft); border: 1px solid var(--line); border-radius: var(--radius); padding: 20px 18px 16px; }
.flow-card + .flow-card { margin-top: 34px; }
/* connector arrow between cards (the "one stroke") */
.flow-card + .flow-card::before {
  content: "↓"; position: absolute; top: -30px; left: 50%; transform: translateX(-50%);
  font-size: 18px; font-weight: 800; color: var(--accent);
}
.flow-num { position: absolute; top: -12px; left: 14px; width: 26px; height: 26px; border-radius: 50%; background: var(--accent); color: #fff; font-size: 13px; font-weight: 800; display: grid; place-items: center; }
.flow-card h3 { font-size: 15.5px; margin: 0 0 6px; overflow-wrap: break-word; }
.flow-card > p { font-size: 13px; color: var(--muted); margin: 0 0 10px; overflow-wrap: break-word; }
.flow-badges { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 10px; }
.flow-badge-skip { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: var(--muted); text-decoration: line-through; opacity: .6; }
.flow-badge-skip::after { content: "不要"; text-decoration: none; font-weight: 800; font-size: 10.5px; color: var(--accent); margin-left: 4px; display: inline-block; }
.flow-note { font-size: 11.5px; color: var(--muted); margin: 0 0 10px; }
.flow-alt { border: 1px dashed var(--line); border-radius: 10px; padding: 8px 10px; font-size: 12px; color: var(--muted); margin-bottom: 10px; }
.flow-char { display: flex; gap: 6px; font-size: 12.5px; font-weight: 700; color: var(--fg); border-top: 1px solid var(--line); padding-top: 10px; }
.flow-char .who { flex-shrink: 0; font-size: 10.5px; font-weight: 800; color: var(--muted); align-self: center; }
@media (min-width: 821px) {
  .flow-steps { max-width: none; display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
  .flow-card + .flow-card { margin-top: 0; }
  .flow-card + .flow-card::before { content: "→"; top: 50%; left: -18px; transform: translateY(-50%); }
}
```

- `story-hand-badge`（既存クラス）を再利用してトンマナ統一。`--accent` 等の既存CSS変数を使い、色を新規定義しない。
- SVG図は**作らない**（矢印はCSSの `↓`/`→` 文字。左右反転事故の余地を消す）。
- グリッドは2カラム（元のFable案は3カラムだったが、2カード構成への変更に伴い調整）。

### C-3. 「なぞる＝コピー完了」のCSSのみ演出（Phase 2・任意）

STEP 1カードの本文とバッジの間に挿入する、JSゼロの無限ループ演出:

```html
<div class="trace-demo">
  <span class="trace-text">先日の件、対応方針を教えてください。</span>
  <span class="trace-pill">✓ コピー済み</span>
</div>
```

```css
.trace-demo { background: #fff; border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px; font-size: 12.5px; margin-bottom: 10px; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.trace-text { background: linear-gradient(to right, var(--accent-soft), var(--accent-soft)) no-repeat left center; background-size: 0% 100%; animation: trace-sweep 4s ease-in-out infinite; }
.trace-pill { font-size: 10.5px; font-weight: 800; color: var(--accent); border: 1px solid var(--accent); border-radius: 999px; padding: 1px 8px; opacity: 0; animation: trace-pill 4s ease-in-out infinite; }
@keyframes trace-sweep { 0%, 12% { background-size: 0% 100%; } 45%, 92% { background-size: 100% 100%; } 100% { background-size: 100% 100%; } }
@keyframes trace-pill { 0%, 48% { opacity: 0; } 58%, 92% { opacity: 1; } 100% { opacity: 1; } }
@media (prefers-reduced-motion: reduce) {
  .trace-text { animation: none; background-size: 100% 100%; }
  .trace-pill { animation: none; opacity: 1; }
}
```

ハイライトが左→右に走り（=なぞる）、走り終わった直後に「✓ コピー済み」ピルが出る。**なぞる動作と
コピー完了の因果を時間軸で直結**させる。reduced-motion時は完成状態の静止画。

### C-4. 情報量の上限（「情報過多」批判への数値回答）

| 要素 | 上限 | 本設計の実値 |
|---|---|---|
| h2 | 16文字 | 13文字 |
| lede | 60文字 | 49文字 |
| カード見出し h3 | 12文字 | 9〜11文字 |
| カード本文 | 65文字 | 31〜59文字 |
| バッジ | 1カード3個 | 1〜2個 |
| キャラセリフ | 1カード1人・1行28文字 | 21〜27文字 |
| セクション総文字数 | 450文字 | 約350文字 |

モバイル初見1スクリーン（375×667）に h2＋lede＋STEP 1カードが収まることを実装後に確認する
（DevToolsのiPhone SEプリセットで可）。

## D. モバイル対応の具体策

- **基礎形はモバイルの縦積み**（縦型ステップカード＋`↓`コネクタ）。横長フロー図をメインに据えない、
  という会議の最重要批判（国内Web利用のモバイル比率6割超）への直接回答。横スクロールはどの幅でも発生しない。
- **ブレークポイントは1つだけ**: `min-width: 821px`（既存の story-cols が `max-width: 820px` で
  縦積みに落ちるのと対で、既存規約に揃える）。
  - **〜820px（モバイル/タブレット縦）**: 1カラム縦積み、カード間に `↓`。max-width 560px。
  - **821px〜（デスクトップ）**: 2カラムgrid、コネクタは `→` に切替（カード左端中央）。
- 矢印はCSSの疑似要素1個の content を `↓`→`→` に差し替えるだけなので、縦横で図を2枚持つコストがない。

## E. MVP（今すぐやるなら最小の一手）

**C-1のHTML＋C-2のCSSのみを追加する**（Phase 2のtrace-demo演出とキャラ画像は入れない）。

1. `grep -n '効かせる場所は、選んでいます' index.html` で挿入位置を特定し、その `<section>` の直前にC-1を挿入
2. `grep -n '/\* steps — 導入の流れ' index.html` でCSS挿入位置を特定し、その直前にC-2を追記
3. 確認: モバイル幅で縦積み・821px以上で2カラム・`#side-button` アンカージャンプが壊れていないこと

キャラは **テキストラベル（`<span class="who">りんく</span>`）のみ**で成立させる。既存の
scene-line的な表現と揃え、画像抽出を一切伴わない（地雷の完全回避）。Phase 2でtrace-demo演出、
Phase 3で40pxアバター画像追加、と段階を切る。

## F. 捨てた案と理由

| 捨てた案 | 理由 |
|---|---|
| 横長SVGタイムライン図（マウス絵＋矢印の1枚絵） | モバイル6割超で横スクロール強制（会議の最重要批判）。SVGは過去に左右反転事故もあり、図を作らなければ事故も起きない |
| JSインタラクティブな「なぞり体験」（ユーザーが実際にドラッグ→コピー完了スタンプ） | 単一静的HTML＋base64埋め込みの構成でJS実装・検証コストが高い。CSSループ演出（C-3）で因果直結の伝達目的は達成できる |
| 3操作を3カードに分割（右クリック貼り付け／長押し送信を別カード） | **事実誤認だった**。実際は長押し1回で貼り付け＋送信が完結するため、2カードが正しい構成 |
| 3操作を3セクションに分割 | 文脈（なぜ長押しに至るのか）が失われる。会議収束点「1セクション統合」に反する |
| キャラ漫才形式の多往復ダイアログ（既存 dialogue-row 再利用） | 1カードあたりのセリフが2行以上になり情報量上限（C-4）を超える。1人1行のバトンリレーで十分 |
| 既存 `#features` mouse map への統合改修 | `#side-button` アンカー・scroll-margin修正・「3秒チェック」等の実績ある資産を触るリスクが利益に見合わない。役割表と流れは別物として併存させる方が構造も明快 |
| Ctrl+Enter を独立STEPとして昇格 | 「脇道」を本流に混ぜると一筆書きの線が濁る。会議収束点どおり視覚的に格下げ（破線チップ）に留める |
| こん太を無理に3人目として登場させる | 2カード構成になったため、りんく・たぬ姉の2人で自然に収まる。こん太は他セクションでの役割を優先し、本セクションでは非登場とする |

## G. 地雷と回避策（実装時の注意点）

1. **全文Read禁止**: index.htmlは655KB。挿入位置は必ず `grep -n` でアンカー文字列
   （`効かせる場所は、選んでいます` / `/* steps — 導入の流れ`）を取り、Edit/sedで部分編集する。
2. **キャラ画像は当面使わない**: MVPはテキストラベル（`who`）のみ。Phase 3で画像を入れる場合は、
   index.html内の `<img id="char-...">` 行をsed抽出**しない**こと（過去に `story-char-line` ラッパー
   ごと抽出して吹き出し二重表示の事故）。代わりに `assets/link-s.b64.txt` / `konta-s.b64.txt` /
   `tanunee-s.b64.txt` から新規に `<img>` を組む。
3. **文言の正確性**: サイドボタンの比喩は「**戻る**ボタン」であり「進む」ではない（FAQ誤記の前科）。
   本セクションはサイドボタンに言及しないが、レビュー時に混入しないこと。長押し時間は既存copyに
   合わせ「0.35秒」で固定。
4. **【解決済み】既存copyとの整合**: 実装前の裏取りで、「右クリック長押し＝貼り付けと送信が一度に
   終わる」（L1734, L1746, L2306の実文言）が正しい挙動だと確定した。本設計はこれに基づき2カード
   構成で確定済み。着手時に再確認は不要。
5. **`#side-button { scroll-margin-top: 100px; }` を壊さない**: 新セクション追加でアンカー位置が
   ずれるため、実装後にヘッダーの `#side-button` ジャンプを目視確認（過去に固定ヘッダー下に潜る
   事故があり修正済み）。
6. **SVGを新規に描かない**: 矢印はCSS疑似要素の文字（`↓`/`→`）のみ。デスクトップの `→` はカードの
   **左端**（前のカードから流れてくる方向）に置く — C-2の `left: -18px` を変更しないこと。
7. **アニメーションは `prefers-reduced-motion` を必ず併記**（既存 `.side-btn-pulse` と同じ規約。
   C-3に記載済み）。
8. **たぬ姉の表情素材**: 本設計はアイコン画像を使わないため影響なし。Phase 3で表情付き画像を使う
   場合、「短い右クリックは〜誤爆しないの」のセリフには smile系素材を使う想定（tired専用素材が
   無い問題はこのセクションでは発生しない）。
