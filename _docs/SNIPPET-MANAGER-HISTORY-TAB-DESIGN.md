# 設計書: 「定型文の管理」ウィンドウへの履歴タブ追加

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 969行/v1.5.0)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・5/5成功、lead役含め全員応答) / 裏取り=司令塔Claude
> 日付: 2026-07-15
> 前提: [`SNIPPET-MANAGER-DESIGN.md`](SNIPPET-MANAGER-DESIGN.md)（定型文の管理ウィンドウ・実装済み）への機能追加

## 裏取りメモ（司令塔による検証）

会議で「45秒以内に数千件蓄積してCPUスパイク」（gpt-oss-120b, critic役）という性能懸念が出たが、
実地調査の結果`global ClipHistory := [], ClipHistoryMax := 30`（既定30件上限、`PushClipHistory`内の
`while (ClipHistory.Length > ClipHistoryMax) Pop()`で構造的に保証）と確認し、事実誤認として却下した。
同様に「クイックペーストランチャーの履歴が別の時間制限を持つ」（qwen3-32b, critic役）も事実誤認 —
両者は同じ`ClipHistory`配列を参照する独立した表示コンポーネント（`LauncherLbH`と新設`SnipMgrHistLV`）
であり、データソースは単一。

Fableの設計は「Tab3のUseTab機構によりCSV出力ボタン等が履歴タブ表示中は自動的に不可視・操作不能になる」
という点を活用し、誤操作防止のためのEnable/Visible切替コードを一切書かずに済ませている。これは会議の
lead/fast両モデルが提案した「イベントハンドラでボタンを非表示にする」という案より優れた解決。

## 結論の要約

| 項目 | 判定 |
|---|---|
| 位置づけ | **Tab3で「定型文」「履歴」の2タブ構成**（既存ウィンドウ内、別ウィンドウ化は却下） |
| 検索実装 | **総入れ替え方式**（`ListView.Delete()`→再構築）。性能懸念は事実誤認のため却下 |
| ソート | **新しい順で固定**。ヘッダクリックでの昇順/降順切替は実装しない（行対応破壊のリスク） |
| 誤操作防止 | **UseTab機構が自動解決**（コード0行）。CSV/追加/保存/削除ボタンは定型文タブ内に留まり、履歴タブでは触れない |
| ペースト機能 | **持たせない**（コピー専用ビュー）。貼り付け先フォーカス捕捉機構がないため |
| 見積もり行数 | 約+70〜95行（969行 → 約1,045〜1,065行） |

---

## A. 理想の体験フロー

1. トレイメニュー等から「定型文の管理」を開くと、ウィンドウ上部に **[定型文] [履歴 N]** の2タブが見える。既定は従来通り定型文タブ（既存動線を一切変えない）。
2. 「履歴」タブをクリックすると、**日時/本文の2列ListView**に最大30件が新しい順で並ぶ。上部に検索ボックスと「N件 / 保存されません」の注記。
3. 検索ボックスに文字を打つたびリストが絞り込まれる（本文と日時文字列の両方に部分一致・大文字小文字無視）。「07/14」と打てば昨日のコピーだけに絞れる。
4. 行を選択すると下の**読み取り専用の全文プレビュー**に本文全体が表示される（ListViewは先頭100文字しか見せないため）。
5. 「クリップボードへコピー」ボタン、または**行のダブルクリック**でその本文をクリップボードに載せる。ステータス行に「コピーしました」。

**ペースト機能は持たせない**。管理ウィンドウは通常ウィンドウで、開いた時点で貼り付け先のフォーカスが失われている。ランチャー側は`LauncherTarget := WinExist("A")`で貼り付け先を捕捉してから出る設計であり、その機構を複製すると「速度動線はランチャー、探索動線はマネージャ」という役割分担を壊す。コピーまでやれば十分。

## B. 統合アーキテクチャ

新設グローバル:

