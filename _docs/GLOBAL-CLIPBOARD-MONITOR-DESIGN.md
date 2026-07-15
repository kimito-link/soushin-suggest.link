# 設計書: グローバルクリップボード監視（ユーザー操作限定フィルタ＋フルセット安全網）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 460行)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・4/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-15

## 【重要】方針転換の経緯

このプロジェクトは複数回にわたり「許可リスト方式・非永続設計」を安全性の核として
グローバル監視を却下してきたが、製品オーナー（ユーザー）が明確な意思決定として
「便利さを安全性の売り文句より優先する」「規模拡大を受け入れ、フルセットの安全網付きで
グローバル監視を実装してほしい」と決定した。この決定に基づき、[`CLIBOR-PARITY-JUDGMENT.md`](CLIBOR-PARITY-JUDGMENT.md)
の却下判定を覆し、本設計を確定する。

**460行という防衛線は正式に撤廃する。** 約655行を目標水準とする（F節参照）。
**ただし履歴の非永続（メモリのみ）は維持する** — これが今回も撤廃しない最後の安全特性。

## 裏取りメモ（司令塔による検証）

Fableが引用した行番号（ClipHistory宣言:L21、`~LButton up::`:L145、`LoadSitesConfig`:L32、
`ShowLauncher`:L247、`PasteText`:L316）はいずれも実ファイルとおおむね一致（多少のズレは
実装時の`grep -n`再特定で吸収可能）。設計の中核判断（除外フォーマット尊重、ユーザー操作
限定フィルタ、多層防御構成）はいずれも実装的に妥当と判断。

---

## A. 理想の体験フロー

1. ユーザーはどのアプリでも普通に Ctrl+C / Ctrl+X / 右クリック→コピー / なぞってコピーをする。
2. コピーした瞬間、送信サジェストが黙って履歴に積む（トーストも音もなし。なぞってコピー時のみ既存の「コピーしました」Flashを維持）。
3. サイドボタン長押し or Ctrl+Win+V でクイックペーストを開くと、**アプリを問わず**直近30件が並んでいる。選択・数字キー・ホバー・定型文昇格は今までどおり。
4. 見られたくない項目は右クリック→「この履歴を削除」で即消える。全部消したいときは「履歴を全削除」（ランチャー右クリック・トレイメニューの両方から）。
5. KeePass/1Password等でパスワードをコピーしても、(a)除外フォーマット尊重で最初から載らない、(b)載ってしまっても自動クリア検知で数十秒後に履歴からも消える、(c)それでも残ったら手動削除、の3層で守られる。
6. バックグラウンドのプロセスが勝手にクリップボードへ書いた内容は、**ユーザー操作限定フィルタにより履歴に入らない**（本設計の核心）。
7. トレイメニューから監視の一時停止（プライベートモード）を1クリックで切替できる。

## B. グローバル監視の実装方式

### 結論: 捕捉は全アプリ対象。安全の軸は「アプリの種類」ではなく「操作の種類」に移す

- **捕捉（履歴に積む側）: 全アプリ**。許可リストで絞らない。便利さ優先の決定に従う。
- **送信（キーを送る側）: 従来どおり許可リスト限定**。なぞってコピーの`Send("^c")`や右クリック長押しの`{Enter}`を未知のアプリへ送るのは別種の危険（ターミナルの割り込み等）であり、ここは変えない。捕捉と送信は別軸である。
- 補助として`[clipboard] exclude=`による**除外リスト（プロセス名）**を用意する。「許可リストの復活」ではなく、パスワードマネージャ等をピンポイントで外すオプトアウト。

### 二重のゲート: ユーザー操作限定フィルタ + デバウンス

`OnClipboardChange`発火時に次を全て通ったものだけ履歴に積む。

