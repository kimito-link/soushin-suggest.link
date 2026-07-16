# 送信サジェスト「コードの地図」設計書 — `/map/` 関数マップページ

> 設計=Fable(claude-fable-5) ／ 対象: `soushin-suggest.link` (静的サイト)
> 踏襲元: `tsuioku-no-kirameki.com/scripts/repo-tree-map.mjs`（実地調査で分類メカニズムを解明した上で翻案）
> 日付: 2026-07-17

対象: `dist/soushin-suggest.ahk`（実測 **2012行・グローバル関数101個**、v1.12.0。関数数は `^FuncName(args) {` の列0パターンで機械カウント済み）。参照元 tsuioku-no-kirameki の `repo-tree-map.mjs` の思想（2段カスケード分類・役割コメント抽出・ハードコード脊椎・健全性バナー）を、「ファイル」→「関数」の単位に翻案する。

ユーザーからの要望「不具合があればどこのどこを直せばいいか一発で原因特定できてわかるものが欲しい。JSONを貼り付けるようなものは望んでいない」への回答。既存の`/shindan/`(診断JSON貼り付けビューア)は「実機の動的計器」として残し、こちらは「ソースの静的地図」として別ページ追加する。

---

## A. 理想の体験フロー

1. 不具合報告が来る（例:「右クリック長押しで送信されない」「履歴のサムネイルが出ない」）。
2. `soushin-suggest.link/map/` を開く。**貼り付けも操作も一切不要**。開いた瞬間に地図が描画済み。
3. ページ最上部の**パイプラインバナー**（検知→取得→記録→表示→貼り付けの5段）を見て、症状がどの段の故障かを当たりを付ける。「履歴に残らない」なら記録段、「残るが一覧に出ない」なら表示段。
4. 段のチップ（関数名）をクリックすると、下の**カテゴリ別関数グリッド**の該当カードへスクロール。カードには「関数名・行番号・役割コメント1行」が並ぶ。`PushClipHistory / L323 / 履歴先頭へ追加・重複昇格・上限切り詰め` のように、**修正すべき場所が「ファイル名ではなく行番号」で一発特定**できる。
5. マウス起因の不具合なら**入口テーブル**（ホットキー/フック一覧）から入る。「サイドボタン(進む)が効かない → XButton2:: L385」。
6. ページ下部の健全性バナーが「役割コメント無し: N/101」を常時表示し、地図の解像度そのものを計測する。
7. 実機の挙動データが必要になったら、既存の `/shindan/`（診断JSONビューア）へリンクで渡る。**/map/ は静的な地図、/shindan/ は動的な計器**——役割を明確に分離し、両方残す。

---

## B. 統合アーキテクチャ（コンポーネント4個・配線）

すべて **`map/index.html` 1ファイル内の vanilla JS**（CDNなし・ビルドスクリプトなし）。実行時に同一オリジンの `.ahk` を読む（判断根拠はD節）。

```
[① ソース取得 Fetcher]
   fetch("/dist/soushin-suggest.ahk", {cache:"no-cache"})   ← 同一オリジン。distはgit管理済みで
   │  BOM除去 → 全行配列                                       静的サイトの一部として既にデプロイされている
   ▼
[② パーサ Parser]
   ・関数定義の検出（列0の FuncName(args) { ）
   ・役割コメント抽出（直上の隣接 ; ブロック → 無ければ定義行末尾の ; ）
   ・入口検出（列0の Hotkey:: 行、OnClipboardChange/OnExit 登録行）
   ・global AppVersion := "…" の抽出
   ▼
[③ 分類器 Classifier]  … 参照元 classifyFeatureCategory の関数版
   MANUAL(手動上書き・少数) → NAME_RULES(関数名regex) → ROLE_RULES(コメント文言regex) → その他
   ▼
[④ レンダラ Renderer]
   パイプラインバナー(SPINE_STAGES: ハードコード) ＋ 入口テーブル ＋
   カテゴリ別グリッド ＋ 健全性バナー
   ※ fetch/parse 失敗時は fail-closed: 白紙ではなく「取得失敗: <URL> <status>」バナー＋
     ハードコード部(パイプライン段の説明・入口の説明文)だけは表示
```

データは①→②→③→④の一方向。状態を持たない純関数の連結で、参照元と同じく「手編集しない・ソースが正本」の原則を守る（違いは変換の実行タイミングだけ）。

---

## C. 具体機構

### C-1. 分類ルール（2段カスケード＋手動上書き層）

参照元の `FEATURES`（手動キュレーション優先）→ `PATH_RULES` → `ROLE_RULES` の三層構造をそのまま関数単位に写像する。**上から順に最初のマッチで確定**。

