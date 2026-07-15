# 設計書: クイックペーストのホバープレビューと履歴→定型文昇格

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 実測400行ちょうど)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・5/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-15 ／ 前提: [`LAUNCHER-DRAG-MOVE-DESIGN.md`](LAUNCHER-DRAG-MOVE-DESIGN.md)（実装済み・ポーリング教訓を継承）
> 対象ブランチ: feature/launcher-drag-move からの派生を想定

## 裏取りメモ（司令塔による検証）

Fableが引用した行番号（ClipHistory宣言:L21、EnableStartup:L99、ToggleStartup:L113、
PushClipHistory:L169、ShowLauncher:L253、PasteHistoryAt:L294、CloseLauncher:L338、
既存ContextMenuハンドラ:L286）はすべて実ファイルと完全一致。`IniRead`を避けた既存コメントも
2箇所（L31, L232）実在し、Fableが「IniWriteも同族の地雷」と関連付けた根拠は裏付けられた。
設計の中核判断（IniWrite不採用の理由付け、行計算によるヒットテスト、ポーリング方式の一貫採用）
はいずれも実装的に妥当と判断。

## 結論の要約

| 論点 | 結論 |
|---|---|
| 400行防衛線 | **460行に緩和（ハード上限・次回以降の再緩和は禁止）**。軽い回収リフォーム(-5行)を併用し、着地見込み約456行 |
| 要望C（ホバー） | **120msポーリング＋`ToolTip()`の自前ツールチップ**。項目特定は`LB_GETTOPINDEX`/`LB_GETITEMHEIGHT`/`LB_GETCOUNT`の行計算（標準Win32メッセージのみ・オーナードロー不要・ListView置換は再却下） |
| 時刻記録 | `ClipHistory`を`{text, time}`のオブジェクト配列化。`time`は`FormatTime(, "HH:mm")`の表示用文字列。非永続のまま |
| 要望D（昇格） | **`IniWrite`は不採用**（ANSI書き込みでUTF-8ファイルが化ける）。**UTF-8明示の`FileAppend`で1行追記** |
| 右クリック競合 | 競合しない。既存`ContextMenu`ハンドラの`ctrl`分岐を1行ラムダ→名前付き関数に昇格して分岐を足すだけ |

---

## A. 理想の体験フロー

1. サイドボタン長押しでポップアップを開く。履歴タブの項目にマウスを乗せて一呼吸置くと、カーソル脇にツールチップが出る: 1行目「14:23 にコピー」、2行目以降に全文（58字で切られていた続きが読める）。隣の項目に動かせばツールチップが差し替わり、リスト外に出れば消える
2. 定型文タブでも同様にホバーで本文全文（`\n`は実改行で）が見える。「この定型文、中身なんだっけ」がクリック（＝即ペースト）せずに確認できる
3. 履歴タブで「これは今後も使う」と思った項目を**右クリック** → ポップアップは閉じ、小さな入力欄が出る（名前は本文先頭12字が初期値）→ Enterで`snippets.ini`の末尾に追記され、「定型文に登録しました: ○○」のトースト
4. 次にランチャーを開くと、定型文タブに今の項目が増えている（`LoadSnippets`は開くたび読み直すので**追加コードゼロで反映**）
5. 掴みしろのドラッグ移動・右クリック固定解除・数字キー・クリック即ペースト・Escクローズは一切変わらない。右クリックの意味は「掴みしろ=固定解除」「履歴項目=昇格」の2つで、押した場所（コントロール）で決まる

## B. 400行防衛線の扱いの結論: 460行へ緩和（ハード上限）

**維持＋相殺は不成立、緩和する。新上限は460行。**