1. **自己書き込み除外**: `PasteText()`等で自分が`A_Clipboard`に書いた直後（500ms）は無視。
2. **除外フォーマット尊重**: `Clipboard Viewer Ignore` / `ExcludeClipboardContentFromMonitorProcessing`フォーマットが載っていたら無視（KeePass・1Password・KeePassXC等が設定する業界標準。Cliborも尊重している）。`IsClipboardFormatAvailable`はクリップボードを開かずに判定できるためコールバック内で安全。
3. **デバウンス**: 発火のたびに`SetTimer(CaptureClip, -120)`を張り直す（trailing-edge）。Office系の多重発火・中間状態を1回に潰す。
4. **ユーザー操作限定フィルタ（核心）**: 捕捉時点で「直近1000ms以内に (a) ^c/^x/^Insのキー押下、(b) なぞってコピーの`Send("^c")`実行、(c) LButton解放」のいずれかがあったこと。なければ**捨てる**（fail-closed）。(c)を含めるのは右クリックメニューの「コピー」やアプリ内コピーボタンを取りこぼさないため。
5. **除外プロセス判定**: `GetClipboardOwner`のプロセス名（取れなければ前面ウィンドウ）が除外リストにあれば捨てる。
6. **サイズ・空チェック**: 空文字と100,000文字超は捨てる（切り詰め保存はペースト結果を壊すのでしない）。

ターミナルのCtrl+C（割り込み）はクリップボードが変化しないので`OnClipboardChange`自体が発火せず、自然に除外される。

## C. 安全網の実装

### C-1. 削除機能（必須）

- **個別削除**: 履歴ListBox上の右クリックでポップアップメニューを出す。現行は右クリック＝即昇格だが、これをメニュー化して「定型文に登録」「この履歴を削除」「履歴を全削除」の3択にする。既存の昇格機能はメニューの1項目として温存。
- **全削除**: 上記メニューに加え、**トレイメニューにも「クリップボード履歴を全削除」**を置く（ランチャーを開かずに消せることが重要 — 開くと画面に内容が映るため）。
- 確認ダイアログは付けない。「即座に削除できる」ことが要件であり、非永続データなので誤削除の被害は軽微。
- 削除後はランチャーを閉じずにListBoxをin-placeで再構築する（`Delete()`→`Add()`。Changeイベントは発火しないので誤ペーストは起きない）。

### C-2. 自動クリア検知

パスワードマネージャの多くは「コピー→N秒後に`EmptyClipboard`」で自動クリアする。AHKでは これが`ClipChanged(0)`として観測できる。

- 判定ロジック: **type=0（クリア）を受信し、かつ直近の捕捉が45秒以内**なら、その捕捉テキストと一致する履歴エントリを`ClipHistory`から削除し、`Flash("自動クリアを検知したため履歴からも削除しました")`を出す。
- 閾値45秒の根拠: 主要マネージャの既定クリア時間は10〜30秒（1Password=90秒設定可）。45秒で大半をカバーしつつ、無関係のクリアを巻き込みにくい。`[clipboard] autoclear=`で変更可能にする。
- 限界: クリアではなく**ダミー文字列で上書きする**タイプのマネージャは検知できない。だからこそC-1/除外フォーマット/除外リストとの多層防御にする（I-7参照）。

### C-3. 高エントロピー除外は実装しない

会議判定どおり誤検知が多く、オプトインの補助機能程度の価値しかない。今回のスコープから**明示的に外す**（将来`[clipboard] entropy=on`を足せる余地だけコメントで残す）。行数と複雑性の節約。

### C-4. 監視の一時停止

トレイメニューに「クリップボード監視を一時停止」（チェックマーク切替）。`ClipWatchOn := false`でClipChangedが捕捉をスキップ。画面共有中・配信中の即時オプトアウト手段。

## D. 既存「なぞってコピー限定」機構との統合

**監視パスを1本化する。** `~LButton up::`のドラッグ検知は「^cを送る」役目だけを残し、`PushClipHistory`の直呼びを削除する。送られた^cによるクリップボード変化はClipChanged→CaptureClipが拾う（ドラッグハンドラが`LastUserCopyTick`を明示更新するのでフィルタを確実に通過する）。

- `PushClipHistory()`関数自体は温存（重複昇格・上限管理のロジックはそのまま使う）。呼び出し元がCaptureClipの1箇所になるだけ。
- 「コピーしました」Flashはドラッグハンドラに残す（体験の連続性）。
- `ClipHistoryMax`は10→**30**に引き上げ（`[clipboard] max=`で変更可）。グローバル監視では10件はすぐ流れる。数字キーは従来どおり先頭10件のみ、11件目以降は番号なし表示にする（現行の履歴側フォーマッタは全件に`Mod(A_Index,10)`を振っており、11件目に「1」が付くバグが顕在化するので修正必須。定型文側の`(i <= 10 ? ... : "   ")`と同じ方式に揃える）。
- `XButton1`長押しランチャーの許可リストゲートは**撤去を推奨**（データソースがグローバルになった以上、呼び出しもグローバルであるべき。`^#v`は既に全アプリで有効であり整合する）。短押し=スクショは全アプリで維持。
- `ShowLauncher`の空メッセージ「なぞってコピーすると貯まります」→「コピーすると貯まります」に更新。