**第0層 MANUAL（手動上書き・regexの誤爆を止める少数の例外だけ）**

```js
const MANUAL = {
  // "Snippet"を名に含むがユーザー体験上は貼り付け動作
  UseSnippetAt:        "📤 送信・貼り付け",
  // "Clip"で始まるが実体はGDI/画像ヘルパ
  GetClipDib:          "📷 画像・スクショ",
  SetClipboardImage:   "📷 画像・スクショ",
  // ミドルクリックの独立機能
  ActivateGitBash:     "🚪 入口・ジェスチャ",
};
```

**第1層 NAME_RULES（関数名。順序が意味を持つ）** — 全101関数の実名を突き合わせて設計した表:

| # | 正規表現（/i） | カテゴリ | マッチする実例関数 |
|---|---|---|---|
| 1 | `^Diag\|Diagnostics\|^BuildDiagText$` | 🩺 診断 | DiagBump, CopyDiagnostics, BuildDiagText |
| 2 | `Archive` | 🗃 フォルダ保存(オプトイン) | QueueTextArchive, CommitPendingArchive, ArchiveBaseDir, ArchiveSubDir, OpenArchiveDir, DiscardPendingArchiveOnExit, ApplyArchiveToggle, ArchiveSnippetsCsv※ |
| 3 | `Snip\|Csv\|Clibor` | 📝 定型文管理 | ShowSnippetManager, SnipMgr系12個, LoadSnippets, ParseCsv, TryLoadCliborCsv, CliborHeaderOk, CsvField, ImportSnippets, ExportSnippetsCsv… |
| 4 | `Thumb\|Dib\|Png\|Bmp\|Image\|Monitor\|ScreenRect` | 📷 画像・スクショ | CaptureClipImage, PushClipImage※, PasteImage※, MakeHistThumb, EnsureHistThumbIL, SaveDibAsPng, CaptureRectToDib, CaptureMonitorAtCursorToClipboard, FlashScreenRect, DibBitsOffset, PngEncoderClsid |
| 5 | `^Clip\|CaptureClip\|MaybeDrop` | 📋 コピー検知・フィルタ | ClipChanged, CaptureClip, ClipOpen, ClipHasIgnoreFormat, ClipSourceExcluded, MaybeDropAutoCleared, ToggleClipWatch |
| 6 | `Paste\|SendMode` | 📤 送信・貼り付け | PasteText, PasteHistoryAt, CurrentSendMode |
| 7 | `Hist\|History` | 💾 履歴記録 | PushClipHistory, DeleteHistoryAt, DeleteHistoryAll, PromoteHistoryAt, OpenHistoryPath |
| 8 | `Launcher\|^SetTabLabel$\|Hover\|Drag` | 🖼 ランチャーUI | ShowLauncher, CloseLauncher, RefreshLauncherHistory, FillLauncherHistoryLV, LauncherWatchDrag/Hover, LauncherItemUnderMouse, LauncherLVItemHeight, LauncherContextMenu, LauncherPickKey, CheckLauncherFocus |
| 9 | `Ini\|Config\|Settings\|Startup\|Shortcut\|AhkProp` | ⚙ 設定・起動 | LoadSitesConfig, SaveIniKey, ShowSettingsWindow, ShowLauncherSettingsMenu, EnsureStartMenuShortcut, CreateAppShortcut, EnableStartup, ToggleStartup, RefreshStartupMenuLabel, AhkPropSet/Key |

※印は順序の妙: `PushClipImage` は規則7(Hist)ではなく規則4(Image)が先に取る＝画像カテゴリへ。`ArchiveSnippetsCsv` は規則2(Archive)が先＝定型文のバックアップだが保存系へ。この2件はどちらの分類も妥当なので上書き不要（迷ったら先勝ちを受け入れ、明白な誤爆だけMANUALへ——参照元と同じ運用思想）。

**第2層 ROLE_RULES（役割コメント文言。名前が無口な関数を拾う網）**

```js
const ROLE_RULES = [
  [/貼り付け|送信|ペースト/,               "📤 送信・貼り付け"],
  [/履歴/,                                  "💾 履歴記録"],
  [/スクショ|画像|サムネ|ビットマップ/,     "📷 画像・スクショ"],
  [/ツールチップ|ホバー|タブ|リスト|GUI|ウィンドウ/, "🖼 ランチャーUI"],
  [/ini|設定|スタートアップ|ショートカット/i, "⚙ 設定・起動"],
  [/曜日|時刻|パス|ロケール/,               "🔧 汎用ヘルパ"],   // NowWithWeekday, RunnablePathFrom等
];
// どれにも落ちなければ "その他" — その他が多い＝ルールの負債、健全性バナーで可視化
```

