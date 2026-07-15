# 設計書: 送信サジェスト クイックペースト（ランチャー）機能

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`)を実地調査した上で設計
> / 素材収集=会議ハーネス(汎用会議、5体召集・5/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-15 ／ council-fable 3段構えワークフローの手順2〜3の産物

## 背景

マウスの「リア」ボタン（XButton1、現状は全画面スクリーンショット専用）に、
Clibor/PowerToys Run/Spotlight風の「クイック検索・ランチャー」機能を追加できないか、
というユーザーの発想が出発点。会議とFableの設計を経て、「アプリ起動ランチャー」ではなく
**「クリップボード履歴からのクイックペースト」**という、本製品の文脈に合った形に収束した。

## 裏取りメモ（司令塔による検証）

Fableは実コードを読んだ上で設計しており、L18-21のglobal宣言・L59付近のiniパーサ分岐・
L161-174のコピー処理関数・L185-203の右クリック長押し（`#HotIf`ゲート）・L213のXButton1、
という行番号の主張はいずれもおおむね正確（多少のズレはあるが対象箇所の特定に支障なし）。
設計の中核判断（許可リストによる長押し判定自体のゲート、なぞってコピー経由限定での
機密情報リスク回避、ToolTip代替案の技術的不成立の指摘）はいずれも実装的に妥当。

## 結論の要約

| 論点 | 結論 |
|---|---|
| ボタン | **XButton1に短押し/長押しを併存。ただし長押し判定そのものを許可リストでゲート**（許可リスト外では従来どおり押下即スクショ＝ゲーム中の挙動は1msも変わらない） |
| スコープ | **クリップボード履歴のみ（なぞってコピー経由・メモリ内10件・非永続）**。アプリ起動・ファイル検索・キーボード検索は不採用。定型文（snippets.ini）はPhase 2 |
| GUI | AHK v2 `Gui` + `ListBox` 1個、クリック1回でペースト。新規コード約90行、合計 235→約325行 |
| 名称 | 「ランチャー」ではなく **「クイックペースト」**（アプリを起動しないため） |

---

## A. 理想の体験フロー

「送信サジェスト」の中核ループは *なぞってコピー → AIチャットに貼る → 右クリック長押しで送信* である。現状このループには「直前にコピーしたもの1件しか貼れない」という穴がある。エラーメッセージとコード片の2つをAIに渡したいとき、ユーザーはウィンドウを往復して2回コピー&ペーストしている。

新機能はこの穴を塞ぐ:

1. ブラウザやエディタで、なぞってコピーを何回か行う（既存動作のまま。コピーのたびに履歴へ静かに積まれる）
2. AIチャット画面で **サイドボタン（戻る）を長押し（0.35秒）**
3. マウスカーソルの位置に、直近コピー最大10件のリストがポップアップ
4. 貼りたい行を **1クリック** → リストが消え、元のウィンドウにその内容がペーストされる
5. リスト外をクリック（またはEsc）でキャンセル

タイピングは一切不要。「AIとのやり取りをマウスだけで完結」という製品の軸をそのまま延長する。

## B. ボタン割り当ての結論

**案A（XButton1併存）を採用。ただし精密操作時の誤爆リスクは「長押し判定自体を許可リストでゲートする」ことで無効化する。** これにより会議で対立していた案A/案Bは偽の二択だったと判明。

```autohotkey
XButton1:: {
    if !(CopyOnSelectApp() || WinActive("ahk_exe mintty.exe")) {
        Send("#{PrintScreen}")   ; 許可リスト外: 従来と完全に同一（押下で即発火・遅延ゼロ）
        return
    }
    ...長押し判定...
}
```

