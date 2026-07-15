# 設計書: 定型文管理ウィンドウ「定型文の管理」（soushin-suggest.link v1.5系）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 831行/v1.4.1)を実地調査した上で設計
> / 素材収集=会議ハーネス(6体召集・4/6成功、lead役1体は応答失敗) / 裏取り=司令塔Claude
> 日付: 2026-07-15
> 前提: [`EXPORT-IMPORT-FILE-EXEC-DESIGN.md`](EXPORT-IMPORT-FILE-EXEC-DESIGN.md)（CSV出力/取込・実装済み）の上位UI刷新

## 裏取りメモ（司令塔による検証）

会議で「既存実装が`IniRead`/`IniWrite`を経由している」という指摘（groq/qwen3-32b, critic役）が出たが、
実地調査の結果これは事実誤認と確認し、Fableへのブリーフで明確に却下した。既存コードは徹底して
`FileRead`/`FileAppend`ベースであり、`IniWrite`/`IniRead`は一切使用していない（非ASCIIキー誤読という
既知の罠を回避するため、意図的に自前パーサ）。また会議メンバーの一部（groq/llama-3.3-70b）が出した
AHKコード例は`ListView.New()`という**存在しないAPI**を使っており、この部分は設計に一切採用していない。

Fableが挙げた行番号（`LoadSnippets`:L257、`ExportSnippetsCsv`:L347、`ShowCsvDialog`:L424、
`ShowLauncher`:L465、`PromoteHistoryAt`:L770等）は司令塔の実地調査結果と一致。`Gui.Add("ListView", ...)`、
`.ModifyCol()`、`OnEvent("ItemSelect", ...)`のコールバックシグネチャ`(lv, row, selected)`はAutoHotkey v2の
実在するAPIとして妥当と判断。

## 結論の要約

| 項目 | 判定 |
|---|---|
| ListView vs カスタムListBox | **ListView採用**（会議は3/4多数派、司令塔もランチャー同居のリスクから支持） |
| 画面構成 | **マスター・ディテール型**（上段ListView・下段編集フォーム） |
| 既存ランチャーの定型文タブとの関係 | **完全独立**の別ウィンドウ（ワンキーペースト動線を壊さない） |
| GUIパターン | **シングルトン**（`ShowCsvDialog`と同流儀。`Hide()`のみ、再表示時に`Refresh()`必須） |
| 書き込み方式 | **行番号ベースの行単位書き換え**（全文書き直しは却下・コメント消失と重複ラベル誤爆のリスク） |
| `ShowCsvDialog` | **退役・削除**（機能は新ウィンドウに統合） |
| 列ソート | **禁止**（`NoSort NoSortHdr`必須。ソートを許すと行対応が壊れ誤削除の危険） |
| インライン編集 | **却下**（ListView上へのEdit重畳は地雷原） |
| 見積もり行数 | 約170行増（831行 → 約1000行前後） |

---

## A. 理想の体験フロー

1. **開く**: ランチャー右上の歯車メニュー（`ShowLauncherSettingsMenu`）とトレイメニューの両方に「定型文の管理...」を追加。クリックで独立ウィンドウが開く（ランチャーはフォーカス喪失で自動クローズするが、既存仕様どおりで自然な挙動）。
2. **見える**: 上段に2列のListView（列1「ラベル」150px・列2「本文」400px）。本文列は改行を空白に潰した1行プレビュー。`run:`項目は「▶ 」プレフィクスで視認できる。IMEの単語登録ダイアログと同じく、**全定型文が一望できる**のが核心。
3. **編集**: 行をクリック → 下段のフォーム（ラベルEdit＋複数行の本文Edit）に読み込まれる → 修正 → 「上書き保存」。一覧が即時再描画される。
4. **追加**: フォームに直接入力 → 「新規追加」。重複ラベルはステータス行で拒否。
5. **削除**: 行を選択 → 「削除」→ 確認なしで削除しステータス行に「削除しました: ○○」（誤削除はCSV出力によるバックアップで担保。MsgBox確認はマウス操作のテンポを削ぐため入れない）。
6. **CSV連携**: 同ウィンドウ右下の「CSV出力」「CSV取込」ボタン。取込後は一覧が自動再読込される。「全クリアして取込」チェックボックスも移設。
7. **閉じる**: Escapeまたは×で`Hide()`。次回は即座に再表示＋最新のiniを再読込。