**第3層 SPINE_STAGES（パイプライン。参照元と同じく完全ハードコード＝自動推論しない）**

参照元の「取得→記録→集計→表示」4段を、この製品の実配線に合わせ**5段**に翻案する（この製品の終着価値は「表示」ではなく「貼り付け」だから1段足す。「集計」段は本製品に存在しないので置かない）:

```js
const SPINE_STAGES = [
  { id:"detect",  label:"👀 検知",     desc:"クリップボード変化を捕まえ、ノイズ・除外アプリを弾く",
    funcs:["ClipChanged","ClipHasIgnoreFormat","ClipSourceExcluded"] },
  { id:"capture", label:"📥 取得",     desc:"テキスト/画像を実際に読み取る",
    funcs:["CaptureClip","CaptureClipImage"] },
  { id:"record",  label:"💾 記録",     desc:"メモリ履歴へ追加(重複昇格・上限)、オプトイン時のみ検疫付き保存",
    funcs:["PushClipHistory","PushClipImage","QueueTextArchive"] },
  { id:"display", label:"🖼 表示",     desc:"ランチャーの履歴タブへライブ反映",
    funcs:["RefreshLauncherHistory","FillLauncherHistoryLV","ShowLauncher"] },
  { id:"paste",   label:"📤 貼り付け", desc:"選んだ項目を対象アプリへ送る",
    funcs:["PasteHistoryAt","PasteText","PasteImage"] },
];
```

### C-2. 役割コメント抽出アルゴリズム（AHK版ノイズフィルタ）

参照元のJS版（shebang/ディレクティブ/区切り線/ファイル名繰り返しのスキップ→最初の4文字以上の説明文）を、AHKの記法と**この実ファイルで観測した実際のコメント習慣**に合わせて翻案:

```
入力: 全行配列 lines, 関数定義の行番号 defLine
1. defLine の直上から上へ、"; " 行が連続する限り遡る（隣接性ルール:
   空行・非コメント行・別の "}" が現れた瞬間に打ち切り）。
   /* */ ブロックが直上で閉じていればその内側も同様に対象。
2. 集めたブロックを「上から下」(読み順)に走査し、各行を正規化:
   - 先頭の ";" と空白を除去
   - 区切り飾りの除去: 先頭/末尾の /[=\-–—*]{3,}/ を剥ぐ
     （例: "; --- load sites.ini (per-app rules…) ---" → "load sites.ini (per-app rules…)" が生きる）
   - スキップ対象: 空になった行 / /^@/ (ディレクティブ風) / /^(TODO|FIXME|NOTE):?$/
     / 関数名自身の繰り返し (/^FuncName\s*[:：]?$/i)
3. 最初に残った4文字以上の行を「役割」とする。2行目以降は「詳細」として
   カードの折りたたみ(<details>)に全文格納（この製品のコメントは経緯説明が濃く、捨てるのは惜しい）。
4. ブロックが無い場合のフォールバック: 定義行自身の末尾コメントを採用。
   実例: "HistThumbIndex(v) {   ; 生成は要素につき1回。以後はキャッシュ…" → これが役割になる。
   "DeleteHistoryAll(*) {   ; トレイメニューからも呼ぶため可変引数" も同様に救える。
5. それでも無ければ role = null → 健全性バナーの分子にカウント。
```

隣接性ルール(手順1)が肝: 実ファイルでは `global ClipDiag` の直上に濃いコメントブロックがあり、その直後に空行を挟んで `DiagBump()` が来る。空行打ち切りが無いと**グローバル変数の説明を関数の役割と誤認**する（G節の地雷#4）。

### C-3. 関数定義・入口の検出

```js
const KEYWORDS = /^(if|while|for|loop|until|else|try|catch|switch|return|static|global|class)\b/i;
// 列0(インデントなし)の定義のみ。AHK v2のグローバル関数はこの形しか無いことを実測済み(101件)
const DEF_RE = /^([A-Za-z_]\w*)\(([^)]*)\)\s*\{\s*(?:;\s*(.*))?$/;   // $3=末尾コメント
// 入口(ホットキー/フック): 列0の "…::" 行 + OnClipboardChange/OnExit/SetTimer登録
const HOTKEY_RE = /^([~*$!^+#<>]*\S+?)::/;
```

