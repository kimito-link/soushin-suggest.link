# 設計書: 定型文の管理・Clibor同等化（グループ／番号キー／右クリック管理メニュー）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 2356行/v1.16.0)を実地調査した上で設計
> / 素材収集=会議ハーネス（司令塔による取捨選択済みブリーフ経由） / 裏取り=司令塔Claude
> 日付: 2026-07-17
> 前提: [`SNIPPET-MANAGER-DESIGN.md`](SNIPPET-MANAGER-DESIGN.md)（2026-07-15・実装済み）の拡張。
> 同設計書の中核判断（行番号ベース書き換え・`NoSort NoSortHdr`必須・インライン編集却下）は**全て維持**する。

## 裏取りメモ（司令塔ブリーフの反映）

会議メンバー(groq/gpt-oss-20b)の「ソートアイコンだけ非表示にして列ソート機能自体は残す」案は
**司令塔が明確に却下済み**であり、本設計でも採用しない（F-1参照）。列ソートは機能ごと無効
（`NoSort NoSortHdr`）のまま、並び替えは右クリックの「↑へ移動」「↓へ移動」のみで実現する。

実地調査で確認した現況（行番号はv1.16.0時点）:
- `SnipMgrLV`は2列(ラベル/本文)・`NoSort NoSortHdr`付きで生成: L744-747
- 行番号ベース書き換え`SnipMgrWriteLine`: L939-952（`ArchiveSnippetsCsv`呼び出しL950込み）
- ランチャー側の数字キー1-9,0はHotIfスコープ限定で実装済み: L2325-2328 → `LauncherPickKey` L2304-2310
- グループ命名慣習「グループ/ラベル」はClibor CSV取込が既に生成している: `TryLoadCliborCsv` L509
- **L2356に `ShowSnippetManager()  ; TEMP-VERIFY: remove before commit` が残存**（実装開始前に除去すること）

## 結論の要約

| Clibor機能 | 判定 |
|---|---|
| グループ階層 | **採用（フラット1階層）**。ラベルの`グループ/名前`規約＋グループ絞り込みDropDown＋グループ表示列。TreeViewは不採用 |
| 番号キー参照 | **採用（選択専用）**。管理画面の1-9,0は「一覧のフォーカスがあるときだけ行を選択」。ペーストは今後もランチャー専任 |
| 右クリック管理メニュー | **採用**。編集/削除/↑へ移動/↓へ移動/新規登録。`LauncherContextMenu`(L2146)と同じ流儀 |
| 並び替え（↑/↓移動） | **採用**。新設`SnipMgrSwapLines`＝隣接2項目の「行内容スワップ」。両行ラベル検証のfail-closed |
| 定型文検索 | **採用（前設計の「置かない」を改定）**。履歴タブの検索ボックス(L764-767)と同型を定型文タブにも |
| 専用編集ダイアログ（整形/変換/マクロ） | **却下**。現状の下段フォームで十分。将来価値は「長文プロンプト用の拡大エディタ」であってマクロではない（F-4） |
| a〜zキー・ページ切り替え | **却下**。グループ＋検索で絞る方が製品思想に合う（F-5） |
| 列ソート | **引き続き禁止**（`NoSort NoSortHdr`必須。G-1） |

見積もり: 約160行増（2356行 → 2520行前後）。バージョンはv1.17.0を想定。

---

## A. 理想の体験フロー

1. **開く**: 従来どおり歯車メニュー(L681)・トレイ(L2335)から「定型文の管理...」。定型文タブの上部に「グループ▼」ドロップダウンと検索ボックスが並び、一覧は「キー｜グループ｜ラベル｜本文」の4列になる。
2. **見わたす**: 定型文が増えても（Clibor CSV取込で数百件になり得る）、グループで絞る→検索語でさらに絞る、の2段で目当てにたどり着ける。グループはラベルの`グループ/名前`規約から自動抽出され、プレフィクスなしは「（未分類）」に集まる。
3. **並べ替える**: 行を右クリック→「↑へ移動」「↓へ移動」。**これの本質的価値は見た目の整頓ではない**。ランチャーの定型文タブは先頭10件に数字キー1-9,0を割り当てる（`FillLauncherSnippetsLB` L2251）ため、並び替えは「どの定型文にワンキーを与えるか」をユーザー自身が決める操作になる。よく使うプロンプトを上へ移動→次にランチャーを開いた瞬間（`ShowLauncher`は開くたびに`LoadSnippets`を呼ぶ: L1056）から数字キーで撃てる。
4. **管理する**: 右クリックメニューは 編集／削除／（区切り）／↑へ移動／↓へ移動／（区切り）／新規登録。「編集」は下段フォームへ読込＋ラベル欄へフォーカス、「新規登録」はフォームをクリアしてラベル欄へフォーカス。マウスの動線だけで一巡できる（製品のマウス中心ブランドと一致）。
5. **番号キー**: 一覧（ListView）にフォーカスがある間だけ、1-9,0で表示中のn行目を選択できる（=クリックと同じ。フォームに読み込まれる）。ラベル欄・本文欄・検索欄に文字を打っている間は数字は普通に文字として入る。**管理画面の数字キーは絶対にペーストしない**（役割分離、B節）。
6. **守られている**: グループ絞り込み中・検索中は「↑へ移動」「↓へ移動」がグレーアウトする（見かけ上の隣＝ini上の隣ではないため。fail-closed）。外部エディタとの同時編集は従来どおり`SnipMgrWriteLine`のラベル検証で検出され、再読込を促す。

