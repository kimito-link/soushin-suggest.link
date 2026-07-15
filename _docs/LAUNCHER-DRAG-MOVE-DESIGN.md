# 設計書: クイックペーストポップアップのドラッグ移動（掴みしろ方式）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 実測397行)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・5/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-15 ／ 対象ブランチ: feature/launcher-color-numkey
> 前提: [`LAUNCHER-COLOR-NUMKEY-DESIGN.md`](LAUNCHER-COLOR-NUMKEY-DESIGN.md)（実装済み）の拡張

## 裏取りメモ（司令塔による検証）

Fableが引用した行番号（ShowLauncher:L271、Gui生成:L281、CloseLauncher:L356、数字キー
HotIfブロック:L375-379）はすべて実ファイルと完全一致。`ToolTip(`呼び出し18回（9対）も
主張と一致。設計の中核判断（現実装はカーソル追従していないという事実に基づき発散案を
却下、掴みしろのhwnd/座標比較による構造的な競合回避）はいずれも実装的に妥当と判断。

## 【実装時の追記】OS委譲ドラッグは実機で動かず、ポーリング方式に変更

D節で設計した`PostMessage(0xA1, 2, ...)`（WM_NCLBUTTONDOWN+HTCAPTION）によるOS委譲ドラッグ、
および代替のWM_NCHITTESTフック方式は、いずれも実機検証で**掴みしろをドラッグしてもウィンドウが
動かない**という結果になった（原因未特定。AHK v2の`Gui`が生成するウィンドウクラス、または
`ToolWindow`スタイルとの組み合わせで、これらのメッセージが期待通りに処理されない可能性がある）。

最終的に採用したのは、**30msポーリングタイマーで「掴みしろ領域内での左クリック押下」を検知し、
検知したら`GetKeyState("LButton","P")`が真の間`Gui.Move()`でウィンドウ座標を手動追従させる**
という、より低レベルだが確実な方式（`LauncherWatchDrag`関数）。実機で動作確認済み。

この方式変更に伴う差分:
- `LauncherDragStart`（PostMessage版）は削除、`LauncherWatchDrag`（ポーリング版）に置換
- `SetTimer(LauncherWatchDrag, 30)`を`ShowLauncher`で開始、`CloseLauncher`で停止
  （既存の`CheckLauncherFocus`と同じ start/stop パターンに合わせた。ドラッグそのものは
  ポーリングで検知するため、数字キーのような「常設登録・解除処理なし」の思想は
  この一点だけ踏襲できなかった。ただしタイマーのstart/stopは`CloseLauncher`の
  全経路を通るため、残留リスクは実質的にない）
- 行数調整のため、既存のコメントブロック等を圧縮し400行ちょうどに着地（D節の見積もりより
  ポーリング版の方が数行重かったため）

D節のコード例（PostMessage版）は設計思想の記録として残すが、**実装は下記の差し替え版を
正としてCursorや今後の実装者は参照すること**。

## 結論の要約

| 論点 | 結論 |
|---|---|
| 実装方式 | **専用の掴みしろバー＋OS委譲ドラッグ（`PostMessage` WM_NCLBUTTONDOWN/HTCAPTION）**。追従/固定トグル案は却下 |
| リスト競合 | `OnMessage(WM_LBUTTONDOWN)`ハンドラ内で**押下先hwndが掴みしろか否かを判定**。ListBox/Tabへのクリックは別hwndに届くため、構造的に競合ゼロ |
| ライフサイクル | `OnMessage`は**起動時に一度だけ常設登録・解除処理なし**（数字キーHotIfと同一思想） |
| 位置記憶 | **メモリ内のみ（セッション限定）**。一度ドラッグしたら以後は最終位置に固定表示、掴みしろの**右クリックで解除**（カーソル位置表示に復帰）。ファイル永続化は却下 |
| 規模 | 397行 → 回収リファクタ(-15) ＋ 機能追加(+14) ＝ **約396行**。400行防衛線内・余白4行 |

---

## A. 理想の体験フロー