入口テーブルは**パース＋手動説明のハイブリッド**: 行番号と発火キーはパースで取り、説明はヘッダコメント(L16-24に既にユーザー向け一覧がある)相当の固定辞書 `ENTRY_NOTES = { "XButton2":"短押し=全画面スクショ/長押し=範囲指定", … }` で付ける。SPINE_STAGES同様、少数(8個前後)なのでハードコードが正しい。

### C-4. ページ構成（1画面・上から下へ）

```html
<header>  送信サジェスト コードの地図
  v1.12.0(パース値) ・ 2012行 ・ 関数101個 ・ /shindan/(実機計器)へのリンク </header>

<section id="spine">   <!-- 5段バナー: 横並びチップ、クリックで該当カードへ #anchor -->
  [👀 検知]→[📥 取得]→[💾 記録]→[🖼 表示]→[📤 貼り付け]
</section>

<section id="entries"> <!-- 入口テーブル: 8行程度 -->
  ~LButton(なぞってコピー) / RButton長押し(送信) / XButton1(クイックペースト) /
  XButton2(スクショ) / MButton / ^#c / ^#v / OnClipboardChange→ClipChanged
</section>

<section id="grid">    <!-- カテゴリ別グリッド: 10カテゴリ × 計101カード -->
  <h2>📋 コピー検知・フィルタ (7)</h2>
    <div class="card" id="fn-ClipChanged">
      <code>ClipChanged</code> <span class="line">L1077</span>
      <p>クリップボード変化フック…(役割1行目)</p>
      <details><summary>詳細</summary>(役割2行目以降全文)</details>
    </div> …
</section>

<footer id="health">   <!-- 健全性バナー -->
  役割コメントが無い関数 N/101件: DiagBump, Flash, … ／ 「その他」に落ちた関数 M件
</footer>
```

**参照元からの縮退**（677ファイル規模→101関数規模への適正化）: 6ファイル生成→1ページのみ / マインドマップ・キャラ解説(`CATEGORY_CHARA_NOTE`)→廃止 / `FEATURES`の説明文付き代表機能カタログ→SPINE_STAGESに統合 / 検索ボックス→付けない(1ページに全部載るのでブラウザのCtrl+Fで足りる)。CSSは既存 `shindan/index.html` のトーンを流用し、ダーク1テーマ・装飾最小。

---

## D. ビルド時 vs 実行時生成の判定（必答論点3）

**前提となる実地調査結果が判断を変える**: `dist/soushin-suggest.ahk` は git 管理されており（`git ls-files dist` で確認）、このサイトは `_routes.json` が `/api/*` のみを Functions に回す静的ホスティング構成。つまり **`.ahk` ソースは既に `soushin-suggest.link/dist/soushin-suggest.ahk` として同一オリジンの静的資産にデプロイされている**。課題文が懸念した「自分のGitHubリポジトリの生ソースをfetchする新しい外部依存」は、**同一オリジンfetchにすれば発生しない**。

| 観点 | ビルド時生成(Node) | 実行時生成(同一オリジンfetch) |
|---|---|---|
| 鮮度 | `.ahk`更新のたび `node scripts/build-map.mjs` を**手動実行し忘れると地図が古いまま嘘をつく**（このリポにはサイトのビルドパイプラインが存在せず、コミット物がそのまま配信される。build.ps1はexe用） | `.ahk`と同じコミット・同じデプロイで**常に自動同期**。忘れる工程が存在しない |
| 外部依存 | なし | **なし**（同一オリジン。GitHub raw等は使わない） |
| 正本原則 | 生成HTMLという「派生コピー」をgitにコミットする＝「正本1つ・コピー散らさない」に反する | 派生物を保存しない。ソースが唯一の正本 |
| 失敗の見え方 | ビルド時に失敗を検出できる(fail-closed) | 閲覧時にパース失敗しうる → **fail-closedバナー**(白紙にせず失敗理由を表示)で担保 |
| JSなし閲覧 | 可能 | 不可（ホスト配信前提のページなので許容） |
| 規模 | 1371行のスクリプト前例あり | 対象は2012行・約80KBの1ファイル。ブラウザでのパースは数ms |

**判定: 実行時生成を推奨する。** 決め手は3点: (1) 同一オリジンfetchにより実行時案の唯一の実質的欠点だった外部依存が消える、(2) このリポには現在サイトのビルド工程が一つも無く、ビルド時案は「リポ初のビルドパイプライン＋実行し忘れという新しい人的故障モード」を持ち込む——今回のゴール(不具合時に信頼できる地図)にとって**古い地図は無い地図より悪い**、(3) 参照元がビルド時なのは677ファイルを`git ls-files`で走査する必要があったからで、ブラウザから見えない情報を使う都合であり、単一ファイルが同一オリジンに公開済みの本件にはその前提が無い。パーサ・ルール群は純粋なデータ/純関数として書き（C節の通り）、将来ビルド時へ移す・姉妹プロジェクトの汎用計器キットへ移植する際もそのままNodeで動く形にしておく。