## B. 統合アーキテクチャ

### B-1. 役割分離の原則（番号キー）

| | ランチャー（実行の場） | 定型文の管理（管理の場） |
|---|---|---|
| 数字キー1-9,0の意味 | **ペースト実行**（`LauncherPickKey` L2304） | **行の選択のみ**（新設`SnipMgrPickKey`） |
| HotIfスコープ | `IsObject(LauncherGui) && WinActive(LauncherGui)` (L2325) | `IsObject(SnipMgrGui) && WinActive(SnipMgrGui)` **かつ一覧LVにフォーカス** |
| 有効化/解除処理 | 不要（HotIfが自動で切る） | 同じく不要 |

2つのHotIfブロックは「どちらのウィンドウがアクティブか」で排他になるため干渉しない。
管理画面でペーストさせない理由: ペーストには貼り付け先`LauncherTarget`（ランチャーを開いた瞬間の
アクティブウィンドウ、L1062）という文脈が必要で、管理画面にはその文脈が存在しない。管理画面の
数字キーにペーストを持たせると「どこに貼られるか分からないSend ^v」という事故製造機になる。

マネージャー側だけに加える追加条件「一覧LVにフォーカス」が本設計の要点。管理画面には
ラベルEdit・本文Edit・検索Editがあり、**本文にもラベルにも数字は普通に含まれる**。
`WinActive`だけを条件にするとEdit入力中の数字が奪われて壊れる（G-5。なおランチャー側の
検索Edit L1076には現状このガードが無く、検索語に数字を打つと誤ペーストする既存課題がある。
本件とは別件として扱う）。

### B-2. 新設・変更一覧

| 部品 | 種別 | 役割 |
|---|---|---|
| `SnipMgrAllItems`（global） | 新設 | ini全項目（lineNo付き）。重複チェック・グループ抽出の母集団 |
| `SnipMgrItems`（既存 L698） | **意味変更** | 「**表示中**の項目」（絞り込み後の部分集合）。各要素がlineNoを持つため編集/削除は絞り込み中も安全 |
| `SnipMgrGroupDD` / `SnipMgrSearchEd`（global） | 新設 | グループDropDownと検索Edit |
| `SnipGroupOf(label)` / `SnipNameOf(label)` | 新設 | 最初の`/`で分割（1階層限定）。`/`なしは「（未分類）」／ラベル全体 |
| `SnipMgrFilterActive()` | 新設 | グループ≠すべて or 検索語あり。並び替え禁止判定に使う |
| `SnipMgrRefresh()`（既存 L916） | 改修 | 全読込→DD選択肢再構築→絞り込み→4列で再描画 |
| `SnipMgrContextMenu(g, ctrl, item, …)` | 新設 | 右クリックメニュー。`LauncherContextMenu`(L2146)と同流儀 |
| `SnipMgrSwapLines(a, b)` | 新設 | 隣接2項目の行内容スワップ。`SnipMgrWriteLine`と同じ検証・書込流儀 |
| `SnipMgrMove(row, delta)` | 新設 | ↑/↓移動の入口。境界・絞り込みチェック→スワップ→再選択 |
| `SnipMgrPickKey(hk, *)` | 新設 | 数字キーで表示n行目を選択 |
| `SnipMgrAdd`（既存 L962） | **1行改修** | 重複チェックの走査先を`SnipMgrItems`→`SnipMgrAllItems`へ（G-2） |
| `SnipMgrWriteLine` / `SnipMgrSave` / `SnipMgrDelete` / `SnipMgrOnSelect` | **無変更** | lineNo経由なので絞り込み導入後もそのまま正しい |

### B-3. データ規約（グループ）