## E. 具体機構（既存実装との差分）

### E-1. グローバル変数の追加（L18付近）

```autohotkey
global ClipWatchOn := true                ; トレイから一時停止可
global LastUserCopyTick := 0              ; ^c/^x/^Ins・なぞってコピー送信の時刻
global LastLButtonUpTick := 0             ; 右クリックメニュー「コピー」等のクリック由来を救う
global SelfClipTick := 0                  ; 自分がA_Clipboardへ書いた時刻(監視除外)
global LastCaptureText := "", LastCaptureTick := 0   ; 自動クリア検知用
global ClipUserWindowMs := 1000           ; ユーザー操作限定フィルタの窓(iniに出さない・固定)
global ClipAutoClearSec := 45, ClipMaxLen := 100000
global ClipExcludeExes := Map("keepass.exe",1, "keepassxc.exe",1, "1password.exe",1, "bitwarden.exe",1)
```

既存L21のコメント「（なぞってコピー経由のみ）」→「（ユーザー操作由来のグローバル監視）」に変更、`ClipHistoryMax := 30`。

### E-2. ユーザー操作の記録（新規ホットキー＋既存ハンドラ改修）

```autohotkey
; ユーザー発のコピー操作を時刻だけ記録する(~でキー自体は素通し)
~^c::
~^x::
~^Ins:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}
```

`~LButton up::`（L145）は先頭で解放時刻を記録し、履歴直積みをやめる:

```autohotkey
~LButton up:: {
    global CopyOnSelect, dragX, dragY, dragT, LastLButtonUpTick, LastUserCopyTick
    LastLButtonUpTick := A_TickCount          ; コンテキストメニュー由来のコピーを救う
    if !CopyOnSelect || !CopyOnSelectApp()
        return
    MouseGetPos &x, &y
    dt := A_TickCount - dragT
    if (Abs(x - dragX) < 30 && Abs(y - dragY) < 30) || dt < 150 || dt > 15000
        return
    prev := A_Clipboard
    LastUserCopyTick := A_TickCount           ; フィルタを確実に通す
    Send("^c")
    Sleep 150
    if (A_Clipboard != "" && A_Clipboard != prev)
        Flash("コピーしました", 800)          ; 履歴追加はClipChangedに一本化
}
```

### E-3. 監視本体（新規・約70行）

```autohotkey
OnClipboardChange(ClipChanged)   ; 起動時セクション(LoadSitesConfigの隣)で登録

ClipChanged(type) {
    global ClipWatchOn, SelfClipTick
    if (A_TickCount - SelfClipTick < 500)     ; PasteText等の自己書き込み
        return
    if (type = 0) {                           ; クリア → 自動クリア検知
        MaybeDropAutoCleared()
        return
    }
    if (type != 1 || !ClipWatchOn)            ; 非テキスト・一時停止中
        return
    if ClipHasIgnoreFormat()                  ; パスワードマネージャの標準除外フォーマット
        return
    SetTimer(CaptureClip, -120)               ; 多重発火デバウンス(最後の発火から120ms後に1回)
}

CaptureClip() {
    global LastUserCopyTick, LastLButtonUpTick, ClipUserWindowMs, ClipMaxLen
    global LastCaptureText, LastCaptureTick
    now := A_TickCount
    ; ★核心の安全策: 直近1秒以内のユーザー操作がなければ捨てる(fail-closed)
    if (now - LastUserCopyTick > ClipUserWindowMs) && (now - LastLButtonUpTick > ClipUserWindowMs)
        return
    if ClipSourceExcluded()
        return
    text := ""
    try text := A_Clipboard                   ; 遅延レンダリング元が死んでいると失敗しうる
    if (text = "" || StrLen(text) > ClipMaxLen)
        return
    LastCaptureText := text, LastCaptureTick := now
    PushClipHistory(text)
}

; クリップボードを開かずに判定できるためコールバック内でも安全
ClipHasIgnoreFormat() {
    static fmts := [DllCall("RegisterClipboardFormat", "Str", "Clipboard Viewer Ignore", "UInt"),
                    DllCall("RegisterClipboardFormat", "Str", "ExcludeClipboardContentFromMonitorProcessing", "UInt")]
    for f in fmts
        if DllCall("IsClipboardFormatAvailable", "UInt", f)
            return true
    return false
}

ClipSourceExcluded() {
    global ClipExcludeExes
    exe := ""
    if (hwnd := DllCall("GetClipboardOwner", "Ptr")) {
        DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid := 0)
        try exe := StrLower(ProcessGetName(pid))
    }
    if (exe = "")
        try exe := StrLower(WinGetProcessName("A"))
    return exe != "" && ClipExcludeExes.Has(exe)
}

MaybeDropAutoCleared() {
    global ClipHistory, LastCaptureText, LastCaptureTick, ClipAutoClearSec
    if (LastCaptureText = "" || A_TickCount - LastCaptureTick > ClipAutoClearSec * 1000)
        return
    for i, v in ClipHistory
        if (v.text = LastCaptureText) {
            ClipHistory.RemoveAt(i)
            Flash("自動クリアを検知したため履歴からも削除しました", 1500)
            break
        }
    LastCaptureText := ""
}
```