- **ゲーム・3Dモデリング中（＝許可リスト外）**: 分岐の1行目で従来コードに落ちる。長押し判定は存在すらしないので誤爆リスクはゼロ。LPが明言する「許可リスト方式＝ゲーム中の誤爆を防ぐ」という設計思想と完全に一致する
- **許可リスト内（ブラウザ・ChatGPT.exe等）**: 短押し=スクショ（発火タイミングが「押下時」→「離した時」に変わるが、体感差は押している時間ぶんだけで実用上無視できる）、長押し=クイックペースト
- ミドルクリック案（案B）を退けた理由はFに詳述

閾値0.35秒は、**グローバル定数 `LongPressSec` に集約し、sites.ini の `[general]` セクションで上書き可能**にする（後述D）。既存の右クリック長押し（`"T0.35"`）も同じ定数を参照するよう統一する。

## C. スコープの結論

**クリップボード履歴のみ。アプリ起動・ファイル検索は不採用。** 理由:

1. **ブランド軸**: アプリ起動/ファイル検索は検索クエリのタイピングが前提で、「マウスだけで完結」と正面衝突する。クリップボード履歴は「リストから1クリック」で完結し、軸に沿う
2. **競合**: アプリ起動ならPowerToys Run/Fluent Searchが無料で存在し、¥980の個人ツールが薄い実装で勝てる領域ではない。「なぞってコピーした断片を複数ストックしてAIに渡す」は本製品の文脈でしか成立しない差別化
3. **規模**: インデックス構築・検索を持ち込むと235行の世界観（LPの「BY THE NUMBERS」）が崩壊する

クリップボード履歴の3リスク（メモリ・機密情報・永続化）は、**取得経路の限定**で3つ同時に潰す:

- **履歴に積むのは「なぞってコピー」が成功した瞬間だけ**。`OnClipboardChange` によるグローバル監視はしない。パスワードマネージャの自動コピーや他アプリのCtrl+Cは一切入らない。なぞってコピー自体が許可リスト内でしか動かないため、取得元も自動的に許可リスト内に限定される
- **メモリ内リングバッファ最大10件・ディスク書き込みなし・終了で消滅**。永続化の設計判断そのものを消す
- 1件あたり実用上数KBのテキスト×10件で、メモリは論点にならない

定型文（AIプロンプトのスニペット集）案は良いが**Phase 2**。snippets.ini（既存のini手書きパーサをそのまま流用可能）を読んでリスト上部に「★」付きで固定表示するだけで載る設計にしてあり、本設計のGUIを変更せずに追加できる（Fの「捨てた」ではなく「延期」）。

## D. 具体機構

追加は4ブロック・約90行。挿入位置つきで示す（実装時は`grep -n`で該当パターンを検索して正確な行を特定すること — 以下の行番号は目安）。

**(1) グローバルと閾値（L18-21の global 群に追加）**

```autohotkey
global ClipHistory := []        ; メモリのみ・非永続
global ClipHistoryMax := 10
global LongPressSec := 0.35     ; sites.ini [general] longpress= で上書き可
global LauncherGui := 0
global LauncherTarget := 0
```

冒頭（`#SingleInstance` 直後）に `CoordMode "Mouse", "Screen"` を追加すること。v2の既定はClient座標なので、これがないとポップアップがカーソル位置に出ない。既存のなぞってコピー判定は相対距離しか見ていないため影響なし。

**(2) sites.iniパーサ拡張（既存のelse if分岐の後に1分岐追加）**

```autohotkey
        else if (section = "general" && StrLower(key) = "longpress" && IsNumber(val))
            LongPressSec := val + 0
```

sites.iniに `[general]` セクションのコメント付き雛形を追記（`;longpress=0.35 ; ゲーミングマウス等で誤反応する場合は大きく`）。右クリック長押しの`"T0.35"`も `"T" . LongPressSec` に置換して閾値を一本化。

**(3) 履歴への積み込み（既存のコピー成功分岐に1行）**

```autohotkey
    if (A_Clipboard != "" && A_Clipboard != prev) {
        PushClipHistory(A_Clipboard)          ; ← 追加はこの1行だけ
        ToolTip("コピーしました")
```