- ini不変条件「1定型文=1行」は**不可侵**。グループはラベル文字列の`グループ/名前`規約のみで表現し、セクションや別ファイルは導入しない。
- この規約はClibor CSV取込(L509)とランチャー表示が既に採用している事実上の標準であり、新たな学習コストがない。
- 分割は**最初の`/`のみ**（`a/b/c`はグループ`a`・名前`b/c`）。多段階層は作らない。
- 下段フォームのラベル欄は従来どおり**フル形式**（`グループ/名前`）を編集する。グループ移動＝ラベルのプレフィクス書き換え、として一貫させる（専用のグループ欄は設けない。G-9）。

## C. 具体機構

### C-1. 定型文タブのレイアウト変更（`ShowSnippetManager` L741-760を改修）

```autohotkey
    SnipMgrTab.UseTab(1)
    SnipMgrGui.Add("Text", "x10 y58 w50 h20", "グループ")
    SnipMgrGroupDD := SnipMgrGui.Add("DropDownList", "x64 y54 w150", ["すべて"])
    SnipMgrGroupDD.OnEvent("Change", (*) => SnipMgrRefresh(true))   ; true=再読込せず絞り込みだけ
    SnipMgrGui.Add("Text", "x226 y58 w36 h20", "検索")
    SnipMgrSearchEd := SnipMgrGui.Add("Edit", "x264 y54 w326 h24")
    SnipMgrSearchEd.OnEvent("Change", (*) => SnipMgrRefresh(true))
    ; NoSort NoSortHdr は今後も必須(G-1)。4列: キー/グループ/ラベル/本文
    SnipMgrLV := SnipMgrGui.Add("ListView", "x10 y84 w580 h220 -Multi NoSort NoSortHdr +Grid",
        ["キー", "グループ", "ラベル", "本文"])
    SnipMgrLV.ModifyCol(1, 34), SnipMgrLV.ModifyCol(2, 96)
    SnipMgrLV.ModifyCol(3, 150), SnipMgrLV.ModifyCol(4, 280)
    SnipMgrLV.OnEvent("ItemSelect", SnipMgrOnSelect)
    SnipMgrGui.OnEvent("ContextMenu", SnipMgrContextMenu)   ; Gui単位イベント。ctrl判定はハンドラ側(C-3)
```

一覧の高さを250→220に詰めて絞り込み行(30px)を捻出する（フォーム以下の座標 L749-760 は無変更で済む）。
履歴タブの検索(L764-767)と操作感を揃える。

### C-2. 絞り込み対応の再描画（`SnipMgrRefresh` L916-925を置換）

```autohotkey
SnipGroupOf(label) {
    p := InStr(label, "/")
    return p ? SubStr(label, 1, p - 1) : "（未分類）"
}
SnipNameOf(label) {
    p := InStr(label, "/")
    return p ? SubStr(label, p + 1) : label
}
SnipMgrFilterActive() {
    global SnipMgrGroupDD, SnipMgrSearchEd
    return (SnipMgrGroupDD.Text != "すべて") || (Trim(SnipMgrSearchEd.Value) != "")
}

; keepFilter=false(既定): iniを読み直し、グループDDの選択肢も作り直す(外部編集・CSV取込後)
; keepFilter=true: DD/検索の操作時。読み直しは行うが選択状態の維持を試みる
SnipMgrRefresh(keepFilter := false) {
    global SnipMgrLV, SnipMgrItems, SnipMgrAllItems, SnipMgrGroupDD, SnipMgrSearchEd
    global SnipMgrLabelEd, SnipMgrBodyEd
    SnipMgrAllItems := SnipMgrReadItems()
    ; グループDD再構築(選択維持。消えたグループを選んでいたら「すべて」へ戻す)
    cur := SnipMgrGroupDD.Text
    groups := Map()
    for s in SnipMgrAllItems
        groups[SnipGroupOf(s.label)] := 1
    opts := ["すべて"]
    for g, _ in groups
        opts.Push(g)
    SnipMgrGroupDD.Delete(), SnipMgrGroupDD.Add(opts)
    if !keepFilter || !groups.Has(cur)
        cur := "すべて"
    SnipMgrGroupDD.Choose(cur = "すべて" ? 1 : 0), (cur != "すべて" && SnipMgrGroupDD.Choose(cur))

    q := Trim(SnipMgrSearchEd.Value)
    SnipMgrItems := []
    SnipMgrLV.Delete()
    for s in SnipMgrAllItems {
        g := SnipGroupOf(s.label)
        if (cur != "すべて" && g != cur)
            continue
        if (q != "" && !InStr(s.label, q) && !InStr(s.value, q))
            continue
        SnipMgrItems.Push(s)
        n := SnipMgrItems.Length
        prev := RegExReplace(s.value, "\s+", " ")
        SnipMgrLV.Add(, (n <= 10 ? Mod(n, 10) : ""), g, SnipNameOf(s.label),
            (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . SubStr(prev, 1, 80))
    }
    SnipMgrLabelEd.Value := "", SnipMgrBodyEd.Value := ""
}
```