- 前回のドラッグ移動実装時に、コメント圧縮・関数の1行化などの回収余地は**すでに刈り取って400行ちょうどに着地**している。残る「削りしろ」は不可侵領域か、ユーザー向けドキュメントコメントしかない
- 今回の2機能の正味コストは約+61行。ホバーは「ListBoxが項目ツールチップ非対応」という構造的制約を自前ポーリングで越えるため、昇格は「ユーザー編集ファイルを壊さず安全に書く」ため、それぞれ圧縮しきれない最低限の行数がある
- 軽い回収リフォーム(-5行)を併用して**着地見込み約456行・余白4行**
- **460は次のハード上限であり、次回要望での再緩和は禁止**。460に収まらない次の機能が来たら、行数交渉ではなく「ランチャーサブシステムの`#Include`分離（配布形態の変更を伴う）」を次回会議の議題にすること
- 超過時の縮退優先順位（削る順）: ①定型文タブのホバー(-2行) ②各関数の説明コメント ③InputBoxを自動ラベル化(-4行、ラベル=本文先頭12字固定)。**昇格機能そのもの・履歴ホバー・時刻記録は削らない**

## C. 要望C（ホバー）の結論: 120msポーリング＋ToolTip＋行計算ヒットテスト

**ListView置換は前回に続き再却下**（回帰リスク・オーナードロー地雷・行数、理由は前回設計と同一）。**サブクラス化やTTN_GETDISPINFOフックも却下**——「理論上動くはずが実機で動かない」のドラッグ教訓が示した通り、この`-Caption +ToolWindow`なGuiでメッセージフック系は信用しない。

採用構成（すべて実績ある部品の組み合わせ）:

1. **ポーリングタイマー`LauncherWatchHover`（120ms）**: `LauncherWatchDrag`(30ms)と同じ「ShowLauncherで開始・CloseLauncherで停止」パターン。ドラッグの30msタイマーには**触らない**（不可侵）。用途が違うので周期も別
2. **どのListBoxの上か**: `MouseGetPos`の第4引数（**フラグ2=hwndモード**）で直下コントロールのhwndを取り、`LauncherLbH.Hwnd`/`LauncherLbS.Hwnd`と比較。掴みしろのhwnd判別と同じ発想
3. **何番目の項目か**: `LB_GETTOPINDEX(0x18E)`＋`LB_GETITEMHEIGHT(0x1A1)`＋`LB_GETCOUNT(0x18B)`の3つの標準Win32メッセージで行計算。`LB_ITEMFROMPOINT`は使わない（項目より下の空白部で「最寄り項目」を返す罠があり、右クリック昇格と共用するには危険）。固定高ListBox（オーナードローなし）なので行計算は正確
4. **表示**: 組み込み`ToolTip()`。**変化検知つき**（前回表示内容と同じなら再呼び出ししない）。これで`Flash`のトーストとチャンネルを共有しても潰し合わない
5. **時刻**: `ClipHistory`を`{text: 本文, time: "HH:mm"}`のオブジェクト配列に変更。影響範囲は`PushClipHistory`（生成・重複比較）、`ShowLauncher`の履歴ループ、`PasteHistoryAt`の3箇所で全部。非永続・上限10・重複昇格のセマンティクスは不変。重複昇格時は新オブジェクトを積むので**時刻も最新に更新される**（望ましい副作用）

## D. 要望D（昇格）の結論: IniWrite不採用、UTF-8のFileAppend追記

**`IniWrite`は検証の結果、使えない。** 理由は3つ:

1. **【致命的】エンコーディング**: `IniWrite`の実体はWinAPIの`WritePrivateProfileString`で、これは**UTF-16 LE BOMのファイル以外をANSI（日本語環境ではCP932）として書く**。`snippets.ini`は`FileRead(path, "UTF-8")`で読むUTF-8運用なので、日本語ラベル・本文を`IniWrite`すると1ファイル内にUTF-8とCP932が混在し、次の`LoadSnippets`で化ける。既存コードが`IniRead`を避けた理由（「非ASCIIキーをUTF-16 LE以外で誤読する既知の問題」）と**同一の地雷ファミリの書き込み側**
2. **セクション必須**: `IniWrite`はセクション名が必須で、セクションレス運用の`snippets.ini`末尾に`[何か]`行を勝手に追加する。`LoadSnippets`は`[`行を読み飛ばすので即死はしないが、ユーザーが手編集するファイルの体裁を勝手に変える
3. **独自`\n`エスケープとの整合検証が割に合わない**: WinAPIは値の引用符処理など独自挙動があり、「書いた内容が`LoadSnippets`で読み戻せるか」の検証コストが、自前1行追記より高い

