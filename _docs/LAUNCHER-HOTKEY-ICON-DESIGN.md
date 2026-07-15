# 設計書: ランチャーのキーボード起動トリガー（^#v）とトレイアイコン変更

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 実測456行)を実地調査した上で設計
> / 素材収集=会議ハーネス(4/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-15
> 前提: [`LAUNCHER-HOVER-PROMOTE-DESIGN.md`](LAUNCHER-HOVER-PROMOTE-DESIGN.md)（実装済み）の拡張
> 対象ブランチ: feature/launcher-hover-promote からの派生を想定

## 裏取りメモ（司令塔による検証）

Fableが引用した行番号（Ctrl+Win+Cコメント:L13、`^#c`:L175、`^#t`:L207、`ShowLauncher`:L247）
はすべて実ファイルと完全一致。実測行数456行もFableの見積もりと一致。`dist/README.txt`の
「緑の「H」アイコン」という記述もL12・L18・L40の3箇所すべてに実在し、Fableの主張と一致。
ファビコンのbase64 PNGデータURIも`index.html:19`に実在確認済み。設計の中核判断
（`Ahk2Exe /icon`焼き込みでAHK側の行数コストをゼロにする、`^#v`という文字選定の妥当性）
はいずれも実装的に妥当と判断。

## 結論の要約

| 論点 | 結論 |
|---|---|
| 要望E（キーボード起動） | **`^#v`（Ctrl+Win+V）の1行ホットキー**。連打検出は不採用（会議の収束どおり）。ゲートなしの全アプリ有効 |
| 要望F（アイコン） | **AHKコードは0行**。`Ahk2Exe /icon`でexeに焼き込む。.icoは`index.html`のファビコンから一度だけ生成してコミット |
| 行数収支 | 456 +2（ホットキー1行＋ヘッダ説明1行）= **458行。460行以内・余白2行。防衛線の緩和不要、`#Include`分離も不要** |

---

## A. 理想の体験フロー

1. ノートPCでマウスを繋いでいないとき、あるいは手がホームポジションにあるとき、**Ctrl+Win+V**を一発押すと、いつものクイックペーストポップアップがマウスカーソル位置に開く。以降は今までと完全に同じ: 数字キー1-9,0で即ペースト、Tabでタブ切替、Escで閉じる。**マウスに一度も触れずに「開く→選ぶ→貼る」が完結する**（Clibor的な体験）
2. XButton1長押しは従来どおり動く。入口が2つに増えただけで、開いた後の世界は1つ
3. タスクトレイには緑の「H」ではなく、**サイトのファビコンと同じ製品アイコン**が並ぶ
4. 配布zipを受け取ったユーザーは何も設定しない。exe自体にアイコンが焼き込まれているので、エクスプローラー上のexeアイコンもトレイアイコンも最初から製品アイコンになっている

## B. 要望E（キーボードトリガー）の結論: `^#v::ShowLauncher()` の1行

**キーは `^#v`（Ctrl+Win+V）を採用。**

- **既存パターンとの一貫性**: `^#c`（なぞってコピー切替）・`^#t`（Git Bash）に続く3つ目の「Ctrl+Win+文字」
- **文字の妥当性**: Vは「ペースト（Ctrl+V）」の文化的定着そのもの。「クイック**ペースト**を開くキー」として`^#v`以上に説明不要な文字はない
- **Windows既定との衝突**: Windows 11の`Win+Ctrl+V`（サウンド出力のクイック設定）を影に隠すが、AHKの登録ホットキーが優先されるので動作に問題はない。既存の`^#c`が既にWin+Ctrl+C（カラーフィルタ切替）を影に隠している前例があり、方針として一貫している
- **連打検出（Ctrl2回等）は不採用**: 会議の強い収束どおり。キーリピート・通常のCtrl+C/Vとの干渉リスクに対し、実装コストも高く、1行で済む単一組み合わせに勝る点がない

**ゲート（許可リスト判定）は付けない。全アプリで有効にする。**

- XButton1のゲートは「短押し=スクショとの曖昧さ解消」のためにある。キーボード起動には曖昧さが存在しないので、ゲートを持ち込む理由がない
- 非対応アプリでも定型文タブ（特に`run:`ランチャー）は普通に有用
- 安全性: `ShowLauncher()`は空なら「履歴がありません」Flashで戻るだけ。`PasteText`は`^v`を送るだけで、どのアプリでも破壊的な動作にならない

**表示位置はマウスカーソル位置のまま**。キャレット位置への表示は追加行数に見合わないので据え置き（G節参照）。

## C. 要望F（アイコン変更）の結論: Ahk2Exe /icon 焼き込み・AHKコード0行

**`TraySetIcon`は書かない。** AutoHotkeyのコンパイル済みスクリプトは、**exeに焼き込まれたカスタムアイコンを自動的にトレイアイコンとして使う**。つまり`build.ps1`のAhk2Exe呼び出しに`/icon`を1フラグ足すだけで、配布物（exe）のトレイアイコン・エクスプローラー上のアイコン・タスクバー表示がすべて製品アイコンになり、**スクリプト行数の消費はゼロ**。

- **.icoの入手元**: 新規デザイン不要。`index.html:19`のファビコン（64x64 PNG、base64埋め込み）が製品アイコンの正本。これを一度だけデコード→16/32/48/64pxの4サイズ入り.icoに変換し、`assets\soushin-suggest.ico`としてコミットする
- **zipへの.ico同梱は不要**: アイコンはexe内蔵なので、配布形態・README手順は変わらない（README.txtの「緑のH」という文言だけ直す）
- **開発時（.ahk直接実行）は緑Hのまま**: これは仕様とする。「緑H=生スクリプトの開発実行 / 製品アイコン=ビルド済みexe」という見分けがつくのはむしろ利点
- **既知のトレードオフ**: カスタムアイコン入りのコンパイル済みスクリプトは、Suspend/Pause時にアイコンが変化しなくなる。トレイメニューのチェックマークで状態は確認でき、許容範囲

## D. 具体機構（既存実装との差分）

### D-1. AHK本体の差分（計+2行）

**(1) ヘッダ説明の追加（L13の直後に1行挿入、+1行）**

```autohotkey
;  Ctrl+Win+C              -> なぞってコピーのON/OFF切り替え
;  Ctrl+Win+V              -> クイックペーストを開く（マウスなしでも呼び出せる）
```

**(2) ヘッダL16の文言修正（±0行）** — 「緑のH」前提を除去:

```autohotkey
;  トレイのアイコンを右クリック -> Suspend Hotkeys / Exit
```

**(3) ホットキー本体（L207 `^#t::ActivateGitBash()` の直後に1行、+1行）**

```autohotkey
^#t::ActivateGitBash()
^#v::ShowLauncher()   ; キーボードからクイックペースト（Clibor風・アプリを問わず有効）
```

`ShowLauncher`は空チェック・`LauncherTarget`捕捉・ピン位置復元・タイマー起動をすべて内包しているので、呼ぶだけでよい。数字キーHotIfブロックは「ランチャーがアクティブな間」でゲートしており、起動経路に依存しないため**変更不要**。

### D-2. アイコン生成（一度だけ実行してコミット。`scripts/make-icon.ps1`として保存）

**注意: PowerShellスクリプトのコメントは英語限定**（日本語だとShift-JIS誤読で壊れる既知の地雷）。

```powershell
# scripts/make-icon.ps1
# One-time: extract the site favicon (base64 PNG in index.html) and build a
# multi-size .ico (16/32/48/64, PNG-compressed entries, Vista+) for Ahk2Exe /icon.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make-icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent
$html = Get-Content (Join-Path $repo 'index.html') -Raw
if ($html -notmatch 'rel="icon"[^>]*base64,([A-Za-z0-9+/=]+)') { throw 'favicon data URI not found in index.html' }
$src = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(,[Convert]::FromBase64String($Matches[1]))))
$sizes = 16, 32, 48, 64
$pngs = foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($src, 0, 0, $s, $s); $g.Dispose()
    $m = New-Object System.IO.MemoryStream
    $bmp.Save($m, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    , $m.ToArray()
}
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($out)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)   # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {                                     # ICONDIRENTRY x4
    $bw.Write([byte]$sizes[$i]); $bw.Write([byte]$sizes[$i])
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($d in $pngs) { $bw.Write($d) }
[IO.File]::WriteAllBytes((Join-Path $repo 'assets\soushin-suggest.ico'), $out.ToArray())
Write-Output ('OK: assets\soushin-suggest.ico (' + $out.Length + ' bytes)')
```

生成後、`assets\soushin-suggest.ico`をgitにコミットする（ビルドのたびに再生成しない。fail-closed: ビルド時は存在チェックのみ）。

### D-3. `scripts/build.ps1`の差分（4箇所）

```powershell
# (a) パス定義ブロックに追加
$icon = Join-Path $repo 'assets\soushin-suggest.ico'

# (b) 存在チェック群に追加 — fail-closed: 無ければ緑Hで黙って出荷、を防ぐ
if (-not (Test-Path $icon)) {
    Write-Error "Icon not found: $icon (run scripts\make-icon.ps1 first)"
    exit 1
}

# (c) staging コピーに追加 — Japanese/OneDrive path safety, same reason as the .ahk
Copy-Item $icon (Join-Path $stage 'soushin-suggest.ico')

# (d) Ahk2Exe の ArgumentList に2要素追加
$p = Start-Process -FilePath $ahk2exe -ArgumentList @(
    '/silent', 'verbose',
    '/in', "`"$stage\soushin-suggest.ahk`"",
    '/out', "`"$outExe`"",
    '/icon', "`"$stage\soushin-suggest.ico`"",
    '/base', "`"$base`""
) ...  # 以降は変更なし
```

zip梱包リストは**変更なし**（アイコンはexe内蔵）。

### D-4. `dist/README.txt`の文言修正（行数防衛線の対象外）

- L12: 「タスクトレイに緑の「H」アイコンが〜」→「タスクトレイに送信サジェストのアイコンが表示されれば準備完了です。」
- L18・L40: 「緑の「H」アイコン」→「送信サジェストのアイコン」

## E. 行数収支（460行以内の明確な計算）

| 項目 | 増減 |
|---|---|
| 現状（`wc -l`実測） | **456** |
| ヘッダ説明1行（D-1(1)） | +1 |
| `^#v`ホットキー1行（D-1(3)） | +1 |
| L16文言修正（D-1(2)） | ±0 |
| 要望F（アイコン） | **±0**（AHK側変更なし。build.ps1と.icoで完結） |
| **着地** | **458行。上限460以内・余白2行** |

会議の「E:約20行」見積もりは、`ShowLauncher`が既に安全な共通入口として完成していることを見落とした過大見積もり。既存資産に薄く乗るだけなら2行で済む。**防衛線の緩和も`#Include`分離も不要。**

## F. MVP（今すぐやるなら最小の一手）

1. **要望Eだけ先に**: D-1の3変更（+2行）→ `scripts/build.ps1`でビルド → `^#v`でランチャーが開き、数字キー・Esc・XButton1経路の回帰がないことを確認 → コミット
2. **要望F**: `make-icon.ps1`作成・実行 → `assets\soushin-suggest.ico`コミット → `build.ps1`の4点差分 → README.txt文言修正 → ビルド → トレイとexeのアイコンを目視確認 → コミット
3. バージョンを上げて（例: 1.2.0）zipを再生成、reality-checkerに動作判定を委任（検証観点はH-1）

EとFは完全に独立しているので、コミットは必ず分ける。

## G. 捨てた案と理由

- **Ctrl2回押し等の連打検出**: 却下。会議の収束どおり（キーリピート・Ctrl+C/V干渉・誤作動頻発）。単一組み合わせなら失敗モードが存在しない
- **`^#e`（会議案）**: 却下。Eの意味付けが弱い。`^#v`=「ペーストのV」の方が説明コストゼロ
- **`^#s`（soushin/suggestの頭文字）**: 次点で検討したが却下。SはSave連想が強く、「開くとペーストされる」機能の連想としてVに劣る
- **キーボード起動時もXButton1と同じ許可リストゲートを適用**: 却下。ゲートの存在理由（スクショとの曖昧さ解消）がキーボードには当てはまらず、非対応アプリでの定型文・`run:`起動という実用を殺す
- **キャレット位置への表示**: 却下。`GetCaretPos`系はElectron/ブラウザで安定して取れない既知の難所で、フォールバック分岐に行数を食う
- **`try TraySetIcon(A_ScriptDir "\soushin-suggest.ico")`を1行足す＋zip同梱**: 却下。コンパイル済み配布物には`/icon`焼き込みで足り、.icoのzip同梱（ユーザーが消せる=緑Hに戻る失敗モード）と行数1を増やすだけ
- **`FileInstall`での.ico埋め込み＋実行時展開**: 却下。`/icon`で済むものに実行時ファイル書き込みを持ち込む理由がない
- **128px以上の高解像度ico**: 却下。トレイは16/32px表示。正本ファビコンが64pxなのでアップスケールは無意味
- **`#Include`分離**: 不要。458行で着地するので議題にすら上がらない（460超過が起きたときの次回議題として温存）

## H. 地雷と回避策

1. **【最重要】実機検証項目**: (a) `^#v`でランチャーが開く（対応アプリ・非対応アプリ・デスクトップの3箇所で）／(b) 開いた後の数字キー・タブ切替・Esc・ホバー・ドラッグ・右クリック昇格が従来どおり／(c) XButton1長押し経路の回帰なし／(d) `^#c`・`^#t`が従来どおり／(e) ビルド後のexeをエクスプローラーで見てアイコンが製品アイコン／(f) 起動してトレイアイコンが製品アイコン／(g) トレイ右クリックメニュー（Suspend/Exit/自動起動トグル）が従来どおり／(h) Win11で`Win+Ctrl+V`が本ツール起動になる（サウンド出力フライアウトが出ないのは仕様）
2. **build.ps1のstagingに.icoを必ずコピーする**こと。リポジトリパスは日本語（デスクトップ）を含むため、`/icon`にリポジトリ直パスを渡すとAhk2Exeが読めない可能性がある
3. **make-icon.ps1のコメント・文字列は英語限定**。日本語を入れるとShift-JIS誤読でスクリプト自体が壊れる
4. **`/icon`の指定順序**を確認し、ビルド後に必ずexeアイコンを目視すること。「ビルドが通った=アイコンが入った」ではない
5. **Suspend時にトレイアイコンが変化しなくなる**（カスタムアイコンの既知仕様）。状態確認はトレイメニューのチェックマークで行う
6. **ビルドは必ず`scripts/build.ps1`経由**（Git BashからAhk2Exe直叩き厳禁）
7. **不可侵領域は今回一切触らない**: `-Caption +AlwaysOnTop +ToolWindow +Border`・`CoordMode "Mouse", "Screen"`・Tab3構成・`LoadSnippets`・`ClipHistory`オブジェクト・XButton1許可リストゲート・数字キーHotIfブロック・ドラッグ/ホバーのポーリング
8. **README.txtの「緑のH」3箇所（L12/L18/L40）を直し忘れない**
9. **規模**: 着地458行・余白2行。次の要望が+3行以上なら、その時点で`#Include`分離を会議の議題にすること（460の再緩和は禁止・確定済み）