1. サイドボタン長押し → 従来どおりカーソル位置にポップアップ。ただし最上部に**高さ12pxの薄い色のバー（掴みしろ）**が付いている
2. バーを左クリックで掴む → ウィンドウが**吸い付いて**マウスに追従（OSネイティブのウィンドウ移動そのもの。タイトルバーを掴んだのと同じ滑らかさ）。ボタンを離した位置で止まる。ドラッグ中にEscを押すとOS標準の移動キャンセル
3. リスト項目のクリック選択・数字キー・Escクローズ・フォーカス喪失クローズは**一切変わらない**。バー以外のどこを押してもウィンドウは動かない
4. 一度でもドラッグしたら「固定モード」: 次にポップアップを開くと**前回置いた位置**に出る（例: 画面右下の定位置に置いて使い続けられる）
5. カーソル位置表示に戻したくなったら**掴みしろを右クリック** → トースト「固定を解除」→ 次回からカーソル位置に復帰
6. アプリ再起動でまっさら（カーソル位置表示）に戻る。`ClipHistory`と同じ非永続の潔さ

## B. 実装方式の結論: 掴みしろバー ＋ OS委譲ドラッグ

**会議収束案（専用ドラッグハンドル）を採用。「追従/固定トグル」案は却下。**

- **却下理由（トグル案）**: 会議で「ウィンドウを物理的にドラッグするのではなく、カーソル追従モード⇔固定モードをトグルする」という発散案が出たが、これは「ウィンドウがカーソルに追従している」ことを前提にした状態遷移。実地調査の通り**現実装は追従していない**（表示時に一度置くだけ）。トグル案を成立させるには、まずマウス追従のタイマー処理を*新規に追加*する必要があり、行数節約どころか純増になる。さらに「追従中のウィンドウの上でリストをクリックする」という新たな競合も生む
- **採用理由（掴みしろ）**: 競合回避が**判定式1つで構造的に完結**する。Win32ではクリックの`WM_LBUTTONDOWN`は「押された子ウィンドウ(hwnd)」に届く。ListBoxを押せばListBoxのhwnd、タブ帯を押せばTab3のhwnd、掴みしろを押せば掴みしろ(Static)のhwndに届く。ハンドラで**掴みしろのhwndのときだけ**反応すれば、リスト選択との競合は原理的に起きない
- **ドラッグ処理自体はOSに丸投げ**: `PostMessage(0xA1, 2, ...)`（WM_NCLBUTTONDOWN + HTCAPTION）でOSの「タイトルバー掴んだ扱い」のモーダル移動ループに入る。マウス追従・座標計算・ボタン解放検知のコードが**一切不要**（AHKコミュニティの定石パターン）。WM_NCHITTESTのフックも不要
- **数字キーとの一貫性**: `OnMessage(0x201, ...)`は起動時に一度だけ常設登録し、`ShowLauncher`/`CloseLauncher`では登録も解除もしない。ハンドラ先頭のガード（`IsObject(LauncherGui) && hwnd = LauncherDragBar.Hwnd`）が偽なら即return＝不発。数字キーの「常設登録＋HotIfスコープ限定」と完全に同じ思想で、「解除し忘れ」という概念自体が存在しない。ドラッグ中の状態もOS所有のモーダルループなので、ボタン解放で必ず終わり、スクリプト側に残留状態を持たない

## C. 位置記憶の結論: メモリ内のみ・「初ドラッグで固定化」セマンティクス

**セッション内メモリのみ。ファイル永続化は却下。**

- `ClipHistory`が意図的に非永続である既存設計と一貫させる。「PCを点けている間の作業姿勢」を覚えるだけで十分
- ファイル永続化の却下理由: `sites.ini`/`snippets.ini`は**ユーザーが編集する設定ファイル**であり、アプリが書き戻す状態ファイルではない（この線引きを壊すと編集競合の地雷が生まれる）。新規ファイルを増やせばini書き込み+読み込み+パースで10行超、400行防衛線に対して割に合わない
- セマンティクス: グローバル`LauncherPinned`（bool）と`LauncherPos`（`{x, y}` or `""`）の2つ。**掴みしろを一度でも掴んだら`LauncherPinned := true`**。以後、`CloseLauncher`が破棄直前に`WinGetPos`で最終位置を`LauncherPos`に保存し、次回`Show`はカーソル位置ではなく`LauncherPos`を使う。**掴みしろ右クリックで両方リセット**（解除）
- 「表示のたびに`Destroy()`→再生成」の使い捨て設計は**そのまま維持**する。位置だけを2つのグローバルに退避する、最小の状態追加