マウス中心の制約との整合: 検索ボックスは置かない。一覧性＋クリック選択で目視スキャンする。文字入力が発生するのはラベル・本文の内容編集そのものだけで、ナビゲーションではなくコンテンツ入力なのでブランド軸に抵触しない。

## B. 統合アーキテクチャ

新設は関数6個＋グローバル7個。既存の2大GUIパターンのうち`ShowCsvDialog`のシングルトン流儀に揃える（管理画面は「たまに開いて長く使う」ウィンドウであり、ランチャーの「頻繁に出して即捨てる」使い捨て流儀とは性格が違う）。

| 新設 | 役割 | 既存パターンとの整合 |
|---|---|---|
| `global SnipMgrGui/SnipMgrLV/SnipMgrLabelEd/SnipMgrBodyEd/SnipMgrStatus/SnipMgrItems/SnipMgrClearChk` | シングルトンGUI参照と行→ini行番号の対応表 | `CsvDlgGui/CsvDlgStatus/CsvDlgClearChk`と同形式 |
| `ShowSnippetManager(*)` | GUI構築（初回のみ）＋表示＋再読込 | `ShowCsvDialog`のシングルトン（`if SnipMgrGui { refresh; Show; return }`） |
| `SnipMgrRefresh()` | ini再パース→ListView再構築→フォームクリア | — |
| `SnipMgrReadItems()` | **行番号付き**で`{label, value, lineNo}`配列を返す | `LoadSnippets`の変形（`LoadSnippets`本体は非改造） |
| `SnipMgrWriteLine(lineNo, expectLabel, newLine)` | 行単位の書き換え/削除。書換え前に該当行のラベル一致を検証（fail-closed） | `PromoteHistoryAt`と同じFileRead/FileDelete/FileAppend UTF-8明示流儀 |
| `SnipMgrAdd/SnipMgrSave/SnipMgrDelete(*)` | ボタンハンドラ3個 | ラベル無害化は`PromoteHistoryAt`の`RegExReplace(v,"[=\[\];]")`と同一規則 |

**書き込み方式の設計判断（本設計の核）**: 「全項目をメモリに持って全文書き直し」は一見単純だが、(a) iniのコメント行・空行が消える（出荷snippets.iniの先頭には説明コメントがある）、(b) 重複ラベルが存在するときどの行を書き換えるか曖昧、の2点で危険。snippets.iniは**1定型文=1行**（`\n`エスケープ済み）という不変条件があるため、行番号ベースの書き換えが安全かつ安価に成立する。追加は既存の`FileAppend`追記パターンをそのまま使う。

## C. 具体機構

### C-1. GUI構築（座標すべて明示・ウィンドウ600×470）