採用: **`FileAppend(label "=" 本文, path, "UTF-8")`による末尾1行追記**。

- **追記オンリー**が唯一の安全な書き方。全体再生成（parse→書き戻し）はユーザーのコメント・空行・並び順を破壊するので却下
- エスケープは`LoadSnippets`の逆変換そのもの: `CRLF→LF`正規化 → `LF→"\n"`。読み側が`\n→LF`するので往復一致
- ラベルはInputBoxでユーザーが決める（初期値=本文先頭12字・空白圧縮済み）。パーサ予約文字（`=`、`;`、`[`）はラベルから黙って除去
- **右クリック競合は存在しない**: 既存の`ContextMenu`ハンドラは`ctrl`引数で押下先コントロールを判別している。現在の1行ラムダ（L286）を名前付き関数に昇格し、`ctrl = LauncherLbH`の分岐を足すだけ。掴みしろの固定解除は1文字も挙動が変わらない
- **フォーカス地雷の回避**: InputBoxがフォーカスを奪うと`CheckLauncherFocus`(150ms)がランチャーを閉じにくる。よって**本文をローカル変数に確保してから自分で`CloseLauncher()`し、その後にInputBoxを出す**。タイマーとの競走をしない
- 項目特定は`ContextMenu`イベントの`Item`引数を**使わない**（ListBoxでは「フォーカス項目」であり、右クリックはフォーカスを動かさないので直前のクリック位置を返す罠）。C節と共用の`LauncherItemUnderMouse()`で決める

## E. 具体機構（既存実装との差分）

行番号は現ファイル実測。実装時は`grep -n`で再特定すること。差分は【回収】2ブロック＋【変更】4ブロック＋【追加】4ブロック。

### 回収リフォーム（機能変更なし・計-5行）— 先にやってビルド確認

**(R1) `ToggleStartup`を三項演算子化（L113-119、-2行）**

```autohotkey
ToggleStartup(*) {
    IsStartupRegistered() ? DisableStartup() : EnableStartup()
    RefreshStartupMenuLabel()
}
```

**(R2) `EnableStartup`のtry/catch圧縮（L99-106、-3行）**

```autohotkey
EnableStartup() {
    try FileCreateShortcut(A_ScriptFullPath, StartupShortcutPath(), A_ScriptDir), Flash("次回のWindows起動時から自動で立ち上がります", 1800)
    catch as e
        Flash("スタートアップ登録に失敗しました: " . e.Message, 2000)
}
```

成功トーストをtry内にカンマ連結で移動。例外時はスキップされるので挙動同値。

### 変更（既存行の書き換え・計±0〜+2行）

**(M1) グローバル宣言（L21・L23）**

```autohotkey
global ClipHistory := [], ClipHistoryMax := 10   ; {text,time}の配列・メモリのみ・非永続（なぞってコピー経由のみ）
global LauncherGui := 0, LauncherTarget := 0, LauncherTab := 0, Snippets := [], LauncherDragBar := 0, LauncherPos := "", LauncherPinned := false, LauncherLbH := 0, LauncherLbS := 0, LauncherHoverLast := ""
```

**(M2) `PushClipHistory`（L169-179、±0行）**: 比較を`v.text = text`に、挿入を時刻付きオブジェクトに。

```autohotkey
    for i, v in ClipHistory
        if (v.text = text) {
            ClipHistory.RemoveAt(i)   ; 重複は先頭へ昇格（時刻も更新される）
            break
        }
    ClipHistory.InsertAt(1, {text: text, time: FormatTime(, "HH:mm")})
```

**(M3) `ShowLauncher`（L253-292）**: ①global宣言に`LauncherLbH, LauncherLbS, LauncherHoverLast`を追記 ②履歴ループの`RegExReplace(v, ...)`→`RegExReplace(v.text, ...)` ③ローカル`lbH`/`lbS`をグローバル`LauncherLbH`/`LauncherLbS`にリネーム（各3参照） ④ContextMenu行（L286）を差し替え ⑤タイマー開始を1行追加:

