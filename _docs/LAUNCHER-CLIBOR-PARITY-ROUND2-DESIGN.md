# 設計書: ランチャー履歴のClibor同等化・第2ラウンド（ワンショット整形/変換・改行分割系・検索ショートカット）

> 3段構え（会議ハーネス→Fable設計→実装）の成果物。COUNCIL-HOWTO.md準拠。
> 会議ハーネス素材: `tsuioku-no-kirameki.com/council/soushin-suggest-clibor-parity-round2.md` / `.answers.json`
> 設計: Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 3338行/v1.22.8)を実地調査した上で設計。
> 前提: `_docs/SNIPPET-MANAGER-CLIBOR-PARITY-DESIGN.md`（2026-07-17）の中核判断（`NoSort NoSortHdr`必須・行番号ベース書き換え・絞り込み中の並び替え禁止）は全て維持する。
> 対象ファイル: `dist/soushin-suggest.ahk`

## 発端（経緯の訂正）

第1ラウンド（コミット58f8b27）は、ユーザーが見せたスクリーンショットを「soushin-suggest本体の別ウィンドウ機能」と誤認して設計・実装した（削除の永続化バグ修理＋メニュー拡充は有効な成果として残る）。実際のスクリーンショットは**別アプリ「Clibor」本体**（バージョン2.3.4）の右クリックメニューだった。真の要望は「soushin-suggest本体にCliborと同じ機能、さらに便利な機能を実装する」こと（Clibor併用をやめられるレベルを目指す）。

## A. 現状の要約（実地調査で確認した事実）

- **ランチャー右クリックメニュー** `LauncherContextMenu` L3011-3048。履歴側はテキスト項目に「開く／定型文に登録／コピーのみ／削除／全削除…／管理画面」。クロージャは要素参照`v`を束縛する流儀（メニュー表示中の新規コピーによるidxズレ対策、第1ラウンドで導入済み）。メニュー表示中は`SetTimer(CheckLauncherFocus, 0)`で誤クローズを止め、`m.Show()`（ブロッキング）後に再開する。
- **ペースト経路**: `PasteHistoryAt`(L1679)→`PasteText`(L1769)。`PasteText`は`SelfClipTick`を記録してから`A_Clipboard`に書き、`LauncherTarget`をアクティブ化して`Send("^v")`。`ClipChanged`は`SelfClipTick`から500ms以内の変化を自己書き込みとして無視する。
- **履歴捕捉の安全弁**: `CaptureClip`(L1809)は「直近1秒以内のユーザー操作がなければ捨てる」fail-closed。**`~^c`/`~^x`/`~^Ins`の受動フック（`~`付き・キーを奪わない）が既にL589-593に存在する**。FIFO/LIFO設計の重要な前例。
- **永続化**: `PushClipHistory`(L620)→`QueueTextArchive`→45+2秒検疫→`CommitPendingArchive`が唯一のディスク書き込み地点。
- **表示上限**: `FillLauncherHistoryLV`(L3219)は`DisplayMax := 500`で表示打ち切り・検索は全件走査。メモリ復元上限は`ClipHistLoadMax := 10000`。
- **検索**: ランチャーは`LauncherSearchEdit`が開いた瞬間に自動フォーカスされる。`^+f`は未使用（grep該当0件）。
- **数字キー**: ランチャー1-9,0＝1〜10番目ペースト、Shift+数字＝11〜20番目。

## B. 設計判断

### B-1. 6ギャップの優先順位

| 順位 | ギャップ | 判定 | 一言理由 |
|---|---|---|---|
| 1 | 整形・変換サブメニュー | **採用（MVP）** | 純関数・プライバシー影響ゼロ・GUI変更ゼロ（メニューのみ）・Clibor併用をやめる決定打 |
| 2 | 専用検索ショートカット ^+F | **採用（MVPに同梱）** | 管理画面側だけ追加。ランチャー側は自動フォーカス済みで実質実装済み |
| 3 | 改行ごとに履歴に展開 | **採用（第2歩）** | 明示操作＝許可リスト思想の範囲内。行数上限100で永続ストア肥大を抑止 |
| 4 | 改行ごとにFIFO/LIFO | **採用（第3歩）** | キューを履歴から分離すれば批判役の懸念は消える（B-3で検証） |
| 5 | ページ切り替え | **却下（再）** | B-4参照。検索全件走査＋管理画面履歴タブが既に上位互換 |