### E-4. 自己書き込みマーク（PasteText改修、L316）

```autohotkey
PasteText(text) {
    global LauncherTarget, SelfClipTick
    SelfClipTick := A_TickCount
    A_Clipboard := text
    ...(以下既存のまま)
}
```

### E-5. 削除UI（LauncherContextMenu改修＋新規3関数）

既存の`else if (ctrl = LauncherLbH)`分岐を差し替え:

```autohotkey
    } else if (ctrl = LauncherLbH) {
        idx := LauncherItemUnderMouse(LauncherLbH)
        if (idx < 1 || idx > ClipHistory.Length)
            return
        SetTimer(CheckLauncherFocus, 0)       ; メニュー表示中の誤クローズ防止(必須・I-5参照)
        m := Menu()
        m.Add("定型文に登録", (*) => PromoteHistoryAt(idx))
        m.Add("この履歴を削除", (*) => DeleteHistoryAt(idx))
        m.Add("履歴を全削除", (*) => DeleteHistoryAll())
        m.Show()
        if IsObject(LauncherGui)
            SetTimer(CheckLauncherFocus, 150)
    }
```

```autohotkey
DeleteHistoryAt(idx) {
    global ClipHistory
    if (idx >= 1 && idx <= ClipHistory.Length)
        ClipHistory.RemoveAt(idx)
    RefreshLauncherHistory()
}

DeleteHistoryAll(*) {                          ; トレイメニューからも呼ぶため可変引数
    global ClipHistory
    ClipHistory := []
    RefreshLauncherHistory()
    Flash("履歴を全削除しました", 1200)
}

RefreshLauncherHistory() {
    global LauncherGui, LauncherLbH
    if !IsObject(LauncherGui)
        return
    LauncherLbH.Delete()
    LauncherLbH.Add(HistoryListItems())
}

; ShowLauncherの履歴フォーマット部を関数化して共用。11件目以降は番号なし(数字キー対象外)
HistoryListItems() {
    global ClipHistory
    items := []
    for i, v in ClipHistory {
        s := RegExReplace(v.text, "\s+", " ")
        items.Push((i <= 10 ? Mod(i, 10) . " " : "   ") . (StrLen(s) > 58 ? SubStr(s, 1, 58) . "…" : s))
    }
    return items
}
```

`ShowLauncher`内のhistItems構築ループは`LauncherLbH := LauncherGui.Add("ListBox", ..., HistoryListItems())`に置換。

### E-6. sites.ini 拡張（LoadSitesConfig改修、既存の分岐に追加）

```autohotkey
        else if (section = "clipboard") {
            k := StrLower(key)
            if (k = "watch")
                ClipWatchOn := (StrLower(val) != "off")
            else if (k = "max" && IsNumber(val))
                ClipHistoryMax := Integer(val)
            else if (k = "autoclear" && IsNumber(val))
                ClipAutoClearSec := val + 0
            else if (k = "exclude")
                for e in StrSplit(val, ",")
                    if (Trim(e) != "")
                        ClipExcludeExes[StrLower(Trim(e))] := 1
```