## D. 具体機構（既存実装との差分）

差分は【回収】4ブロック＋【追加】5ブロックの計9ブロック。すべて`dist/soushin-suggest.ahk`（行番号は現ファイル実測・裏取り済み。実装時は`grep -n`で再特定すること）。

### 回収リフォーム（機能変更なし・計-15行）— 先にやってビルド確認すること

**(R1) トースト用ヘルパー`Flash`を追加し、9箇所の`ToolTip`+`SetTimer`対を1行化（-5行）**

```autohotkey
Flash(msg, ms := 1500) {
    ToolTip(msg)
    SetTimer () => ToolTip(), -ms
}
```

置換例: `ToolTip("コピーしました")`＋`SetTimer () => ToolTip(), -800` → `Flash("コピーしました", 800)`。9箇所すべて。**各所のms値（-2000/-1800/-1500/-1200/-800）を正確に引き継ぐこと**。

**(R2) 3行関数4つをファットアロー1行化（-8行）**

```autohotkey
CopyOnSelectApp() => CurrentSendMode() != ""
StartupShortcutPath() => A_Startup . "\soushin-suggest.lnk"
IsStartupRegistered() => FileExist(StartupShortcutPath()) ? true : false
StartupLabelFor(registered) => registered ? "Windows起動時に自動実行: ON" : "Windows起動時に自動実行: OFF"
```

`CopyOnSelectApp`は`#HotIf`ディレクティブから呼ばれるが、アロー定義でも関数であることに変わりなく挙動不変。

**(R3) グローバル宣言の統合（-2行）**

```autohotkey
global CopyOnSelect := true, dragX := 0, dragY := 0, dragT := 0
global ClipHistory := [], ClipHistoryMax := 10   ; メモリのみ・非永続（なぞってコピー経由のみ）
```

**(R4) ランチャー系グローバル行に3変数を追記（±0行）**

```autohotkey
global LauncherGui := 0, LauncherTarget := 0, LauncherTab := 0, Snippets := [], LauncherDragBar := 0, LauncherPos := "", LauncherPinned := false
```

### 機能追加（計+14行）

**(A1) `ShowLauncher`: global宣言の追記＋掴みしろの追加（+1行）**

```autohotkey
    global ClipHistory, LauncherGui, LauncherTarget, Snippets, LauncherTab, LauncherDragBar, LauncherPos, LauncherPinned
    ...
    LauncherGui := Gui("-Caption +AlwaysOnTop +ToolWindow +Border")   ; ← 無変更
    LauncherGui.SetFont("s12", "Meiryo UI")                            ; ← 無変更
    LauncherDragBar := LauncherGui.Add("Text", "w460 h12 BackgroundD4DCE8")   ; 掴みしろ（ここだけドラッグ可）
    LauncherTab := LauncherGui.Add("Tab3", "w460 -Wrap", ...)          ; ← 無変更（バーの下に自動配置される）
```

global宣言への3変数追記は**必須**。特に(A2)のクロージャが`LauncherPos`/`LauncherPinned`へ代入するため、外側関数で`global`宣言されていないとクロージャ内ローカルが生成される（AHK v2のassume-local）。

**(A2) `ShowLauncher`: 固定解除の右クリック（`OnEvent("Escape", ...)`行の直後に+1行）**

```autohotkey
    LauncherGui.OnEvent("ContextMenu", (g, ctrl, *) => ctrl = LauncherDragBar ? (LauncherPos := "", LauncherPinned := false, Flash("固定を解除しました（次回からカーソル位置に表示）")) : 0)
```

掴みしろ以外（ListBox上など）の右クリックは`ctrl = LauncherDragBar`が偽で何もしない。

**(A3) `ShowLauncher`: 表示位置の分岐（既存の`MouseGetPos`→`Show`部分の書き換え、±0行）**

```autohotkey
    MouseGetPos &mx, &my
    LauncherGui.Show(LauncherPos != "" ? "x" . LauncherPos.x . " y" . LauncherPos.y : "x" . mx . " y" . my)
```