**会議の批判役（gpt-oss-120b）の懸念の検証結果**: 「FIFO/LIFOは大量の一時履歴を生成しクリップボード監視と衝突する」という指摘は、**FIFO/LIFOを『履歴への分割再登録』で実装した場合にのみ**成立する。本設計はキュー（`FifoQueue`、メモリのみ・履歴非登録）を`ClipHistory`から完全分離するため、履歴汚染・検疫キュー大量投入・監視との衝突はいずれも構造的に発生しない。装填（`A_Clipboard`への書き込み）は`SelfClipTick`により監視から除外される（既存`PasteText`と同一機構）。一方「履歴に展開」の方は本当に永続ストアへN行書くが、これはユーザーの明示的な項目単位の操作であり、展開元テキストは既に履歴・永続ストアに入っている（新しい機密が増えない）。よって懸念の半分は妥当（＝展開側に行数上限を付ける根拠）、半分は実装方式の選択で無効化できる。

### B-2. 「整形」「変換」の項目と実装方法

**動詞の設計判断**: Cliborの「クリップボードにセット（整形）」をそのまま持ってこない。ランチャーの行クリック＝即ペースト（`LauncherHistSelect`）という製品イディオムに合わせ、**「整形して貼り付け」「変換して貼り付け」**とする。「セットだけしたい」ニーズは既存の「コピーのみ（貼り付けない）」と同じ思想で**Shiftを押しながら項目を選ぶとコピーのみ**に割り当てる。

**整形（テキストの形を直す・6項目）**:
1. 改行を除去して1行に
2. 改行を半角スペースに
3. 前後の空白を削除
4. 各行の行頭・行末の空白を削除
5. 連続する空白を1つに
6. 引用記号(>)を除去

**変換（文字の種類を変える・6項目）**:
1. 大文字に (ABC)
2. 小文字に (abc)
3. 全角→半角（英数カナ）
4. 半角→全角（英数カナ）
5. ひらがな→カタカナ
6. カタカナ→ひらがな

**`LCMapStringW`の技術裏取り**（採用）: AutoHotkeyに全角半角・かな変換の組み込みは無く、`kernel32\LCMapStringW`が正解ルート。シグネチャは `int LCMapStringW(LCID, DWORD dwMapFlags, LPCWSTR src, int cchSrc, LPWSTR dest, int cchDest)`。勘所は3つ:
- LCIDは`0x0411`（ja-JP）を明示する。カナの半全変換はロケール依存。
- 2段呼び出し必須（`cchDest=0`で必要長を取得→バッファ確保→再呼び出し）。変換で文字数は増減する（半角ｶﾞ=2単位→全角ガ=1単位、逆は1→2）ため入力長のバッファ確保は不可。
- `cchSrc`にはAHK v2の`StrLen`をそのまま渡せる。`-1`（NUL含む）は渡さない。

会議で出た「日付時刻自動挿入・ランダム文字列生成」は不採用（F-4）。

### B-3. FIFO/LIFO・履歴展開の実装可否

**両方とも実装可。ただし設計条件つき。**

**FIFO/LIFO（第3歩）** — 製品思想との照合:
- 許可リストテスト: 本設計は**キー送信を一切しない**。貼り付け操作を実行するのは常にユーザー自身で、本機能は「次の行をクリップボードに装填し直す」だけ。→ 通過。
- 非永続テスト: キューはメモリのみ。装填は`SelfClipTick`付き自己書き込みで履歴に入らず、検疫キューにも入らない。→ 通過。
- **貼り付けトリガーの解**: サイドボタン横取りでも既存操作の変更でもなく、**受動フック`~^v`**を使う。`~`付きなのでCtrl+V自体は素通しされ、貼り付けを一切妨げない。この「グローバルに聞くだけで奪わない」パターンは`~^c`/`~^x`/`~^Ins`で既に採用済みの流儀。
- fail-closedの脱出口: (a) キューが尽きたら自動終了+Flash、(b) モード中に外部の新規コピーを検知したら即座にモードを中止、(c) 右クリックメニューに「連続貼り付けを中止」を出す。