```autohotkey
PushClipHistory(text) {
    global ClipHistory, ClipHistoryMax
    for i, v in ClipHistory
        if (v = text) {
            ClipHistory.RemoveAt(i)   ; 重複は先頭へ昇格
            break
        }
    ClipHistory.InsertAt(1, text)
    while (ClipHistory.Length > ClipHistoryMax)
        ClipHistory.Pop()
}
```

**(4) XButton1改修とGUI（既存の `XButton1::Send("#{PrintScreen}")` を置換）**

```autohotkey
; --- サイドボタン(戻る): 短押し=スクショ / 対応アプリでは長押し=クイックペースト ---
XButton1:: {
    global LongPressSec
    if !(CopyOnSelectApp() || WinActive("ahk_exe mintty.exe")) {
        Send("#{PrintScreen}")
        return
    }
    if KeyWait("XButton1", "T" . LongPressSec) {
        Send("#{PrintScreen}")
        return
    }
    KeyWait("XButton1")
    ShowLauncher()
}

ShowLauncher() {
    global ClipHistory, LauncherGui, LauncherTarget
    if (ClipHistory.Length = 0) {
        ToolTip("履歴がありません（なぞってコピーすると貯まります）")
        SetTimer () => ToolTip(), -1800
        return
    }
    LauncherTarget := WinExist("A")           ; ペースト先を先に記憶
    CloseLauncher()
    LauncherGui := Gui("-Caption +AlwaysOnTop +ToolWindow +Border")
    LauncherGui.SetFont("s10", "Meiryo UI")
    items := []
    for v in ClipHistory {
        s := RegExReplace(v, "\s+", " ")
        items.Push(StrLen(s) > 40 ? SubStr(s, 1, 40) . "…" : s)
    }
    lb := LauncherGui.Add("ListBox", "w340 r" . Min(items.Length, 10), items)
    lb.OnEvent("Change", PasteFromLauncher)
    LauncherGui.OnEvent("Escape", (*) => CloseLauncher())
    MouseGetPos &mx, &my
    LauncherGui.Show("x" . mx . " y" . my)
    WinActivate("ahk_id " . LauncherGui.Hwnd)
    SetTimer(CheckLauncherFocus, 150)         ; リスト外クリックで閉じる
}

PasteFromLauncher(lb, *) {
    global ClipHistory, LauncherTarget
    idx := lb.Value
    if (idx < 1)
        return
    text := ClipHistory[idx]
    CloseLauncher()
    A_Clipboard := text
    if (LauncherTarget && WinExist("ahk_id " . LauncherTarget))
        WinActivate("ahk_id " . LauncherTarget)
    Sleep 150
    Send("^v")
}

CheckLauncherFocus() {
    global LauncherGui
    if !IsObject(LauncherGui) {
        SetTimer(CheckLauncherFocus, 0)
        return
    }
    if !WinActive("ahk_id " . LauncherGui.Hwnd)
        CloseLauncher()
}

CloseLauncher() {
    global LauncherGui
    SetTimer(CheckLauncherFocus, 0)
    if IsObject(LauncherGui) {
        try LauncherGui.Destroy()
        LauncherGui := 0
    }
}
```

行数見積: (1)〜(4)合計で約90行。**235行 → 約325行**。「1ファイル・サーバーもAIも使わない」は不変。LPの「BY THE NUMBERS」の行数表記を出している場合は数値の更新が必要（G参照）。

## E. MVP（今すぐやる最小の一手）

上記(1)〜(4)そのもの。これ以上削るものがない構成にしてある。順序:

1. `CoordMode` + グローバル追加 + `PushClipHistory` + コピー成功分岐への1行フック（この時点で履歴が貯まる。GUIなしでも壊れない）
2. XButton1改修 + `ShowLauncher` 一式
3. パーサの `[general]` 分岐と右クリック長押しの閾値統一
4. `scripts/build.ps1` でビルド（Git Bashから直接Ahk2Exeを叩かない）、reality-checkerに動作判定を委任