```autohotkey
global SnipMgrGui := 0, SnipMgrLV := 0, SnipMgrLabelEd := 0, SnipMgrBodyEd := 0
global SnipMgrStatus := 0, SnipMgrItems := [], SnipMgrClearChk := 0

ShowSnippetManager(*) {
    global SnipMgrGui, SnipMgrLV, SnipMgrLabelEd, SnipMgrBodyEd, SnipMgrStatus, SnipMgrClearChk
    if SnipMgrGui {
        SnipMgrRefresh()               ; 外部編集(メモ帳/取込)を拾うため再表示時は必ず再読込
        SnipMgrGui.Show()
        return
    }
    SnipMgrGui := Gui("+ToolWindow", "定型文の管理")
    SnipMgrGui.SetFont("s9", "Meiryo UI")
    ; NoSort NoSortHdr が必須: ソートを許すと行番号↔SnipMgrItemsの対応が壊れる(G-1参照)
    SnipMgrLV := SnipMgrGui.Add("ListView", "x10 y10 w580 h250 -Multi NoSort NoSortHdr +Grid",
        ["ラベル", "本文"])
    SnipMgrLV.ModifyCol(1, 150), SnipMgrLV.ModifyCol(2, 400)
    SnipMgrLV.OnEvent("ItemSelect", SnipMgrOnSelect)

    SnipMgrGui.Add("Text", "x10 y274 w50 h20", "ラベル")
    SnipMgrLabelEd := SnipMgrGui.Add("Edit", "x64 y270 w300 h24")
    SnipMgrGui.Add("Text", "x10 y304 w50 h20", "本文")
    ; +WantReturn: Enterで改行を入力させる(既定ボタンに食われるのを防ぐ)
    SnipMgrBodyEd := SnipMgrGui.Add("Edit", "x64 y300 w526 h96 +Multi +WantReturn +VScroll")

    SnipMgrGui.Add("Button", "x64 y406 w100 h28", "新規追加").OnEvent("Click", SnipMgrAdd)
    SnipMgrGui.Add("Button", "x172 y406 w100 h28", "上書き保存").OnEvent("Click", SnipMgrSave)
    SnipMgrGui.Add("Button", "x280 y406 w80 h28", "削除").OnEvent("Click", SnipMgrDelete)
    SnipMgrGui.Add("Button", "x430 y406 w76 h28", "CSV出力").OnEvent("Click", (*) => ExportSnippetsCsv(true))
    SnipMgrGui.Add("Button", "x510 y406 w80 h28", "CSV取込").OnEvent("Click", SnipMgrImport)
    SnipMgrClearChk := SnipMgrGui.Add("CheckBox", "x430 y438 w160 h20", "全クリアして取込")
    SnipMgrStatus := SnipMgrGui.Add("Text", "x10 y442 w400 h20 cGray", "")

    SnipMgrGui.OnEvent("Close", (*) => SnipMgrGui.Hide())
    SnipMgrGui.OnEvent("Escape", (*) => SnipMgrGui.Hide())
    SnipMgrRefresh()
    SnipMgrGui.Show("w600 h470")
}
```

### C-2. 行番号付き読込と再描画

```autohotkey
; LoadSnippetsと同じ判定規則だが ini上の行番号を保持する(編集・削除の宛先に使う)
SnipMgrReadItems() {
    items := [], path := A_ScriptDir . "\snippets.ini"
    if !FileExist(path)
        return items
    for n, raw in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
        line := Trim(raw)
        if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "[")
            continue
        eq := InStr(line, "=")
        if !eq
            continue
        label := Trim(SubStr(line, 1, eq - 1)), val := Trim(SubStr(line, eq + 1))
        if (label != "" && val != "")
            items.Push({label: label, value: StrReplace(val, "\n", "`n"), lineNo: n})
    }
    return items
}