`global`宣言に`ClipWatchOn, ClipHistoryMax, ClipAutoClearSec, ClipExcludeExes`を追加。sites.ini同梱サンプルに`[clipboard]`セクションのコメント付き雛形を追記（`watch=on / max=30 / autoclear=45 / exclude=example.exe`）。

### E-7. トレイメニュー（起動時セクションに追加）

```autohotkey
A_TrayMenu.Add("クリップボード監視を一時停止", ToggleClipWatch)
A_TrayMenu.Add("クリップボード履歴を全削除", DeleteHistoryAll)

ToggleClipWatch(name, *) {
    global ClipWatchOn
    ClipWatchOn := !ClipWatchOn
    ClipWatchOn ? A_TrayMenu.Uncheck(name) : A_TrayMenu.Check(name)
    Flash(ClipWatchOn ? "クリップボード監視: 再開" : "クリップボード監視: 一時停止", 1200)
}
```

### E-8. XButton1 のゲート撤去

先頭の`if !(CopyOnSelectApp() || WinActive("ahk_exe mintty.exe"))`ブロックを削除し、長押し=ランチャーを全アプリで有効化。短押し=スクショは変更なし。

## F. 行数見積もり

| 項目 | 増減 |
|---|---|
| グローバル変数・コメント | +12 |
| ユーザー操作記録ホットキー | +8 |
| ClipChanged/CaptureClip/ClipHasIgnoreFormat/ClipSourceExcluded/MaybeDropAutoCleared | +75 |
| 削除UI（メニュー化・3関数・HistoryListItems共用化） | +52 |
| sites.ini `[clipboard]` パース | +14 |
| トレイメニュー2項目＋トグル関数 | +12 |
| 改修（LButton up・PasteText・ShowLauncher・XButton1）差し引き | +8 |
| セクションコメント | +12 |

**合計 約+195行 → 約655行**。目標の600〜700行に収まる。水増し要素（確認ダイアログ、エントロピー判定、設定GUI）は意図的に含めていない。

## G. MVP（段階的な実装順序）

1. **Phase 1 — 監視コア（これだけで出荷可能な最小単位）**: E-1〜E-4。OnClipboardChange＋ユーザー操作限定フィルタ＋自己書き込み除外＋除外フォーマット尊重＋デバウンス、`~LButton up`の直積み廃止。検証: メモ帳でCtrl+C→履歴に載る / PowerShellから`Set-Clipboard "injected"`を実行（キー・マウスに触れず）→**載らない** / ターミナルでCtrl+C割り込み→載らない。
2. **Phase 2 — 削除UI**: E-5＋E-7の全削除。右クリックメニュー3択とin-place更新。
3. **Phase 3 — 自動クリア検知・設定**: MaybeDropAutoCleared、E-6のini拡張、除外リスト。検証: KeePassXCでパスワードコピー→（除外フォーマットで最初から載らないことを確認）→フォーマットを付けないダミースクリプトで45秒クリアを模擬し履歴から消えることを確認。
4. **Phase 4 — 磨き**: E-7の監視トグル、E-8のXButton1ゲート撤去、`ClipHistoryMax=30`、空メッセージ文言、バージョン表記v1.3.0へ更新。

各Phaseは独立してコミット可能。Phase 1完了時点でreality-checkerに「注入テキストが載らないこと」の判定を委任すること。

## H. 捨てた案と理由

- **`AddClipboardFormatListener`直叩き**: AHK v2の`OnClipboardChange`が同APIの薄いラッパとして十分機能する。DllCallとメッセージポンプの自前管理は行数と地雷を増やすだけ。
- **`A_TimeIdlePhysical`による「最近何か入力があったか」判定**: 一見エレガントだが、ユーザーがタイピング中は常に真になり、作業中に走るバックグラウンド注入を素通しする。「コピーという操作」に紐づく明示シグナル（^c/^x/^Ins/LButton解放）に限定する方が防御として意味がある。
- **高エントロピー文字列の除外**: 会議判定どおり誤検知過多（UUID・コミットハッシュ・APIキーの正当コピーを潰す）。多層防御の他層で足りる。
- **履歴の永続化（ファイル保存）**: 「PCを落とせば全部消える」は残された最強の安全特性。Cliborとの差別化点でもある。
- **捕捉側の許可リスト限定**: 「便利さ優先」の決定に真っ向から反する。送信側の許可リストは維持するので誤爆リスクは増えない。
- **全削除の確認ダイアログ**: 「即座に消せる」ことが要件。非永続データで被害が軽微、かつダイアログは画面共有中の緊急削除を遅らせる。
- **削除をDeleteキーで**: ListBoxの選択変更＝即ペーストという既存UXのため「選択してからDel」が構造的に成立しない。右クリックメニューに一本化。
- **画像（type=2）の履歴**: スコープ外。テキストのみ。