「キー」列の番号は**表示行**基準（絞り込み後の1〜10）。数字キー選択(C-5)と常に一致する。
`SnipMgrSave`/`SnipMgrDelete`(L981-1012)と`SnipMgrOnSelect`(L929-935)は`SnipMgrItems[row]`
（=表示行→lineNo持ち要素）参照なので**無変更で絞り込み中も正しく動く**。これが
「lineNoを要素に抱かせる」既存設計の配当であり、履歴タブの`SnipMgrHistRows`(L853「インデックス
でなく要素の参照を保持」)と同じ思想。

### C-3. 右クリックメニュー（新設。`LauncherContextMenu` L2146-2165と同流儀）

```autohotkey
; ListView上の右クリック管理メニュー。item=右クリックで焦点が当たった表示行(空白部は0)。
; マネージャー表示中はCheckLauncherFocusを既に止めている(L723)ため、ランチャー流の
; タイマー停止/再開はしない(G-11: ここで再開するとランチャー誤クローズを誘発する)。
SnipMgrContextMenu(g, ctrl, item, isRC, x, y) {
    global SnipMgrLV, SnipMgrItems
    if (ctrl != SnipMgrLV)
        return
    m := Menu()
    if (item >= 1 && item <= SnipMgrItems.Length) {
        row := item
        SnipMgrLV.Modify(row, "+Select +Focus")      ; 操作対象と見た目の選択を一致させる
        m.Add("編集", (*) => SnipMgrEditRow(row))
        m.Add("削除", (*) => SnipMgrDelete())
        m.Add()
        m.Add("↑へ移動", (*) => SnipMgrMove(row, -1))
        m.Add("↓へ移動", (*) => SnipMgrMove(row, +1))
        if SnipMgrFilterActive() {
            m.Disable("↑へ移動"), m.Disable("↓へ移動")   ; 絞り込み中の並べ替え禁止(G-3)
        } else {
            (row = 1) && m.Disable("↑へ移動")
            (row = SnipMgrItems.Length) && m.Disable("↓へ移動")
        }
        m.Add()
    }
    m.Add("新規登録", (*) => SnipMgrNewForm())
    m.Show()
}

SnipMgrEditRow(row) {          ; クリック選択と同じ読込＋ラベル欄へフォーカス
    global SnipMgrLV, SnipMgrLabelEd
    SnipMgrOnSelect(SnipMgrLV, row, true)
    SnipMgrLabelEd.Focus()
}
SnipMgrNewForm(*) {            ; フォームをクリアして新規入力へ誘導
    global SnipMgrLabelEd, SnipMgrBodyEd
    SnipMgrLabelEd.Value := "", SnipMgrBodyEd.Value := ""
    SnipMgrLabelEd.Focus()
}
```

Cliborの「定型文検索」項目は検索ボックスが常時可視なので不要、「ページ切り替え」はグループDDが
代替、CSV系は既存ボタン(L758-759)があるためメニューには入れない。

### C-4. ↑/↓移動 = 隣接2項目の「行内容スワップ」（新設）

`SnipMgrWriteLine`(L939-952)と同じ「読む→検証→書く」流儀。**行を移動するのではなく、
2つの定型文行の内容を入れ替える**。これにより (a) 他の全行の行番号が一切動かない、
(b) 間に挟まったコメント行・空行は元の位置に残る、(c) 検証失敗時は何も書かずに中止できる。

```autohotkey
; 表示行aとbの定型文の「行内容」をini上で入れ替える。両行のラベルを検証し、
; どちらか一方でも外部編集でズレていたら何も書かない(fail-closed)。
SnipMgrSwapLines(a, b) {
    global SnipMgrItems
    ia := SnipMgrItems[a], ib := SnipMgrItems[b]
    path := A_ScriptDir . "\snippets.ini"
    lines := StrSplit(FileRead(path, "UTF-8"), "`n", "`r")
    if (ia.lineNo > lines.Length || ib.lineNo > lines.Length
        || !RegExMatch(Trim(lines[ia.lineNo]), "^\Q" . ia.label . "\E\s*=")
        || !RegExMatch(Trim(lines[ib.lineNo]), "^\Q" . ib.label . "\E\s*="))
        return false
    tmp := lines[ia.lineNo]
    lines[ia.lineNo] := lines[ib.lineNo], lines[ib.lineNo] := tmp
    out := ""
    for l in lines
        out .= l . "`n"
    FileDelete(path)
    FileAppend(RTrim(out, "`n") . "`n", path, "UTF-8")
    ArchiveSnippetsCsv()                      ; SnipMgrWriteLine L950と同じ(フォルダ保存ON時のみ)
    return true
}