**改行ごとに履歴に展開（第2歩）** — 明示的な項目単位の操作なので思想テストは素通り。条件は2つ: (a) 行数上限100（超過は中止Flash）、(b) 展開前に`CloseLauncher()`する（`PushClipHistory`は1回ごとに`RefreshLauncherHistory`を呼ぶため、開いたままN回展開するとN回の全再描画になる）。

### B-4. ページ切り替えの再検討

**履歴側でも却下を維持**（前回とは別の根拠で独立に判断）:
1. 検索が既に上位互換: 表示は500件打ち切りだが検索は`ClipHistory`全件（最大10000件）を走査する。
2. 全件をめくりたい体験の受け皿も既にある: 管理画面の履歴タブ（2000件表示+検索+時刻列）。
3. 物理制約: ランチャーは460px固定・垂直のみ拡張可。ページャUIは操作ヘッダー1本化の思想を壊す。
4. 将来「500件より深くを目視でめくりたい」が出た場合の予約席は時間フィルタ（直近10/50/200件・日付指定）であり、ページ切り替えは採らない。

### B-5. MVPの範囲

**整形6+変換6のサブメニュー（Shift=コピーのみ含む）+ 管理画面の^+F**。GUIコントロールの追加・変更ゼロ（`Menu`オブジェクトのみ）なので描画バグのリスク面がそもそも存在しないことがMVP選定の決め手。

## C. 具体的な文言・コード変更案

### C-1. 変換エンジン（新設・`NowWithWeekday`の後ろ辺りに配置）

```autohotkey
; --- ワンショット整形/変換。純関数のみ・履歴/ini/クリップボードに触らない ---
; LCMapStringW: AHKに無い全角半角・かな変換の正規ルート。LCID 0x0411(ja-JP)明示。
; 変換で文字数は増減する(半角ｶﾞ2単位→全角ガ1単位)ため、必要長の問い合わせ→確保の2段呼び出しが必須。
LCMapJa(text, flags) {
    if (text = "")
        return text
    n := DllCall("kernel32\LCMapStringW", "UInt", 0x0411, "UInt", flags
        , "Str", text, "Int", StrLen(text), "Ptr", 0, "Int", 0)
    if (n <= 0)
        return text                            ; 失敗時は原文のまま(fail-closed)
    buf := Buffer(n * 2, 0)
    n2 := DllCall("kernel32\LCMapStringW", "UInt", 0x0411, "UInt", flags
        , "Str", text, "Int", StrLen(text), "Ptr", buf, "Int", n)
    return n2 ? StrGet(buf, n2, "UTF-16") : text
}

; メニュー項目定義。fnは必ず「文字列→文字列」の純関数。
ClipTransformDefs() {
    static defs := 0
    if !defs
        defs := {format: [
            {name: "改行を除去して1行に",            fn: (t) => RegExReplace(t, "\R+", "")},
            {name: "改行を半角スペースに",          fn: (t) => RegExReplace(t, "\R+", " ")},
            {name: "前後の空白を削除",              fn: (t) => Trim(t, " `t`r`n　")},
            {name: "各行の行頭・行末の空白を削除",  fn: (t) => RegExReplace(t, "m)^[ `t　]+|[ `t　]+$", "")},
            {name: "連続する空白を1つに",           fn: (t) => RegExReplace(t, "[ `t　]{2,}", " ")},
            {name: "引用記号(>)を除去",             fn: (t) => RegExReplace(t, "m)^(>[ `t]?)+", "")}
        ], convert: [
            {name: "大文字に (ABC)",       fn: (t) => StrUpper(t)},
            {name: "小文字に (abc)",       fn: (t) => StrLower(t)},
            {name: "全角→半角 (英数カナ)", fn: (t) => LCMapJa(t, 0x00400000)},   ; LCMAP_HALFWIDTH
            {name: "半角→全角 (英数カナ)", fn: (t) => LCMapJa(t, 0x00800000)},   ; LCMAP_FULLWIDTH
            {name: "ひらがな→カタカナ",    fn: (t) => LCMapJa(t, 0x00200000)},   ; LCMAP_KATAKANA
            {name: "カタカナ→ひらがな",    fn: (t) => LCMapJa(t, 0x00100000)}    ; LCMAP_HIRAGANA
        ]}
    return defs
}