## I. 地雷と回避策

1. **フィルタ窓の拡大は情報漏洩リスクの再導入**。`ClipUserWindowMs=1000`は意図的にsites.iniへ**出さない**（固定値）。「取りこぼしがある」という報告が来ても、窓を広げるのではなく取りこぼした操作の明示シグナル（例: 新たなキー）を追加する方向で直すこと。窓を2秒超にするとクリック頻度の高い通常作業中はほぼ常時開放になり、フィルタが形骸化する。
2. **`~^c`のSend自己トリガ**: ドラッグハンドラの`Send("^c")`は既定のSendInputではフックを叩かないが、将来SendEventに変えても実害はない（tickが更新されるだけで、それは意図どおりの動作）。ただし依存はせずE-2のとおり明示的に`LastUserCopyTick`を更新する。
3. **OnClipboardChangeコールバック内でクリップボードを開かない**。`A_Clipboard`の読み取りは必ずデバウンス後のタイマースレッド（CaptureClip）で行う。コールバック内で開くとコピー元アプリとのデッドロック・タイムアウトの温床。`IsClipboardFormatAvailable`は開かずに済むのでコールバック内でよい。
4. **Officeの遅延レンダリング**: コピー元が終了していると`A_Clipboard`読み取りが空や例外になる。CaptureClipの`try`＋空スキップで握りつぶす（削らないこと）。
5. **ポップアップメニュー中のCheckLauncherFocus誤爆**: `Menu.Show()`はブロッキングで、その間も150msタイマーは走る。フォーカス判定が揺れるとメニュー選択前にランチャーが破棄され、コールバックが古いidxで走る。E-5のとおり`m.Show()`の前後でタイマーを止めて再開する処理は**必須**。
6. **Suspend Hotkeysとの相互作用はfail-closedで正しい**: トレイのSuspend中はホットキーが止まりtickが更新されなくなるが、OnClipboardChangeは生き続ける。結果「Suspend中は何も履歴に載らない」— これは仕様として正しい挙動なので「直そう」としないこと。
7. **自動クリア検知の限界を過信しない**: `EmptyClipboard`型（type=0）しか検知できない。ダミー文字列上書き型のマネージャは検知不能。第一防衛線はあくまで除外フォーマット（業界標準対応マネージャは全て設定してくる）とexcludeリスト。README/LPの注意書きは別タスクだが、実装コメントには3層構造を明記しておく。
8. **RDP/VMのクリップボード同期（rdpclip.exe / VMwareツール）**: リモート側でコピーしてローカルに同期された変更は、ローカルのキー・マウス操作を伴わないためフィルタで弾かれ履歴に載らない。これはバグではなく仕様（非ユーザー発と区別不能）。問い合わせが来たら「リモート利用時は載らない」と案内する前提でコメントに残す。
9. **履歴30件化に伴う番号ラベルのバグ顕在化**: 現行の履歴フォーマッタは全件に`Mod(A_Index,10)`を振るため、11件目に「1」が付き数字キーと不整合になる。E-5の`HistoryListItems()`（`i <= 10`で番号打ち切り）への置換を忘れると、数字キー1を押したつもりが11件目でなく1件目がペーストされる混乱を生む。
10. **PushClipHistoryの重複昇格とペースト再捕捉**: 履歴からのペーストは`SelfClipTick`で捕捉除外されるため、「ペーストしただけで先頭に昇格する」ことはない（昇格するのは実際に再コピーしたときだけ）。この挙動を変えたければSelfClipTick除外を外すのではなく、CaptureClip側に意図的な分岐を足すこと。除外を外すと定型文のrun:以外の全ペーストが履歴を汚す。