---

## E. MVP（1つだけ作るなら）

**`map/index.html` 1ファイル**: ①同一オリジンfetch → ②関数定義＋役割コメントのパース → ③3層カスケード分類 → ④**カテゴリ別関数グリッド＋健全性バナー**の描画、まで。パイプラインバナーと入口テーブルはデータ(SPINE_STAGES/ENTRY_NOTES)だけ定義しておき描画は第2弾でもよい——「不具合→どの関数のどの行か」の一発特定はグリッドだけで成立する。受け入れ基準: (a) 開くだけで101関数が10カテゴリに分かれて全件表示される、(b) 各カードに行番号がある、(c) 役割コメント無し件数がバナーに出る、(d) fetch失敗時に白紙でなくエラーバナーが出る。

## F. 捨てた案と理由

- **診断JSONとの統合ページ**: `/shindan/` は「実機の動的計器」、`/map/` は「ソースの静的地図」で目的が別。混ぜると前回却下された「貼り付け操作」がまた入口に立つ。リンクで相互参照するだけにする。
- **Nodeビルド時生成**: D節の通り。鮮度の人的故障モードと派生コピーのコミットが原則に反する。
- **GitHub raw からの fetch**: 同一オリジンに実物があるのに外部オリジン・レート制限・公開設定依存を背負う理由がない。
- **コールグラフ自動抽出（関数間の呼び出し矢印を全自動描画）**: AHKは `SetTimer`, `.Bind()`, ホットキー文字列経由の間接呼び出しが多く、regexでは矢印が虫食いになり「地図が嘘をつく」。ハードコードのSPINE_STAGES（人間が保証する幹線だけ描く）が参照元の答えであり、それに従う。
- **キャラクター解説・マインドマップ描画**: 677ファイル規模の姉妹サイト向け演出。101関数では過剰装飾で、原因特定という目的に寄与しない。
- **検索・フィルタUI**: 1ページ全載せ＋Ctrl+Fで足りる規模。JSを増やすだけ。

## G. 地雷と回避策

1. **関数定義regexの誤検出**: 列0の `if (x) {` 等の制御構文・ホットキーブロック `^#c:: {` が `Name(args) {` に紛れる。→ 列0限定＋制御キーワードのブラックリスト＋`::`行の除外。実ファイルで101件ちょうどになることを検収時に目視突合。
2. **CDN/ブラウザキャッシュの古い.ahk**: デプロイ直後に地図だけ旧版を映す。→ `fetch(…, {cache:"no-cache"})` ＋ ヘッダにパースした `AppVersion` を明示表示（ズレたら人間が気づける）。
3. **`.ahk` の配信可否/MIME**: ホスティングが `.ahk` を octet-stream で返しても `response.text()` は動くが、そもそも404の可能性はゼロでない。→ 実装初日に本番URLで1回確認。失敗時はURLとstatusを出すfail-closedバナー（白紙禁止）。
4. **役割コメントの誤帰属**: 関数直上にあるのが「グローバル変数の説明」や「前の関数の閉じ括弧後の余談」であるケース。→ C-2の隣接性ルール（空行・非コメント行で即打ち切り）。実ファイルの `ClipDiag` コメント→`DiagBump` で再現テスト。
5. **BOM/文字コード**: `.ahk` はUTF-8(BOM付き想定)。1文字目のBOMを剥がさないと1行目のパースと `#Requires` 判定がズレる。→ `text.replace(/^﻿/, "")`。
6. **ルール順序の腐敗**: 将来関数が増えて「その他」やMANUALが膨らむと地図の信頼が落ちる。→ 健全性バナーに「その他 M件」も併記し、増加を可視化（役割コメント欠落と同格の負債として扱う。必答論点5への答え: **健全性チェックは含める**。このコードベースはコメント文化が資産であり、地図の解像度＝コメント被覆率。欠落一覧は「次にコメントを書くべき関数のTODOリスト」として機能し、実装コストは10行程度で釣り合う）。
7. **将来のファイル分割**（リポ直下に refactor-instructions.md あり）: 単一ファイル前提を定数に閉じ込める → `const SOURCES = ["/dist/soushin-suggest.ahk"]` の配列にしておき、分割時は要素追加のみで対応。カードの行番号表示も `ファイル名:L行` 形式に自然拡張できる。