; AHK v2のforループ変数はクロージャに参照捕捉されるため、直接 (*) => Paste...(v, d.fn) と
; 書くと全項目が最後のfnになる(G-1)。必ずこのファクトリ経由で束縛を固定する。
MakeTransformHandler(v, fn) {
    return (*) => PasteTransformed(v, fn)
}

; 通常選択=変換して貼り付け / Shiftを押しながら選択=変換結果をコピーのみ。
; 貼り付け経路はPasteText(SelfClipTick付き)なので変換結果は履歴に入らない(原文が履歴の正)。
PasteTransformed(v, fn) {
    out := ""
    try out := fn(v.text)
    if (out = "") {
        Flash("結果が空になったため中止しました", 1500)
        return
    }
    copyOnly := GetKeyState("Shift", "P")
    CloseLauncher()
    if copyOnly {
        A_Clipboard := out
        Flash("変換結果をコピーしました（貼り付けはしていません）", 1400)
    } else
        PasteText(out)
}
```

### C-2. メニュー配線（`LauncherContextMenu`のテキスト分岐を拡張）

```autohotkey
        if (v.type = "text") {
            if (p := RunnablePathFrom(v.text))
                m.Add(InStr(FileExist(p), "D") ? "このフォルダを開く" : "このファイルを開く", (*) => OpenHistoryPath(p))
            m.Add("定型文に登録", (*) => PromoteHistoryItem(v))
            ; --- ワンショット整形/変換 ---
            defs := ClipTransformDefs()
            mF := Menu(), mC := Menu()
            for d in defs.format
                mF.Add(d.name, MakeTransformHandler(v, d.fn))
            for d in defs.convert
                mC.Add(d.name, MakeTransformHandler(v, d.fn))
            for sub in [mF, mC] {
                sub.Add()
                sub.Add("Shift+選択でコピーのみ", (*) => 0)
                sub.Disable("Shift+選択でコピーのみ")     ; 押せないヒント行
            }
            m.Add("整形して貼り付け", mF)
            m.Add("変換して貼り付け", mC)
            ; --- 改行分割系(第2歩・第3歩)。複数行のときだけ出す ---
            if InStr(v.text, "`n") {
                m.Add("改行ごとにFIFO貼り付け", (*) => StartLineQueue(v, "fifo"))
                m.Add("改行ごとにLIFO貼り付け", (*) => StartLineQueue(v, "lifo"))
                m.Add("改行ごとに履歴に展開", (*) => ExpandHistoryLines(v))
            }
            if (FifoMode != "")
                m.Add("連続貼り付けを中止（残り" . FifoQueue.Length . "件）", (*) => CancelLineQueue(true))
        }