```autohotkey
    LauncherGui.OnEvent("ContextMenu", LauncherContextMenu)
    ...
    SetTimer(CheckLauncherFocus, 150)
    SetTimer(LauncherWatchDrag, 30)
    LauncherHoverLast := "", SetTimer(LauncherWatchHover, 120)   ; ホバー監視（変化検知の記憶もリセット）
```

**(M4) `PasteHistoryAt`（L294-301、±0行）**: `text := ClipHistory[idx]` → `text := ClipHistory[idx].text`。
**(M4b) `CloseLauncher`（L338-348、+1行）**: `SetTimer(LauncherWatchDrag, 0)`の直後に:

```autohotkey
    SetTimer(LauncherWatchHover, 0), ToolTip()   ; ホバー監視停止・出しっぱなしのツールチップを消す
```

### 追加（新規関数4つ・`LauncherWatchDrag`の直後に配置、計+58行程度）

**(A1) 項目ヒットテスト（ホバーと右クリック昇格で共用）**

```autohotkey
; マウス直下のListBox項目番号(1始まり)。項目外・末尾より下の空白部は0。
; LB_ITEMFROMPOINTは空白部で「最寄り項目」を返す罠があるため、行計算(TOPINDEX/ITEMHEIGHT/COUNT)で厳密に判定する
LauncherItemUnderMouse(lb) {
    MouseGetPos &mx, &my
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " . lb.Hwnd)
    if (mx < cx || mx >= cx + cw || my < cy || my >= cy + ch)
        return 0
    ih := SendMessage(0x1A1, 0, 0, , "ahk_id " . lb.Hwnd)   ; LB_GETITEMHEIGHT
    idx := (ih > 0) ? SendMessage(0x18E, 0, 0, , "ahk_id " . lb.Hwnd) + (my - cy) // ih + 1 : 0   ; LB_GETTOPINDEX起点
    return (idx < 1 || idx > SendMessage(0x18B, 0, 0, , "ahk_id " . lb.Hwnd)) ? 0 : idx   ; LB_GETCOUNT超=空白部
}
```

**(A2) ホバー監視タイマー**