| 名前 | 型 | 役割 |
|---|---|---|
| `SnipMgrTab` | Tab3コントロール | 定型文/履歴の切替 |
| `SnipMgrHistLV` | ListView | 履歴2列表示（日時/本文） |
| `SnipMgrHistEd` | Edit | 検索ボックス |
| `SnipMgrHistPrev` | Edit(+ReadOnly) | 選択行の全文プレビュー |
| `SnipMgrHistCount` | Text | 「N件」表示 |
| `SnipMgrHistRows` | Array | 表示中の行↔履歴要素の対応表。**インデックスではなく要素オブジェクトの参照を保持**（G-3） |

新設関数:

| 関数 | 役割 |
|---|---|
| `SnipMgrHistRefresh()` | `ClipHistory`を検索語でフィルタし総入れ替え |
| `SnipMgrHistOnSelect(lv, row, selected)` | 選択行の全文をプレビューEditへ |
| `SnipMgrHistCopy(*)` | 選択行の本文をクリップボードへ |
| `SnipMgrTabChanged(tab, *)` | タブ切替時に履歴タブなら再構築 |

既存関数の変更は`ShowSnippetManager()`のGUI構築部のみ（Tab3挿入と座標シフト）。データ層（`SnipMgrRefresh`/`SnipMgrWriteLine`/`SnipMgrReadItems`）は無変更。

## C. 具体機構

### C-1. Tab3の挿入と既存コントロールの収容

```autohotkey
    SnipMgrGui := Gui("+ToolWindow", "定型文の管理")
    SnipMgrGui.SetFont("s9", "Meiryo UI")
    SnipMgrTab := SnipMgrGui.Add("Tab3", "x0 y0 w600 h496 -Wrap", ["定型文", "履歴"])
    SnipMgrTab.OnEvent("Change", SnipMgrTabChanged)

    SnipMgrTab.UseTab(1)
    ; --- 既存コントロール群。y座標のみ全て+26（x/w/hは不変） ---
    SnipMgrLV := SnipMgrGui.Add("ListView", "x10 y36 w580 h250 -Multi NoSort NoSortHdr +Grid",
        ["ラベル", "本文"])
    ; ...（ラベルy300/y296, 本文y330/y326, ボタン行y432, チェックy464 — G-1の座標表参照）
```

### C-2. 履歴タブの構築（座標全明示）

```autohotkey
    SnipMgrTab.UseTab(2)
    SnipMgrGui.Add("Text", "x10 y40 w40 h20", "検索")
    SnipMgrHistEd := SnipMgrGui.Add("Edit", "x54 y36 w280 h24")
    SnipMgrHistEd.OnEvent("Change", (*) => SnipMgrHistRefresh())
    SnipMgrHistCount := SnipMgrGui.Add("Text", "x344 y40 w246 h20 cGray", "")
    SnipMgrHistLV := SnipMgrGui.Add("ListView", "x10 y66 w580 h240 -Multi NoSort NoSortHdr +Grid",
        ["コピー日時", "本文"])
    SnipMgrHistLV.ModifyCol(1, 150), SnipMgrHistLV.ModifyCol(2, 400)
    SnipMgrHistLV.OnEvent("ItemSelect", SnipMgrHistOnSelect)
    SnipMgrHistLV.OnEvent("DoubleClick", (lv, row) => SnipMgrHistCopy())
    SnipMgrGui.Add("Text", "x10 y316 w50 h20", "全文")
    SnipMgrHistPrev := SnipMgrGui.Add("Edit", "x64 y312 w526 h108 +ReadOnly +Multi +VScroll")
    SnipMgrGui.Add("Button", "x64 y428 w170 h28", "クリップボードへコピー").OnEvent("Click", SnipMgrHistCopy)
    SnipMgrGui.Add("Text", "x244 y434 w340 h20 cGray", "履歴は最大" . ClipHistoryMax . "件・このPC内のみ・保存されません")

    SnipMgrTab.UseTab()   ; ← 必須。以降のステータス行を両タブ共通にする
    SnipMgrStatus := SnipMgrGui.Add("Text", "x10 y500 w400 h20 cGray", "")
    ; ...
    SnipMgrGui.Show("w600 h528")   ; 従来 w600 h470 → +26(タブ) +32(ステータス外出し)
```

### C-3. フィルタ＆総入れ替え