判定は`LauncherPinned`ではなく`LauncherPos != ""`で行う（`WinGetPos`が万一失敗して座標未保存でも安全に既定動作へ落ちる、fail-closed）。

**(A4) `CloseLauncher`: 破棄直前に位置を退避（+2行）**

```autohotkey
CloseLauncher() {
    global LauncherGui, LauncherPos
    SetTimer(CheckLauncherFocus, 0)
    if IsObject(LauncherGui) {
        if LauncherPinned
            try WinGetPos(&x, &y, , , LauncherGui), LauncherPos := {x: x, y: y}
        try LauncherGui.Destroy()
        LauncherGui := 0                      ; ← 第1ガードの実体。触らない
    }
}
```

すべてのクローズ経路（Esc・項目選択・フォーカス喪失タイマー・再表示時の先行Close）がここを通るため、退避漏れの経路は存在しない。

**(A5) ドラッグハンドラ＋常設登録（+10行）**

関数は`CloseLauncher`の直後に（7行+空行1）:

```autohotkey
LauncherDragStart(wParam, lParam, msg, hwnd) {
    global LauncherPinned
    if !(IsObject(LauncherGui) && IsObject(LauncherDragBar) && hwnd = LauncherDragBar.Hwnd)
        return
    LauncherPinned := true
    PostMessage(0xA1, 2, 0, , LauncherGui)   ; WM_NCLBUTTONDOWN + HTCAPTION = OSの移動ループに委譲
}
```

登録は「起動時」セクション、数字キーのHotIfブロックの直後に（コメント1+実行1=2行）:

```autohotkey
; 掴みしろのドラッグ移動: OnMessageは常設登録・ガードで不発化（数字キーHotIfと同思想、解除処理なし）
OnMessage(0x201, LauncherDragStart)   ; WM_LBUTTONDOWN
```

ハンドラを名前付き関数にするのは意図的（トップレベルのアロー関数内での代入はローカル化されるため、`global`宣言できる通常関数が必須）。

**行数収支**: 397 −15（R1〜R3） ＋14（A1〜A5） ＝ **約396行。400行防衛線内・余白4行**。はみ出た場合の削りしろ: (A5)のコメント1行、`Flash`前後の空行。それでも超えるなら(A2)の固定解除機能（+1行）と(A4)の2行を削って「ドラッグ移動のみ・記憶なし」に縮退すること（機能の優先順位: 移動 > 記憶 > 解除）。

## E. MVP（今すぐやるなら最小の一手）

1. **回収リフォームのみ**（R1〜R3、機能変更ゼロ）→ 382行。`scripts/build.ps1`でビルド → 既存4系統（短押しスクショ/クリック選択ペースト/`run:`起動/`\n`展開）＋トースト表示の回帰確認。**ここで一度コミット**（機能と回収を混ぜない）
2. **ドラッグ移動のみ**（A1＋A5から`LauncherPinned := true`行を除いた6行版）→ 約393行。掴みしろで動く・リスト選択が壊れていないことを確認
3. **位置記憶＋固定解除**（A2/A3/A4＋A5のpinned行）→ 約396行。ビルド → reality-checkerに動作判定を委任（検証観点はGの1・5）

## F. 捨てた案と理由