検証観点: (a) 許可リスト外アプリでXButton1押下→即スクショ（遅延なし）、(b) ブラウザで短押し→スクショ/長押し→リスト、(c) リスト1クリック→元ウィンドウにペースト、(d) リスト外クリック→閉じるだけで何も起きない、(e) 履歴0件で長押し→ToolTip案内のみ。

## F. 捨てた案と理由

- **ミドルクリック長押しに割り当て（案B）**: 却下。(1) MButtonは既にGit Bash呼び出しで押下即発火しており、長押し判定を足すとそちらに遅延が入る、(2) ホイールボタンの0.35秒長押しは物理的に硬く、押している間にホイールが回って誤スクロールしやすい、(3) 案Bの根拠だった「精密操作時の誤爆」は許可リストゲートで消滅するため、移す理由自体がなくなった
- **XButton2（進む）への割り当て**: 未使用ボタンなので一見最安だが、許可リスト＝主にブラウザであり、ブラウザ内でこそ「進む」は現役。スクショと違い「戻る/進む」を両方潰すのはLPの説明とも整合しない
- **アプリ起動・ファイル検索**: Cで詳述。タイピング前提でブランド軸と衝突、PowerToys Runと正面競合、規模爆発
- **`OnClipboardChange` によるグローバル履歴**: 機密情報（パスワードマネージャ等）を無差別に吸う。なぞってコピー経由限定なら仕様説明も「自分でなぞったものだけが履歴になる」の一文で済む
- **履歴のディスク永続化**: 機密リスクと「サーバーも保存もしない軽さ」の売りに反する。再起動で消えるのは仕様として明記する
- **ToolTip拡張による疑似UI**: ToolTipはヒットテスト（クリック判定）を持たない純粋な表示物であり、「クリックで選ぶ」というマウス完結UIが原理的に作れない
- **検索ボックス付きGUI（Edit + インクリメンタル検索）**: 10件のリストに検索は不要。キーボードを持ち込んだ瞬間にブランド軸を踏む

## G. 地雷と回避策

1. **ビルド**: 必ず `scripts/build.ps1` を使う。Git BashからAhk2Exe直叩きは引数が壊れる（既知）
2. **座標系**: `CoordMode "Mouse", "Screen"` を入れ忘れるとマルチモニタ/最大化以外でポップアップ位置がずれる。実装時の最頻出バグ予測ポイント
3. **フォーカス監視タイマーの競合状態**: `Show` 直後にGUIがまだアクティブでないタイミングで `CheckLauncherFocus` が走ると即閉じする。上記コードでは `Show` → `WinActivate` → `SetTimer` の順にして回避している。順序を崩さないこと
4. **ペーストの取りこぼし**: `WinActivate` 直後の `Send ^v` はフォーカス移行前に飛ぶことがある。`Sleep 150` を挟んである。ChatGPT.exe等Electron系で落ちる場合は250まで伸ばす
5. **短押しスクショの発火タイミング変化**: 許可リスト内のみ「押下時→離した時」に変わる。リリースノートに一行書く。許可リスト外は完全無変更なのでゲーマーへの説明は不要
6. **`$` プレフィックス不要**: 新XButton1ハンドラはXButton1自身をSendしないため自己再帰なし
7. **LP文言修正（別タスクに切り出し）**: (a) サイドボタンの説明に「対応アプリでは長押しでクイックペースト（直近コピー10件から1クリックで貼り付け）」を追記、(b) 「BY THE NUMBERS」の行数を実測値に更新、(c) 許可リスト方式の説明に「クイックペーストも許可リスト内でのみ動作」を追加。sites.iniの `[general]` コメント雛形の追記は実装タスクに含める
8. **Phase 2（snippets.ini）着手時の注意**: パーサは既存の手書きパーサを流用し、`IniRead` は使わない（非ASCIIキー誤読の既知の罠。定型文のラベルは日本語になるため必ず踏む）