```autohotkey
SnipMgrHistRefresh() {
    global ClipHistory, SnipMgrHistLV, SnipMgrHistEd, SnipMgrHistRows, SnipMgrHistCount, SnipMgrHistPrev
    q := Trim(SnipMgrHistEd.Value)
    SnipMgrHistRows := []
    SnipMgrHistLV.Delete()
    for v in ClipHistory {                       ; 配列は常に新しい順（PushClipHistoryが先頭挿入）
        if (q != "" && !InStr(v.text, q, false) && !InStr(v.time, q, false))
            continue
        SnipMgrHistRows.Push(v)                  ; 要素オブジェクトの参照を保持（G-3）
        disp := StrReplace(StrReplace(v.text, "`r", ""), "`n", " ⏎ ")
        SnipMgrHistLV.Add(, v.time, SubStr(disp, 1, 100))
    }
    SnipMgrHistCount.Text := SnipMgrHistRows.Length . " 件"
        . (q != "" ? " （絞り込み中 / 全" . ClipHistory.Length . "件）" : "")
    SnipMgrHistPrev.Value := ""
}
```

### C-4. 選択→プレビュー、コピー

```autohotkey
SnipMgrHistOnSelect(lv, row, selected) {
    global SnipMgrHistRows, SnipMgrHistPrev
    if (!selected || row < 1 || row > SnipMgrHistRows.Length)
        return
    v := SnipMgrHistRows[row]
    SnipMgrHistPrev.Value := StrReplace(v.text, "`n", "`r`n")   ; EditはCRLF
}