```autohotkey
; ホバー監視: 直下項目の全文(+履歴は時刻)をToolTip表示。ListBoxは項目単位ツールチップ非対応のため
; 自前ポーリング（ドラッグ監視と同じ思想）。変化検知つき: 同内容の再表示をしないのでFlashのトーストと共存できる
LauncherWatchHover() {
    global LauncherGui, LauncherLbH, LauncherLbS, LauncherHoverLast, ClipHistory, Snippets
    if !IsObject(LauncherGui)
        return
    MouseGetPos , , , &ctrlHwnd, 2   ; フラグ2=hwndで受ける（既定のClassNNだとHwnd比較が永遠に不一致）
    lb := (ctrlHwnd = LauncherLbH.Hwnd) ? LauncherLbH : (ctrlHwnd = LauncherLbS.Hwnd) ? LauncherLbS : 0
    idx := lb ? LauncherItemUnderMouse(lb) : 0
    tip := ""
    if (lb = LauncherLbH && idx >= 1 && idx <= ClipHistory.Length)
        tip := ClipHistory[idx].time . " にコピー`n" . SubStr(ClipHistory[idx].text, 1, 600)
    else if (lb = LauncherLbS && idx >= 1 && idx <= Snippets.Length)
        tip := SubStr(Snippets[idx].value, 1, 600)
    if (tip != LauncherHoverLast) {
        LauncherHoverLast := tip
        ToolTip(tip)   ; 空文字なら非表示
    }
}
```

**(A3) ContextMenuハンドラ（L286の1行ラムダを置換する名前付き関数）**

```autohotkey
; 右クリック: 掴みしろ=固定解除 / 履歴項目=定型文へ昇格（ctrl=押下先コントロールで分岐、競合なし）
LauncherContextMenu(g, ctrl, item, isRC, x, y) {
    global LauncherDragBar, LauncherLbH, LauncherPos, LauncherPinned
    if (ctrl = LauncherDragBar) {
        LauncherPos := "", LauncherPinned := false
        Flash("固定を解除しました（次回からカーソル位置に表示）")
    } else if (ctrl = LauncherLbH)
        PromoteHistoryAt(LauncherItemUnderMouse(LauncherLbH))   ; Item引数は使わない（右クリックはフォーカスを動かさない罠）
}
```

**(A4) 昇格本体**

```autohotkey
; 履歴→定型文昇格。IniWriteは不採用: 実体のWritePrivateProfileStringはUTF-16 LE以外をANSI(CP932)で書くため、
; UTF-8のsnippets.iniに日本語が混在エンコーディングで書かれて化ける（IniReadを避けた既存コメントと同族の地雷）。UTF-8明示のFileAppendで追記する
PromoteHistoryAt(idx) {
    global ClipHistory
    if (idx < 1 || idx > ClipHistory.Length)
        return
    text := ClipHistory[idx].text
    CloseLauncher()   ; InputBoxがフォーカスを奪うとCheckLauncherFocusが閉じにくるため、先に自分で閉じる
    ib := InputBox("この内容を定型文に登録します。名前を入力:", "定型文に昇格", "w380 h120", SubStr(RegExReplace(text, "\s+", " "), 1, 12))
    label := (ib.Result = "OK") ? RegExReplace(Trim(ib.Value), "[=\[\];]") : ""   ; パーサ予約文字は黙って除去
    if (label = "")
        return
    body := StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "\n")   ; LoadSnippetsの\n形式へ逆変換（往復一致）
    path := A_ScriptDir . "\snippets.ini"
    try {
        nl := (FileExist(path) && !RegExMatch(FileRead(path, "UTF-8"), "\R$")) ? "`n" : ""   ; 末尾改行がなければ補う
        FileAppend(nl . label . "=" . body . "`n", path, "UTF-8")
        Flash("定型文に登録しました: " . label, 1800)
    } catch as e {
        Flash("登録に失敗しました: " . e.Message, 2000)
    }
}
```

**行数収支**: 400 −5（R1/R2） ＋2（M3/M4b） ＋約59（A1〜A4・空行込み） ＝ **約456行。新上限460行内・余白4行**。超過したらB節の縮退優先順位に従うこと。

## F. MVP（今すぐやるなら最小の一手）

1. **回収＋データ構造だけ**（R1/R2＋M1/M2/M4の`ClipHistory`オブジェクト化）→ 約395行。`scripts/build.ps1`でビルド → なぞってコピー→ランチャー→クリックペースト・数字キー・重複昇格の回帰確認。見た目は何も変わらないのが正。**ここで一度コミット**（構造変更と機能追加を混ぜない）
2. **ホバー（要望C）**: A1＋A2＋M3の⑤＋M4b → 約425行。履歴・定型文両タブでツールチップ、リスト外で消える、掴みしろドラッグ中に変な表示が出ないことを確認。コミット
3. **昇格（要望D）**: A3＋A4＋M3の④ → 約456行。ビルド → reality-checkerに動作判定を委任（検証観点はH-1）

## G. 捨てた案と理由

- **ListViewへの全面置き換え**: 再々却下。前回・前々回と同じ理由（回帰リスク・実装コスト）に加え、今回はポーリング＋ToolTipで要件を満たせることが確定したので、置き換えの動機が完全に消えた
- **IniWriteでの書き込み**: 却下。D節の3理由（ANSI書き込みでUTF-8ファイル破壊・セクション強制追加・エスケープ整合の検証コスト）
- **snippets.ini全体を読んで再生成する書き込み**: 却下。ユーザーの手書きコメント・空行・並び順を破壊する。「ユーザーが編集するファイル」への安全な機械書き込みは追記オンリー
- **TTN_GETDISPINFO/サブクラス化によるネイティブツールチップ**: 却下。ドラッグ実装で「PostMessage/WM_NCHITTESTが理論通り動かなかった」実績のあるGuiスタイル構成で、さらに繊細なフック系を試す理由がない
- **OnMessage(WM_MOUSEMOVE)でのホバー検知**: 却下。理論上は動くはずだが、まさにその「理論上動くはず」をドラッグで踏んだ。ポーリングなら失敗モードが存在しない
- **LB_ITEMFROMPOINTによるヒットテスト**: 却下。空白部で「最寄り項目」を返すため、右クリック昇格と共用すると「空白を右クリックしたら末尾項目が昇格される」誤爆になる
- **ContextMenuイベントの`Item`引数で項目特定**: 却下。ListBoxではフォーカス項目を返すが、右クリックはフォーカスを動かさないので「前にクリックした別の項目」を返す罠
- **右クリックで1項目メニュー（「定型文に登録」）を出す**: 見送り。直接InputBoxでも「初期値入り・Escでキャンセル」で誤爆リスクは低い
- **昇格時の重複ラベル検査**: 見送り。`LoadSnippets`は重複ラベルを両方表示するので壊れはしない
- **時刻の永続化・日付表示**: 却下。`ClipHistory`は非永続（セッション限定）なので日付は常に今日。"HH:mm"で必要十分
- **掴みしろ右クリックとの機能統合（どこを右クリックしても共通メニュー）**: 却下。押した場所で意味が決まる現設計の方が説明可能性が高い

## H. 地雷と回避策

1. **【最重要】実機検証項目**: (a) 履歴ホバーで時刻+全文が出る／(b) 隣の項目へ移動で差し替わる／(c) リスト外・空白部・掴みしろ上では消える／(d) 掴みしろドラッグが従来どおり動く（ホバータイマー追加の影響なし）／(e) 履歴項目の**左**クリックは従来どおり即ペースト（右クリックだけが昇格）／(f) 掴みしろ右クリック=固定解除が不変／(g) 昇格→再度ランチャーを開くと定型文タブに増えている／(h) 昇格した定型文の`\n`が実改行でペーストされる（往復一致）／(i) snippets.iniに日本語コメントや`;`入り本文がある状態で昇格しても既存行が無傷
2. **`MouseGetPos`の第5引数は必ず`2`（hwndモード）**。省略するとClassNN文字列が返り、`.Hwnd`との比較が黙って永遠に不一致＝ホバーが一切出ないのに原因が見えない
3. **`ClipHistory`オブジェクト化の変更漏れ**: AHK v2でオブジェクトと文字列を`=`比較してもエラーにならず単にfalseなので、`PushClipHistory`の重複判定を書き換え忘れると「重複排除が黙って死ぬ」。`grep -n "in ClipHistory\|ClipHistory\["`で3関数（PushClipHistory/ShowLauncher/PasteHistoryAt）全部の書き換えを確認すること
4. **InputBoxの前に必ず`CloseLauncher()`**。順序を逆にすると`CheckLauncherFocus`(150ms)がフォーカス喪失を検知してランチャーを破棄し、タイマーと競走することになる
5. **`FileAppend`のエンコーディング引数`"UTF-8"`を省略しない**。省略するとANSIで書かれ、IniWriteを却下した理由と同じ壊れ方をする
6. **ホバーの変化検知（`LauncherHoverLast`）を省かないこと**。毎tick無条件に`ToolTip()`を呼ぶと、空文字tickが`Flash`のトーストを120ms以内に消してしまう。変化検知はグローバルにする（`ShowLauncher`でのリセットが必須）
7. **`LauncherWatchDrag`(30ms)には一切触らない・統合しない**。周期も関心も別
8. **昇格の既知の限界（許容・ドキュメント化のみ）**: ①本文中に**リテラルの`\n`という2文字**があると読み戻し時に実改行になる ②本文の先頭・末尾の空白はTrimで落ちる ③同名ラベルの重複は両方表示される
9. **既存構造の不可侵領域**: `-Caption +AlwaysOnTop +ToolWindow +Border`・`CoordMode "Mouse", "Screen"`・Tab3構成・`LoadSnippets`（読み側は1文字も変えない）・`ClipHistory`の非永続・XButton1許可リストゲート・数字キーHotIfブロック・`LauncherWatchDrag`・`CloseLauncher`の`LauncherGui := 0`
10. **ビルドは必ず`scripts/build.ps1`**（Git BashからAhk2Exe直叩き厳禁）。zip同梱の`snippets.ini`テンプレートは変更不要
11. **規模**: 今回で約456行・新上限460行。次の要望（右クリックメニュー化・重複検査・定型文の削除/編集UI・履歴の永続化の再燃を含む）は実装せず、次回会議に差し戻すこと。460超えが必要になったら緩和ではなく`#Include`分離を議題にする