SnipMgrRefresh() {
    global SnipMgrLV, SnipMgrItems, SnipMgrLabelEd, SnipMgrBodyEd
    SnipMgrItems := SnipMgrReadItems()
    SnipMgrLV.Delete()
    for s in SnipMgrItems {
        prev := RegExReplace(s.value, "\s+", " ")
        SnipMgrLV.Add(, s.label, (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . SubStr(prev, 1, 80))
    }
    SnipMgrLabelEd.Value := "", SnipMgrBodyEd.Value := ""
}

SnipMgrOnSelect(lv, row, selected) {
    global SnipMgrItems, SnipMgrLabelEd, SnipMgrBodyEd
    if (!selected || row < 1 || row > SnipMgrItems.Length)
        return
    SnipMgrLabelEd.Value := SnipMgrItems[row].label
    SnipMgrBodyEd.Value := StrReplace(SnipMgrItems[row].value, "`n", "`r`n")  ; Editは`r`n(G-2)
}
```

### C-3. 書き込み3操作（fail-closedな行検証付き）

```autohotkey
; 行単位の書換え/削除。書換え前に宛先行のラベルを検証し、外部編集でズレていたら中止(fail-closed)
SnipMgrWriteLine(lineNo, expectLabel, newLine) {
    path := A_ScriptDir . "\snippets.ini"
    lines := StrSplit(FileRead(path, "UTF-8"), "`n", "`r")
    if (lineNo > lines.Length || !RegExMatch(Trim(lines[lineNo]), "^\Q" . expectLabel . "\E\s*="))
        return false                      ; メモ帳等で外部編集された → 呼び元でRefreshさせる
    (newLine = "") ? lines.RemoveAt(lineNo) : lines[lineNo] := newLine
    out := ""
    for l in lines
        out .= l . "`n"
    FileDelete(path)
    FileAppend(RTrim(out, "`n") . "`n", path, "UTF-8")
    return true
}

; フォーム値の取り出し共通部: CRLF正規化＋ラベル無害化(PromoteHistoryAtと同一規則)
SnipMgrFormValues(&label, &body) {
    global SnipMgrLabelEd, SnipMgrBodyEd
    label := RegExReplace(Trim(SnipMgrLabelEd.Value), "[=\[\];]")
    body := StrReplace(SnipMgrBodyEd.Value, "`r`n", "`n")
    return (label != "" && body != "")
}
```

`SnipMgrAdd`は重複ラベル検査→`PromoteHistoryAt`と同じ`FileAppend`追記（末尾改行補正の`nl`イディオムごと流用）→`SnipMgrRefresh()`。`SnipMgrSave`/`SnipMgrDelete`は`SnipMgrLV.GetNext(0)`で選択行を取り、`SnipMgrWriteLine(item.lineNo, item.label, ...)`（保存は`label . "=" . StrReplace(body, "\n", "\n")`、削除は`""`）→ falseが返ったら`SnipMgrRefresh()`して「ファイルが外部で変更されたため再読込しました」をステータス表示。`SnipMgrImport`は`ImportSnippets(SnipMgrClearChk.Value, true)`→`SnipMgrRefresh()`の2行。

## D. 既存関数の扱い

| 関数 | 扱い |
|---|---|
| `LoadSnippets`/`ParseCsv`/`LoadSnippetsCsv`/`CsvField` | **無変更**。`SnipMgrReadItems`は`LoadSnippets`を変形コピーするが、`LoadSnippets`に`lineNo`を足す改造はしない（ランチャー側の呼び出し複数箇所に波及させないため） |
| `ExportSnippetsCsv(dlg:=true)` | **無変更で流用**。`SetCsvStatus`の出力先を`SnipMgrStatus`に付け替えるだけ |
| `ImportSnippets(clearFirst, dlg:=true)` | **無変更で流用**。呼び元`SnipMgrImport`が取込後に`SnipMgrRefresh()`を呼ぶ |
| `ShowCsvDialog` | **退役・削除**（約23行減）。機能は新ウィンドウに完全包含される。歯車メニューとトレイメニューの「定型文CSV出力/取込...」項目を「定型文の管理...」→`ShowSnippetManager`に差し替え |
| `ShowLauncherSettingsMenu` | 項目差し替えのみ。「定型文ファイルを編集 (snippets.ini)」は**温存**（メモ帳直編集は上級者向け脱出ハッチとして残す価値がある） |
| `PromoteHistoryAt`/`UseSnippetAt`/`ShowLauncher` | **完全無変更**。履歴→昇格の動線もランチャーの定型文タブ（ワンキーペースト主動線）も一切触らない |
| `ClipHistory`関連 | **不可侵**。管理ウィンドウは`ClipHistory`に一切触れない。読み書きするのはsnippets.iniのみ |

## E. MVP

A〜Cの全部がMVP。**MVPに入れないもの**: 行の並べ替え（上へ/下へボタン）、複数選択削除、列ソート、ListView上の右クリックメニュー、インライン編集、検索。どれも「一覧性」という核心要望に寄与しない。

## F. 捨てた案と理由

1. **カスタム描画ListBoxで既存ポップアップ内に完結**（会議のgpt-oss-120b対案）: 却下。「軽い」という主張が成立しない。ListBoxで2列風の表示をするにはタブ文字整形かオーナードローが必要で、前者は等幅の崩れ、後者はListView以上の行数になる。さらにランチャー同居は`CheckLauncherFocus`（フォーカス喪失で自殺するGUI）と管理フォームの編集中状態が根本的に相性最悪。
2. **インライン編集**（セル直接編集）: 却下。ListView上にEditを重ねるのはLVM_GETSUBITEMRECTのSendMessage直叩き＋スクロール追従が要り、確実に地雷原。
3. **全文書き直し方式の保存**: 却下（B節で詳述）。コメント行消失と重複ラベル誤爆の2重リスク。
4. **列ヘッダクリックのソート**: 却下。ソートすると表示行↔`SnipMgrItems`インデックス↔ini行番号の3者対応が壊れ、**別の定型文を上書き・削除する**最悪級のバグ源になる。`NoSort NoSortHdr`で封印。
5. **削除時のMsgBox確認**: 却下。マウス操作のテンポ優先。CSV出力がバックアップ手段として同一画面にある。
6. **`ListView.New()`等の非実在API**（会議の一部メンバーが提示）: 論外・全捨て。

## G. 地雷と回避策

- **G-1 ソートによる行対応破壊**: `NoSort NoSortHdr`は必須オプションであり省略不可。実装者への最重要申し送り。
- **G-2 Editコントロールの改行はCRLF**: `Edit.Value`への代入は`` `r`n ``、取り出し後は`StrReplace(v, "`r`n", "`n")`で正規化してからini書き込み（`\n`エスケープ）とCSV（実改行）の各経路へ。ここを混同するとini内に生`` `r ``が混入し、次回`LoadSnippets`で本文末尾が壊れる。
- **G-3 シングルトンの陳腐化**: `ShowCsvDialog`流儀の`Hide()`温存は、再表示時に古い一覧が見える罠を持つ。`Show()`前の`SnipMgrRefresh()`を絶対に省略しない。書き込み系は`SnipMgrWriteLine`のラベル検証で外部編集を検出して中止する（メモ帳並行編集への防御）。
- **G-4 `+WantReturn`忘れ**: 本文Editで省略すると、Enterがダイアログ既定動作に吸われて改行が打てない。
- **G-5 `ItemSelect`イベントのシグネチャ**: コールバックは`(lv, row, selected)`で、選択解除時も`selected=false`で発火する。`selected`チェックを省くと選択解除のたびにフォームへ`row`の残骸が読み込まれる。
- **G-6 FileSelectの親**: `ExportSnippetsCsv`/`ImportSnippets`内の`FileSelect`はオーナー指定なしのグローバルダイアログ。管理ウィンドウは`+AlwaysOnTop`を**付けない**こと（付けるとファイル選択ダイアログの背後に被さる）。`+ToolWindow`のみで十分。
- **G-7 ランチャーとの同時表示**: 歯車メニューから開いた瞬間、ランチャーはフォーカス喪失で自動クローズする（既存の`CheckLauncherFocus`仕様）。これは正常系として受け入れる。管理ウィンドウをランチャーのオーナー付き(`+Owner`)にしてはならない — オーナーの`Destroy()`に巻き込まれて消える。

## 行数見積もり

既存パターン実測（`ShowCsvDialog`=23行、`ShowLauncher`=41行、`PromoteHistoryAt`=20行）からの積算:

| 部品 | 行数 |
|---|---|
| グローバル宣言＋`ShowSnippetManager` | 40 |
| `SnipMgrReadItems`＋`SnipMgrRefresh`＋`SnipMgrOnSelect` | 42 |
| `SnipMgrWriteLine`＋`SnipMgrFormValues` | 24 |
| `SnipMgrAdd`＋`SnipMgrSave`＋`SnipMgrDelete`＋`SnipMgrImport` | 52 |
| コメント行 | 12 |
| メニュー差し替え（歯車＋トレイ） | ±0（置換） |
| `ShowCsvDialog`削除 | −23 |
| `SetCsvStatus`付け替え | ±0（置換） |

**増加 約170行 → 831行から約1000行前後（950〜1020行のレンジ）**。600-700行目安は既に超過済みであり、この+170行は「メモ帳直編集しか手段がなかった管理機能」への投資として妥当。これ以上増える兆候（並べ替え・検索・タグ等の要望）が出たら、その時が単一ファイル分割を検討する節目。