SnipMgrHistCopy(*) {
    global SnipMgrHistLV, SnipMgrHistRows
    row := SnipMgrHistLV.GetNext(0)
    if (!row || row > SnipMgrHistRows.Length) {
        SetCsvStatus("コピーする履歴を選択してください")
        return
    }
    A_Clipboard := SnipMgrHistRows[row].text
    SetCsvStatus("クリップボードへコピーしました")
}
```

### C-5. タブ切替時と再表示時のリフレッシュ

```autohotkey
SnipMgrTabChanged(tab, *) {
    if (tab.Value = 2)
        SnipMgrHistRefresh()
}
```

既存の再表示パス（`if SnipMgrGui { SnipMgrRefresh() ... }`）に `SnipMgrHistRefresh()` を1行追加。

## D. 既存機能との関係

- **`LauncherLbH` / `HistoryListItems()` / `PasteHistoryAt()`**: 一切触らない。`HistoryListItems()`の再利用もしない（ワンキーペースト専用フォーマットで2列ListViewには不適）。共有するのはデータソース`ClipHistory`のみ、読むだけで書かない。
- **CSV出力/CSV取込/新規追加/上書き保存/削除ボタン＋全クリアチェックボックス**: すべて`UseTab(1)`配下に置くため、履歴タブ表示中はOSが不可視・操作不能にする。制約（履歴のエクスポート禁止）はコードではなくコントロール階層で担保される。
- **`SnipMgrStatus`**: `UseTab()`で共通領域に移し、両タブのフィードバックを1本で表示。`SetCsvStatus()`は無変更で共用。
- **`SnipMgrGui`シングルトン＋`Hide()`パターン**: 無変更。
- **`SnipMgrWriteLine`（snippets.ini書き込み）**: 履歴タブから到達不能。

## E. MVP

1. Tab3化＋既存コントロールのタブ1収容（座標+26シフト）
2. 履歴タブ: 検索Edit＋2列ListView（新しい順固定）＋件数表示
3. 全文プレビュー（ReadOnly Edit）
4. コピー（ボタン＋ダブルクリック）
5. タブ切替時・再表示時のリフレッシュ

**含めないもの**: ソート切替、履歴の個別削除（ランチャー側の右クリックメニューに既にある）、履歴の編集、タグ、ペースト、永続化・エクスポート全般。

## F. 捨てた案と理由

| 案 | 出所 | 捨てた理由 |
|---|---|---|
| 別ウィンドウ | critic(qwen3-32b) | 論拠が事実誤認で崩壊。シングルトン管理・Hide/Show・座標管理を丸ごと複製するだけで保守コストが増える |
| ラジオボタンで同一ListViewの中身を差し替え | diverge(qwen3.6-27b) | `SnipMgrLV`は行番号ベースの破壊的書き込み(`SnipMgrWriteLine`)に配線されている。モードフラグの分岐漏れで「履歴行を選択したつもりが定型文を削除」という事故に直結する |
| 検索のデバウンス・差分更新 | critic(gpt-oss-120b)ほか | 性能懸念は事実誤認（上限30件）。総入れ替えで体感ゼロ。デバウンスはバグ表面積を増やすだけ |
| 列ヘッダクリックでの昇順/降順 | ユーザー要望文言「日付順ソート」 | 配列が既に新しい順＝要望の実体は満たしている。ヘッダソートを許すと行対応が壊れ、コピー誤爆の温床になる |
| 履歴タブからの直接ペースト | — | 貼り付け先フォーカスの捕捉機構が管理ウィンドウに無く、役割分担を壊す |
| CSVボタンのEnable/Visible切替コード | lead・fast(Q4) | UseTab(1)配下に置けばTab3が自動で不可視化する。イベント処理0行で同じ結果 |

## G. 地雷と回避策

1. **座標シフトの取りこぼし**: Tab3挿入で既存12コントロール全部のyを+26する必要がある。対応表: LV `y10→36` / ラベルText `y274→300`・Edit `y270→296` / 本文Text `y304→330`・Edit `y300→326` / ボタン5個 `y406→432` / チェック `y438→464`。ステータスは`UseTab()`後に`y500`へ外出し、`Show("w600 h470")`→`Show("w600 h528")`。1つでも漏れるとタブヘッダに重なるか別タブに紛れる。
2. **`UseTab()`の閉じ忘れ**: 履歴タブのコントロール追加後に`SnipMgrTab.UseTab()`を呼ばないと、ステータス行やOnEvent配線以降のコントロールがタブ2専用になる。
3. **コピーが履歴自身を書き換える**: `A_Clipboard := text`はクリップボード監視経由で`PushClipHistory`を発火させ、重複昇格ロジックがその要素を配列先頭へ移動させる。表示中のLVと`ClipHistory`のインデックス対応はこの瞬間ズレる。回避策: `SnipMgrHistRows`にインデックスではなく要素オブジェクトの参照を持たせる（C-3）。コピー直後の強制リフレッシュはしない（選択状態が飛んで連続コピーの邪魔になるため）。
4. **改行・長文のLV表示**: 履歴テキストは複数行・数万文字があり得る。LVセルには`\r`除去＋`\n`→`" ⏎ "`置換＋`SubStr(…,1,100)`で渡す。原文は`SnipMgrHistRows`側に無傷で残る。
5. **プレビューEditの改行**: `ClipHistory`内はLF混在があり得るがEditはCRLF。`StrReplace(text, "`n", "`r`n")`で統一。
6. **`NoSort NoSortHdr`は履歴LVにも付ける**: ソートされると行↔`SnipMgrHistRows`対応が崩れる。定型文タブと同じ理由で固定。
7. **検索EditのChangeはIME変換中も発火**: 30件総入れ替えなので実害なし。デバウンス追加は不要。
8. **`ClipHistoryMax`はiniで可変**: 注記テキストは「最大30件」とハードコードせず`ClipHistoryMax`変数を埋め込む。
9. **既存グローバル宣言への追記漏れ**: `ShowSnippetManager()`冒頭の`global`行に新設変数を足し忘れるとv2は未定義エラーではなくローカル変数として黙って動き、シングルトン再表示で壊れる。

## 行数見積もり

| 内訳 | 行数 |
|---|---|
| グローバル宣言追加＋Tab3生成＋Change配線 | +5 |
| 履歴タブGUI構築 | +14 |
| `SnipMgrHistRefresh` | +18 |
| `SnipMgrHistOnSelect` | +8 |
| `SnipMgrHistCopy` | +11 |
| `SnipMgrTabChanged`＋再表示パス1行 | +6 |
| コメント | +8〜12 |
| 既存行の変更（座標シフト・Show行・global行） | ±0（増加なし） |

**合計 約+70〜95行。969行 → 約1,045〜1,065行。**