SnipMgrMove(row, delta) {
    global SnipMgrItems, SnipMgrLV
    dest := row + delta
    if (SnipMgrFilterActive() || dest < 1 || dest > SnipMgrItems.Length)
        return                                 ; メニュー側Disableと二重の防御(G-3)
    if SnipMgrSwapLines(row, dest) {
        SnipMgrRefresh()
        SnipMgrLV.Modify(dest, "+Select +Focus Vis")   ; 移動先の行を選択し直し連打移動を可能に
        SetCsvStatus("移動しました: " . SnipMgrItems[dest].label)
    } else {
        SnipMgrRefresh()
        SetCsvStatus("ファイルが外部で変更されていたため再読込しました。もう一度お試しください")
    }
}
```

再選択(`Modify(dest, …)`)により「↑へ移動を3回連打」のような連続操作が右クリック3回で済む。

### C-5. 数字キー選択（新設。起動時ブロックL2325-2328の直後に追加）

```autohotkey
; 管理画面の数字キー1-9,0 = 「表示中のn行目を選択」専用。ペーストはしない(役割分離、設計書B-1)。
; ラベル/本文/検索Editへの数字入力を奪わないよう「一覧LVにフォーカスがあるとき」限定。
; HotIfコールバックはフックスレッドで走るため軽量・非throw必須(tryで包む。G-5)
HotIf (*) => IsObject(SnipMgrGui) && WinActive("ahk_id " . SnipMgrGui.Hwnd) && SnipMgrLVFocused()
Loop 10
    Hotkey Mod(A_Index, 10) . "", SnipMgrPickKey
HotIf

SnipMgrLVFocused() {
    global SnipMgrGui, SnipMgrLV
    try return ControlGetFocus("ahk_id " . SnipMgrGui.Hwnd) = SnipMgrLV.Hwnd
    return false
}