```

既存の`SetTimer(CheckLauncherFocus, 0)`〜`m.Show()`〜再開の枠組みは一切変更しない。サブメニューは同じ`m`にぶら下がるだけでタイマー制御の追加は不要。

### C-3. ^+F 検索ショートカット（起動時ホットキーブロック直後に追加）

```autohotkey
; Ctrl+Shift+F = 検索へフォーカス(Clibor同キー)。ランチャーは開いた瞬間に検索フォーカス済みだが、
; リストクリック後に検索へ戻る手段として同キーを両窓に揃える。
HotIf (*) => IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)
Hotkey "^+f", (*) => LauncherSearchEdit.Focus()
HotIf
HotIf (*) => IsObject(SnipMgrGui) && WinActive("ahk_id " . SnipMgrGui.Hwnd)
Hotkey "^+f", SnipMgrFocusSearch
HotIf
```

```autohotkey
SnipMgrFocusSearch(*) {
    global SnipMgrTab, SnipMgrSearchEd, SnipMgrHistEd
    try (SnipMgrTab.Value = 1) ? SnipMgrSearchEd.Focus() : SnipMgrHistEd.Focus()
}
```

### C-4. 改行ごとに履歴に展開（第2歩）

```autohotkey
; 複数行テキストを1行ずつ個別の履歴項目に分割登録する(Clibor同名機能)。
; 明示的な項目単位の操作なので許可リスト/非永続テストを素で通過する(設計書B-3)。
; 上限100行: 永続ストア(history-store.csv)へのN行追記と削除時書き直しコストの抑制。
; 先にCloseLauncher(): PushClipHistoryは1件ごとにRefreshLauncherHistory(最大500行再構築)を
; 呼ぶため、閉じてno-op化してからループする(閉じないとN回の全再描画)。
ExpandHistoryLines(v) {
    lines := []
    for l in StrSplit(v.text, "`n", "`r")
        if (Trim(l) != "")
            lines.Push(l)
    if (lines.Length < 2)
        return Flash("展開できる複数行がありません", 1500)
    if (lines.Length > 100)
        return Flash("行数が多すぎます（100行まで・検索やFIFOをご利用ください）", 2000)
    CloseLauncher()
    loop lines.Length
        PushClipHistory(lines[lines.Length - A_Index + 1])   ; 逆順Push→1行目が履歴の先頭に来る
    Flash(lines.Length . "行を履歴に展開しました", 1500)
}
```

`PushClipHistory`の重複昇格により、テキスト内に同一行が複数あれば1件に潰れる。これは仕様として受け入れる。

### C-5. FIFO/LIFO（第3歩）

```autohotkey
global FifoQueue := [], FifoMode := ""     ; ""|"fifo"|"lifo"。キューはメモリのみ・履歴非登録

StartLineQueue(v, mode) {
    global FifoQueue, FifoMode
    lines := []
    for l in StrSplit(v.text, "`n", "`r")
        if (Trim(l) != "")
            lines.Push(l)
    if (lines.Length < 2)
        return Flash("複数行のテキストではありません", 1500)
    FifoQueue := lines, FifoMode := mode
    CloseLauncher()
    LoadNextQueueLine()                     ; 1行目(fifo)/最終行(lifo)を即装填
    Flash((mode = "fifo" ? "FIFO" : "LIFO") . "モード開始: Ctrl+Vのたびに次の行になります（全" . lines.Length . "行）", 2000)
}

; 次の行をクリップボードへ装填する。SelfClipTickで自己書き込み扱い=履歴・検疫に入らない。
LoadNextQueueLine() {
    global FifoQueue, FifoMode, SelfClipTick
    if (FifoMode = "")
        return
    if (FifoQueue.Length = 0) {
        FifoMode := ""
        Flash("連続貼り付けを終了しました（全行貼り付け済み）", 1500)
        return
    }
    line := (FifoMode = "fifo") ? FifoQueue.RemoveAt(1) : FifoQueue.Pop()
    SelfClipTick := A_TickCount
    A_Clipboard := line
}

CancelLineQueue(notify := false) {
    global FifoQueue, FifoMode
    FifoQueue := [], FifoMode := ""
    if notify
        Flash("連続貼り付けを中止しました", 1200)
}

; 受動フック: ~付きなのでCtrl+V自体は素通し(貼り付けを一切妨げない)。~^c(既存)と同じ流儀。
; 200ms後の装填: いま貼られているのは装填済みの現在行。貼り付け完了(対象アプリのWM_PASTE処理)を
; 待ってから次を装填する。遅延値は実機確認が必要(G-8)。
~^v:: {
    global FifoMode
    if (FifoMode = "")
        return
    SetTimer(LoadNextQueueLine, -200)
}
```

さらに`CaptureClip`（`PushClipHistory(text)`の直前）に3行追加:

```autohotkey
    if (FifoMode != "") {                     ; 外部の新規コピー=ユーザーの意図が変わった明確なシグナル
        CancelLineQueue()
        Flash("新しいコピーを検知したため連続貼り付けを終了しました", 1500)
    }