- **追従/固定トグル案**: 却下。現実装は追従型ではなく置き型なので、この案は前提から成立しない。追従タイマーを新設する必要があり行数純増＋新たな競合源。B節参照
- **`WM_NCHITTEST`をフックして上部領域をHTCAPTION扱いにする**: 却下。座標計算（クライアント座標変換・バー領域判定）が必要で行数増。計算を1px誤るとタブ帯やリストがドラッグ領域化する、まさに会議が警告した競合の温床。hwnd比較（計算ゼロ・誤判定の余地ゼロ）が上位互換
- **`WM_MOUSEMOVE`を自前追跡する手動ドラッグ**: 却下。追従・解放検知・キャプチャ管理で30行級。OS委譲(`0xA1`)の存在意義がない
- **`+Caption`を付けてタイトルバーで動かす**: 却下。既存スタイル不可侵の原則に正面から抵触。見た目も壊れる
- **ファイル永続化（sites.ini拡張 or 新規position.ini）**: 却下。C節参照。「ユーザーが編集する設定」と「アプリが書く状態」の線引きを守る
- **掴みしろのダブルクリックで固定解除**: 却下。1回目の押下が即モーダル移動ループに入るため、コントロールにダブルクリックが届かない（構造的に不可能）。右クリックなら`WM_LBUTTONDOWN`ハンドラと完全に干渉しない
- **掴みしろに「≡ ドラッグで移動」等のラベル表示**: 見送り。s12フォントだとバーが高くなり縦幅を食う。色付きバーだけで掴める見た目は成立しており、要望が出たら+2行で追加可能とだけ記録
- **GUI背景(hwnd = LauncherGui.Hwnd)もドラッグ可能にする**: 見送り。(A5)の条件に`|| hwnd = LauncherGui.Hwnd`を足すだけ（+0行）で余白部分も掴めるようになるが、「掴める場所は1つ」の方が説明可能性が高い。実機で掴みしろが窮屈なら+0行で開放してよい
- **モニタ構成変化時の座標クランプ**: 見送り。`MonitorGet`系で5行超。セッション限定メモリなので露出は小さい（G-6参照）

## G. 地雷と回避策

1. **【最重要】競合の実機検証**。実装後の必須テスト:
   (a) 掴みしろドラッグでリスト項目が選択されない／(b) リスト項目クリックでウィンドウが動かず従来どおり即ペースト／(c) タブ帯クリックでタブ切替のみ／(d) 数字キーがドラッグ後も正常／(e) ドラッグ中にEsc → 移動キャンセルのみでポップアップは開いたまま、その後Escで閉じる
2. **(A5)のガードは`IsObject(LauncherGui)`を必ず左端に**（短絡評価）。順序を崩すと`LauncherGui=0`のとき全システムの左クリックごとに`.Hwnd`エラー。`OnMessage`ハンドラは全アプリの左クリック経路上にいる自覚を持つこと
3. **`OnMessage`の解除コードを書かないこと**。`ShowLauncher`/`CloseLauncher`に`OnMessage(0x201, ..., 0)`のような解除を足す改変は、数字キーで排除した「ライフサイクル管理」の復活であり却下。ガードで不発化が正
4. **`CheckLauncherFocus`との共存**: OSの移動ループ中もランチャーはアクティブのままなので、150msタイマーが発火しても`WinActive`が真で閉じない見込み。ただし実機確認必須（万一ドラッグ中に閉じる場合は、`LauncherDragStart`でタイマー停止→委譲→再開の+2行で対処。現時点では入れない）
5. **ドラッグが反応しない場合の代替**: AHKのTextコントロールは`OnEvent`未登録なら`SS_NOTIFY`なしでマウスをキャプチャしない設計だが、環境によりドラッグが始まらない場合は(A5)の`PostMessage`行の後に`return 0`を足して元メッセージを遮断する（+1行）。同様に`ContextMenu`イベントがTextコントロール上で発火しない場合は`OnMessage(0x204, ...)`を同思想で追加登録
6. **モニタ外への固定**: 外部モニタに固定→切断すると次回表示が画面外に出うる。復帰手段は「トレイからExit→再起動」（セッションメモリなのでリセットされる）。既知の限界として受容し、クランプ実装はしない
7. **Flash置換は機械的に・ms値を落とさない**（R1参照）。catch節内・`e.Message`連結ありの箇所も、置換後`return`を残すこと
8. **既存構造の不可侵領域**: `-Caption +AlwaysOnTop +ToolWindow +Border`・`CoordMode "Mouse", "Screen"`・Tab3構成・`LoadSnippets`・`ClipHistory`・XButton1の許可リストゲート・数字キーHotIfブロック・`CloseLauncher`の`LauncherGui := 0`。今回の差分はいずれにも1行も触れない（(A4)は同関数内への挿入だが既存行は無変更）
9. **ビルドは必ず`scripts/build.ps1`**（Git BashからAhk2Exe直叩き厳禁・既知の地雷）。今回ini追加なし・zip同梱リスト変更なし、exe再ビルドのみ
10. **規模**: 今回で約396行・余白4行。次の要望（バーへのラベル表示・座標クランプ・永続化の再燃・背景ドラッグ開放を含む）は実装せず、次の機能会議に差し戻すこと