SnipMgrPickKey(hk, *) {
    global SnipMgrLV, SnipMgrItems, SnipMgrTab
    if (SnipMgrTab.Value != 1)                 ; 履歴タブでは何もしない
        return
    n := (hk = "0") ? 10 : Integer(hk)
    if (n > SnipMgrItems.Length)
        return
    SnipMgrLV.Modify(n, "+Select +Focus Vis")  ; ItemSelect発火の有無は実装時に検証(G-6)
}
```

## D. 既存機能との関係

| 既存 | 扱い |
|---|---|
| `LoadSnippets` L398-417 | **無変更**。ランチャーは並び順をiniの行順のまま読むので、↑/↓移動の結果が次回`ShowLauncher`(L1056)で自動反映される |
| `LauncherPickKey` L2304-2310 ／ HotIfブロック L2325-2328 | **無変更**。ランチャーの数字キー＝ペーストは専任のまま |
| `FillLauncherSnippetsLB` L2242-2256 | **無変更**。先頭10件への番号振りが「並び替えの本質的価値」の受け皿になる |
| `SnipMgrWriteLine` L939-952 | **無変更**。保存/削除の唯一の書き込み口として継続。`SnipMgrSwapLines`は同流儀の兄弟関数 |
| `SnipMgrSave`/`SnipMgrDelete` L981-1012 | **無変更**。`SnipMgrItems`が部分集合になってもlineNo経由なので正しい |
| `SnipMgrAdd` L962-979 | **1行改修**: L966の重複走査を`SnipMgrItems`→`SnipMgrAllItems`へ（G-2） |
| `SnipMgrOnSelect` L929-935 | **無変更**（列が増えても行→要素対応は不変） |
| `SnipMgrReadItems` L898-914 | **無変更** |
| 履歴タブ一式 L762-894 | **不可侵**。検索ボックスのUIパターン(L764-767)だけ流用する |
| Clibor CSV取込 `TryLoadCliborCsv` L482-527 | **無変更**。取込が作る`グループ/名前`ラベルがそのままグループ列・DDに現れる（設計の整合が取込→管理→ランチャーで一気通貫になる） |
| `PromoteHistoryAt` L2282-2302 | **無変更**。昇格時のラベルに`グループ/`を手で付ければグループに入る（それ以上の誘導はしない） |
| ドラッグバー/`SnipMgrWatchDrag` L804-826、`HideSnipMgr` L829-835 | **無変更**（v1.16.0の-Caption統一はそのまま） |

## E. MVP

**今回のスコープ（全部で1リリース=v1.17.0）**:
1. 定型文タブの4列化（キー/グループ/ラベル/本文）＋グループDropDown＋検索ボックス（C-1, C-2）
2. 右クリックメニュー: 編集/削除/↑へ移動/↓へ移動/新規登録（C-3）
3. `SnipMgrSwapLines`による並び替え（C-4）
4. 数字キー1-9,0による行選択（C-5）
5. `SnipMgrAdd`の重複チェック母集団修正（G-2。絞り込み導入と不可分なので同時必須）

**前回MVP（SNIPPET-MANAGER-DESIGN.md E節）からの差分**: 前回「MVPに入れないもの」とした
6項目のうち、右クリックメニュー・並び替え・検索の3つを今回昇格させる。昇格理由はいずれも
状況変化による: Clibor CSV取込の実装で定型文が数百件規模になり得るようになり「一覧性＋目視
スキャン」だけでは成立しなくなった（検索・グループ）。ランチャーの数字キー実装で「先頭10件」
に意味が生まれ、並び順がユーザーの資産になった（並び替え）。

**今回も入れないもの**: 列ソート（恒久禁止）／インライン編集（恒久却下）／複数選択削除／
a〜zキー・ページ切り替え／専用編集ダイアログ・マクロ/変換／グループの一括リネーム・
ドラッグ&ドロップ並び替え（以上F節）。

## F. 捨てた案と理由

1. **「ソートアイコンだけ隠して列ソート機能は残す」**（会議gpt-oss-20b案）: **却下（司令塔裁定）**。`NoSort`を外す限り、ユーザーが列ヘッダをクリックすれば実ソートが発火し得る。表示順↔`SnipMgrItems`↔ini行番号の3者対応が壊れると**別の定型文を上書き・削除する**という地雷の趣旨(G-1)を何も回避できていない。見た目の妥協ではなく機能自体の無効化が必要。
2. **TreeView等による実グループ階層**: 却下。「1定型文=1行」不変条件と両立しない（階層をiniに持たせるにはセクションや別ファイルが要り、行番号ベース書き換えの土台が崩れる）。ラベル規約`グループ/名前`はClibor CSV取込(L509)とランチャー表示が既に使っている事実上の標準で、追加コストゼロで同じ体験が得られる。
3. **行の「挿入移動」方式**（RemoveAt+InsertAtで行を抜き差しして移動）: 却下。移動範囲内の全項目の行番号がズレて`SnipMgrItems`全体の再計算が必要になり、コメント行を挟む位置関係も崩れる。隣接スワップなら動くのは2行だけで、検証も2行分で済む（C-4）。連続スワップで任意距離の移動は実現できる。
4. **専用編集ダイアログ（Cliborの整形/変換/マクロ付き）**: 却下。Cliborのマクロ（日付展開等）は「貼り付け時の実行時機能」であり管理画面の編集機能ではない。導入するなら`UseSnippetAt`(L1188)側の話で、`run:`に続く第2のミニ言語を抱えることになり、fail-closedのシンプルさを損なう。編集体験としての本質的価値はマクロではなく「長文AIプロンプトを広い画面で編集できること」だが、現在の本文Edit(96px・スクロール付き L753)で致命的に困っている証拠がまだ無い。将来ユーザーから「本文が長くて編集しづらい」が実際に出た時に「本文欄の拡大トグル」として最小実装する（ダイアログ新設ではなく）。
5. **a〜zキー・ページ切り替え**（Cliborの番号体系の完全移植）: 却下。a〜zは26個のホットキーがラベル/検索の文字入力と正面衝突し、ガード条件がどれだけ精密でも「タイプ中に選択が飛ぶ」体験リスクが残る。11件目以降はグループDD＋検索で絞って先頭10件に入れる方が、ランチャー側の「先頭10件だけ番号」という既存設計(L2251, L2275)とも一貫する。
6. **絞り込み中の並び替え許可**: 却下。表示上の隣は ini上の隣ではないため、スワップすると「検索結果の2件の間にある無関係な定型文を飛び越えた並び」になり、ユーザーの意図（1つ上へ）と結果が一致しない。禁止（メニューDisable＋関数内ガードの二重防御）が唯一の誠実な挙動。
7. **ドラッグ&ドロップ並び替え**: 却下。ListViewのD&DはAHKでは自前実装（LVM_*直叩き＋マウス監視ループ）で、既知の地雷 feedback_ahk_drag_race_condition（GUI破棄との競合）と同型の監視ループをまた1本増やす。右クリック↑↓で十分。
8. **右クリックメニューに「定型文検索」「CSV出力/取込」項目**: 却下。検索ボックスとCSVボタンが常時可視なのでメニュー項目は冗長。Cliborの項目構成の模倣より、この画面の実配置に合わせる。
9. **数字キーを`WinActive`だけで有効化**（ランチャーと同条件）: 却下。管理画面は入力欄が主役であり、ラベル・本文・検索語に含まれる数字が全て選択操作に化ける。LVフォーカス限定が必須条件（G-5）。

## G. 地雷と回避策

- **G-1 列ソート禁止は恒久条項**: `NoSort NoSortHdr`(L744)は今回の4列化後も必須オプションであり省略不可。「アイコンだけ隠す」変種も禁止（F-1）。ソートが発火した瞬間、表示行↔`SnipMgrItems`↔lineNoの対応が壊れ、保存/削除/スワップが**別の定型文を破壊**する。
- **G-2 `SnipMgrItems`の意味変更に伴う重複チェックの母集団**: 絞り込み導入後、`SnipMgrItems`は表示中の部分集合になる。`SnipMgrAdd`のL966-968が`SnipMgrItems`走査のままだと、**絞り込み中に重複ラベルの追加を通してしまう**。必ず`SnipMgrAllItems`走査に変更する。同種の走査を今後書くときも「全件が要るのか表示中で良いのか」を毎回問うこと。
- **G-3 絞り込み中の↑/↓移動禁止は二重防御**: メニューの`Disable`（UI）と`SnipMgrMove`冒頭の`SnipMgrFilterActive()`ガード（ロジック）の両方を実装する。片方だけだと、メニュー表示中に検索Editへ文字が入る等のレース時に抜け穴ができる。
- **G-4 スワップは「行内容の交換」であり行の移動ではない**: コメント行・空行は絶対に動かさない。挟まったコメントの位置が定型文に対して相対的に変わって見えることがあるが、これは仕様（コメントは行位置に帰属する）。全行書き直しへの誘惑に負けないこと（コメント消失リスクの再来）。
- **G-5 HotIfコールバックの制約**: フックスレッドで頻繁に評価されるため、軽量・非throwが必須。`ControlGetFocus`はフォーカス無し等で throw し得るので必ず`try`で包み、失敗時は`false`（=キー無効。fail-closed）。またEditフォーカス時に数字を奪わない条件は省略不可。なお**ランチャー側の検索Edit(L1076)には現状このガードが無く、検索語に数字を打つと`LauncherPickKey`が誤発火してペーストされる既存課題がある**。本設計のスコープ外だが、同じ`SnipMgrLVFocused`パターン（LVまたはListBoxフォーカス時のみ有効）での修正候補として申し送る。
- **G-6 `LV.Modify(+Select)`と`ItemSelect`イベント**: プログラムからの選択変更でも`ItemSelect`(LVN_ITEMCHANGED由来)が発火するはず（発火すれば`SnipMgrOnSelect`が自動でフォームに読み込む）。実装時に必ず実機確認し、(a)発火しない場合は`SnipMgrPickKey`/`SnipMgrMove`から`SnipMgrOnSelect(SnipMgrLV, n, true)`を手動で呼ぶ、(b)発火する場合は手動呼び出しを入れない（入れると二重読込）。どちらか一方に確定させること。
- **G-7 `ContextMenu`イベントの`item`引数**: 行の無い場所（一覧の空白部・ヘッダ）での右クリックは`item=0`。この場合も「新規登録」だけのメニューを出す（C-3の分岐）。`item`を無検証で`SnipMgrItems[item]`に使うと配列範囲外エラー。
- **G-8 メニュー表示中のタイマー制御はランチャーと逆**: `LauncherContextMenu`(L2152, L2163)は`CheckLauncherFocus`を止めて→再開するが、マネージャーは開いた時点で既に止めている(L723)。`SnipMgrContextMenu`で同じ停止/再開を真似すると、**再開側が走ってランチャー誤クローズ／マネージャー表示中の挙動不整合を誘発**する。何もしないのが正解。
- **G-9 グループ分割は最初の`/`のみ・1階層限定**: `SnipGroupOf`/`SnipNameOf`以外の場所でラベルを分割しない（分割ロジックの複製が将来の多段化・仕様ズレの温床）。ラベル無害化規則`[=\[\];]`(L957)に`/`は**含めない**こと（含めるとグループ規約自体が書けなくなる）。
- **G-10 出荷前にL2356を除去**: `ShowSnippetManager()  ; TEMP-VERIFY: remove before commit` が現main作業ツリーに残っている。今回の実装コミットに紛れ込ませず、着手時にまず削除する。
- **G-11 検索/DDの`Change`から呼ぶRefreshは`keepFilter=true`**: 既定の`SnipMgrRefresh()`（フィルタ維持なし）を配線すると、1文字打つたびにDDが「すべて」へ戻り検索と グループ絞り込みが併用できない。逆に外部変更後（CSV取込・保存後）は既定呼び出しでフィルタ状態の妥当性から作り直す。

## 行数見積もり

| 部品 | 行数 |
|---|---|
| C-1 レイアウト変更（DD＋検索＋4列化） | +18 |
| C-2 `SnipGroupOf`/`SnipNameOf`/`SnipMgrFilterActive`/`SnipMgrRefresh`改修 | +45 |
| C-3 `SnipMgrContextMenu`/`SnipMgrEditRow`/`SnipMgrNewForm` | +40 |
| C-4 `SnipMgrSwapLines`/`SnipMgrMove` | +38 |
| C-5 HotIfブロック/`SnipMgrLVFocused`/`SnipMgrPickKey` | +22 |
| コメント | 込み |
| **合計** | **約160行 → 2356行から2520行前後** |

---

## 次のチャットへの引き継ぎ用ハンドオフ

**やること（v1.17.0）**: `dist/soushin-suggest.ahk`の定型文管理ウィンドウをClibor同等化する。
本設計書のC節のコードイメージをそのまま下敷きにしてよい（行番号はv1.16.0/2356行時点）。

**着手順**:
1. **最初にL2356の`ShowSnippetManager()  ; TEMP-VERIFY: remove before commit`を削除**（既存の検証用残骸。今回の変更に混ぜない）
2. グローバル追加（L697-701付近）: `SnipMgrAllItems := []`, `SnipMgrGroupDD := 0`, `SnipMgrSearchEd := 0`
3. C-1: `ShowSnippetManager`のタブ1レイアウト改修（L741-747を置換、LV高さ250→220、y座標はC-1の値）。`SnipMgrGui.OnEvent("ContextMenu", SnipMgrContextMenu)`の配線を忘れない
4. C-2: `SnipMgrRefresh`置換＋ヘルパー3関数新設。**同時に`SnipMgrAdd` L966の走査を`SnipMgrAllItems`へ変更**（G-2。これを忘れると絞り込み中に重複追加が通るバグになる）
5. C-3: 右クリックメニュー新設（タイマー停止/再開は**入れない**。G-8）
6. C-4: `SnipMgrSwapLines`/`SnipMgrMove`新設
7. C-5: 数字キーHotIfブロックをL2328（ランチャー用HotIfブロック）の直後に追加
8. バージョン L26 `AppVersion := "1.17.0"` へ

**絶対に守る制約**:
- `NoSort NoSortHdr`を外さない・「アイコンだけ隠す」変種もやらない（G-1、司令塔裁定）
- 並び替えは隣接スワップのみ・絞り込み中は禁止（Disable＋関数内ガードの二重防御）
- ini書き込みは既存`SnipMgrWriteLine`と新設`SnipMgrSwapLines`の2口だけ。全文書き直し禁止
- 管理画面の数字キーはペーストしない（選択のみ）。LVフォーカス限定ガード必須

**実装時に実機で確定させる点**:
- G-6: `SnipMgrLV.Modify(n, "+Select")`で`ItemSelect`が発火するか → 発火するなら手動呼び出し無し、しないなら`SnipMgrPickKey`/`SnipMgrMove`から`SnipMgrOnSelect(SnipMgrLV, n, true)`を呼ぶ
- `ContextMenu`イベントの`item`が右クリック行を正しく指すか（指さない環境なら`LauncherLVItemUnderMouse`(既存)流のヒットテストに差し替え）
- DropDownListの`Choose(文字列)`の挙動（C-2のグループ選択維持部。不安定なら添字検索に書き換え）

**検証シナリオ（reality-checker向け）**:
1. 定型文20件（3グループ混在）で開く → グループDDに「すべて/各グループ/（未分類）」が出る
2. 5行目を右クリック→↑へ移動 → iniの該当2行だけが入れ替わり、コメント行が動いていないこと（diffで確認）
3. 検索語を入れる → ↑/↓がグレーアウト。その状態で編集/削除は正しい対象に効く
4. メモ帳でiniを書き換えた直後に↑へ移動 → 「外部で変更されていたため再読込」で中止される（fail-closed）
5. ラベルEditに「1」を打つ → 行選択に化けない。LVをクリックしてから「3」→3行目が選択されフォームに載る
6. 並び替え後にランチャーを開く → 定型文タブの番号1-9,0が新しい順序に追従している

**別件の申し送り（今回のスコープ外）**: ランチャーの検索Edit(L1076)にはEditフォーカスガードが無く、
検索語に数字を打つと`LauncherPickKey`(L2304)が発火して誤ペーストする疑いが濃い。G-5の
`SnipMgrLVFocused`と同じパターンでランチャー側HotIf(L2325)に「Editフォーカス時は無効」条件を
足す小修正を、別セッションで検討すること。