```

### C-6. バージョン表記

各リリースでバージョン番号を更新（例: 1.23.0 → 1.24.0 → 1.25.0）。

## D. 実装順序

1. **第1歩（MVP）**: C-1（エンジン）→ C-2のうち整形/変換サブメニュー部分 → C-3（^+F）。
2. **第2歩**: C-4（履歴に展開）＋C-2の`InStr(v.text, "`n")`分岐のうち展開項目。
3. **第3歩**: C-5（FIFO/LIFO）＋C-2の残り（FIFO/LIFO/中止項目）。実機確認事項（G-8）があるため独立リリースにし、問題があればこのリリースだけ切り戻せるようにする。
4. 各歩の後にreality-checkerで検証（検証シナリオはG節末尾）。

## E. MVP

**「整形して貼り付け」6項目＋「変換して貼り付け」6項目＋Shift=コピーのみ＋^+F。**

選定理由: (1) Cliborギャップ6件中、唯一「プライバシー・永続化・入力ハンドリングのどれにも触れない」機能で、リスクとリターンの比が突出している。(2) `Menu`オブジェクトの追加だけでGUIコントロールを1つも触らないため、この製品最大の地雷原（描画バグ）と交差しない。(3) `LCMapJa`エンジンは将来の定型文側変換にもそのまま流用できる基盤投資になる。

**MVPに入れないもの**: 改行分割系3機能（第2・3歩へ）／ページ切り替え（却下）／定型文タブ・管理画面履歴タブへの変換メニュー展開（F-6）。

## F. 却下案と理由

1. **「クリップボードにセット（整形/変換）」というClibor原文の動詞** — 却下。ランチャーの中核イディオムは「選ぶ＝貼る」。「セットのみ」を主動詞にするとランチャー内で唯一「選んでも何も起きない（ように見える）」メニュー群になる。セットのみはShift+選択に降格して両取りする。
2. **FIFO/LIFOの「履歴分割再登録」実装**（会議の批判役が懸念した形） — 却下。履歴先頭がN行で埋まり、検疫キューにN件積まれ、「新しい順」不変条件と貼り付け順序の管理が衝突する。キュー分離が唯一誠実な実装。
3. **FIFO/LIFOトリガーのサイドボタン横取り・貼り付け操作の乗っ取り** — 却下。サイドボタン短押し＝ランチャーは製品の看板操作であり、モードによって意味が変わるボタンは事故製造機。受動`~^v`は既存操作を1つも変えない。
4. **日付時刻自動挿入・ランダム文字列生成** — 却下。Cliborの実メニューに無い可能性が高い上、「クリップボード履歴の変換」ではなく「新規テキスト生成」であり右クリックメニューの文脈に合わない。
5. **ページ切り替え（時間フィルタ含む）** — 今回は履歴側でも却下（B-4）。将来の予約席は時間フィルタであってページャではない。
6. **変換メニューを定型文タブ・管理画面履歴タブにも同時展開** — 却下（今回は）。定型文は「編集して保存する」場が既にあり、ワンショット変換の需要が薄い。要望が出たら`ClipTransformDefs`を流用して足す。
7. **`LCMAP_HIRAGANA|LCMAP_FULLWIDTH`の合成で半角カナも「ひらがな化」する案** — 却下。`LCMAP_FULLWIDTH`は半角ASCIIまで全角化する副作用があり、「カタカナ→ひらがな」の名前と挙動が乖離する。素直な単一フラグに留める。

## G. 地雷と回避策

- **G-1 AHK v2のループ変数クロージャ捕捉（今回最大の新地雷）**: `for d in defs.format`の中で直接`(*) => PasteTransformed(v, d.fn)`と書くと、`d`は参照捕捉されるため**全メニュー項目が最後の変換関数になる**。`MakeTransformHandler`ファクトリ経由の束縛固定が省略不可。実装後、必ず「整形の1番目と6番目が異なる結果になる」ことを実機確認すること。
- **G-2 メニュー表示中のタイマー制御は既存の枠組みを触らない**: `SetTimer(CheckLauncherFocus, 0)`→`m.Show()`→再開の構造はそのまま。サブメニューは`m.Show()`のブロッキング中に生きるローカル`Menu`オブジェクトで完結し、追加の停止/再開・破棄処理を入れないこと。
- **G-3 GUIスタイル不可侵**: 今回の3ステップはいずれもGUIコントロールの追加・スタイル変更ゼロであること自体が設計目標。`WS_EX_COMPOSITED`の再提案禁止（撤回済み）、`NoSort NoSortHdr`維持、460px幅固定にはそもそも触れない。
- **G-4 変換結果と履歴の関係は非対称（仕様）**: 貼り付け経路は`SelfClipTick`で履歴に入らない（原文が履歴の正・変換はワンショット）。Shift=コピーのみ経路は素の`A_Clipboard`代入で監視が拾い**変換結果が履歴先頭に積まれる**（`CopyHistoryItem`と同じ意図された挙動）。この非対称を「バグ」と誤認して統一しないこと。
- **G-5 `LCMapStringW`の呼び出し規約**: LCIDは`0x0411`明示。2段呼び出し必須・出力長は増減する・`StrGet`には2回目の戻り値`n2`を使う。`cchSrc`に`-1`を渡すとNUL込み長になりズレる。空文字列は先頭でreturn。
- **G-6 「カタカナ→ひらがな」は全角カナ限定**: `LCMAP_HIRAGANA`単独は半角カナを変換しない。フラグ合成での「修正」は禁止。
- **G-7 履歴展開は「閉じてから・逆順・上限100」の3点セット**: `CloseLauncher()`を先に呼ばないと`RefreshLauncherHistory`がN回走る。逆順Pushを忘れると履歴上で行順が反転する。
- **G-8 FIFO/LIFOの実機確認事項**: (a) `~^v`後の装填遅延200msで、貼り付けの遅いアプリでも「貼り終わる前に次が装填される」レースが起きないか。起きるなら300-500msへ調整。(b) 対象アプリが`Ctrl+V`以外（右クリック→貼り付け）で貼った場合はフックに乗らず行が進まない——これは仕様として許容し、Flash文言で「Ctrl+Vのたびに」と明示しておく。(c) `#SingleInstance Force`下でのスクリプトリロード時にモードが自然消滅すること。
- **G-9 過去の却下判断との整合**: 前回設計F-4の却下は「定型文の**編集フォーム**にマクロ/変換機能を組み込む」ことの却下であり、本設計のワンショット変換（履歴右クリック→即変換即貼り付け・何も保存しない）は**別物**。編集ダイアログ・保存される変換設定のいずれも導入していないため矛盾しない。同様にF-5（a〜zキー・ページ切り替え却下）は定型文管理の文脈で、本設計B-4は履歴側として独立に再検討した上で同結論に達した。`_docs/CLIBOR-PARITY-JUDGMENT.md`のOS重複テストについては、「Clibor併用をやめられるレベルを目指す」への方針転換をユーザーが明示宣言済みであり、実装コミットの際、同判断書のOS重複テスト項に今回の転換を1行追記しておくこと。
- **G-10 メニュー項目名の一意性**: `m.Disable("Shift+選択でコピーのみ")`は名前参照。同名項目を同一メニュー内に複数作らない。
- **G-11 `^+f`のHotIfは2ブロック排他**: ランチャーと管理画面はどちらか一方しかアクティブにならないため干渉しない。`SnipMgrFocusSearch`の`try`は省略不可（タブ未生成時のフォーカス失敗をfail-closedで握る）。

## 検証シナリオ（実装後の確認用）

1. 複数行テキストを履歴から右クリック→整形→「改行を除去して1行に」→ 1行になって貼り付けられる。履歴の原文は無変更・変換結果は履歴に**現れない**。
2. 同じ項目で変換→「ひらがな→カタカナ」をShift押しながら選択 → 貼り付けは起きず、変換結果が履歴の**先頭に現れる**。
3. 「全角→半角」で`ＡＢＣ１２３ガガ`→`ABC123ｶﾞｶﾞ`（文字数増を確認＝2段呼び出しが正しい証拠）。
4. 整形サブメニューの1番目と6番目が**異なる**結果を出す（G-1のクロージャ束縛検証）。
5. 画像履歴項目の右クリック → 整形/変換メニューが**出ない**。
6. 管理画面で本文Editに入力中に^+F → 検索Editへフォーカスが移る。数字入力は奪われない。
