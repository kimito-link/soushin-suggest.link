# ランチャー「クリップボード」タブ管理機能 設計書

> 3段構え（会議ハーネス→Fable設計→実装）の成果物。COUNCIL-HOWTO.md準拠。
> 会議ハーネス素材: `tsuioku-no-kirameki.com/council/soushin-suggest-launcher-management-features.md` / `.answers.json`
> 設計: Fable(claude-fable-5)。司令塔Claudeが実コードで裏取り済み。

対象: `dist/soushin-suggest.ahk`（v1.22.8、3222行）

## 発端（ユーザー要望）

「定型文タブには編集・削除・↑↓移動・新規登録・検索・ページ切り替えの右クリックメニューがあるのに、クリップボード履歴タブには無い。実装してほしい。他にも使いやすい機能を」

## A. 現状の要約（実コードで裏取り済み）

1. **ユーザーが見たメニューは「定型文の管理」という別ウィンドウのもの**。`SnipMgrContextMenu()`（1404行）が編集/削除/↑↓移動/新規登録を持つ。ランチャー本体には無い。Ctrl+Shift+N / Ctrl+Shift+F はコード全体に存在しない。「実装済み機能の移植」ではなく新規設計。
2. ランチャー履歴タブの右クリックメニュー（`LauncherContextMenu` 2957行）は「開く/定型文に登録/この履歴を削除/履歴を全削除」の4項目。定型文タブ（`LauncherLvS`）は右クリックしても何も起きない。
3. **重複排除は実装済み**: `PushClipHistory`（619行）が同文再コピーを先頭昇格でdedup。復元時も`FinishHistoryStoreLoad`（2599行）が`seen` Mapでdedup。
4. **検索は実装済み**: `LauncherSearchEdit`が全件走査・表示500件打ち切り（`FillLauncherHistoryLV` 3104行、`DisplayMax := 500`）。ただし検索対象は本文のみ（3116行）。
5. **重大バグ（司令塔が実コードで裏取り確認済み）**: `DeleteHistoryAt(idx)`（3004行）はメモリの`ClipHistory`配列から削除するだけで、永続ストア`history-store.csv`（追記式、`AppendHistoryStore` 2558行）には触れない。71行の`HistStoreRewritePending`フラグは宣言のみで未使用（参照ゼロ）。永続化は既定ON（`ClipHistoryPersist := true`）のため、**「この履歴を削除」で消したはずの項目が、アプリ再起動後に復活する**。対照的に`DeleteHistoryAll`（3011行）は`FileDelete(HistoryStorePath())`でストアごと消しており対策済み——単一削除だけが手薄。プライバシー訴求の製品として看過できない。
6. 「履歴を全削除」は確認なしで即実行。実質無制限保存（`ClipHistoryMax := 999999`）の現在、誤クリック1回で全喪失するリスクが高い。
7. 「定型文の管理」ウィンドウには既に履歴タブがある（1060行、時刻列+プレビュー+検索+2000件表示、貼り付けない再コピー機能付き）。フル機能画面は既存だが入口がトレイメニューのみで発見性が低い。
8. 潜在バグ: 既存メニューはクロージャに行インデックス`idx`を束縛。メニュー表示中も監視は生きており、新規コピーが`InsertAt(1)`で先頭に積まれると`idx`が1ずれ、隣の項目を誤操作する。

## B. 設計判断

### 問い1: 「編集」「手動↑↓移動」の移植価値 — 無い

- 並び替え: `ClipHistory`は「常に新しい順・先頭積み」が不変条件。手動並び順は次のコピー1回で崩れる。
- 編集: 追記式ストアのため編集しても再起動で旧内容が蘇る（削除と同じ構造問題）。画像項目は編集不能。実ニーズは既存の「定型文に登録」→管理画面で編集、で足りる。
- **どちらも移植しない**。「重要項目を上に固定したい」という実ニーズは第2歩の「ピン留め」で満たす。

### 問い2: 履歴ならではの高価値機能

採用（優先順）:
1. 単品削除の永続反映（蘇りバグ修理・最優先）
2. 「コピーのみ（貼り付けない）」— ランチャーは行クリック即ペーストのため、戻すだけの操作が現状できない
3. 「履歴を全削除」への確認ダイアログ
4. 履歴検索の日時対応（1行追加）
5. 管理画面（既存フル機能）への導線
6. 定型文タブの右クリックメニュー新設（ユーザー誤認の根本原因に対応）
7. （第2歩）ピン留め

不採用: 重複排除・検索新設（既存）、頻度ソート・種類フィルタ・日付範囲ドロップダウン・セッショングルーピング（F節参照）。

999999件前提のページングは追加しない。「検索が正・スクロールは直近500件用」という現状構造が正しい。打ち切りの可視化のみ第3歩で検討。

### 問い3: レイアウト制約内の実装方式

**右クリックメニュー拡張＋既存管理画面への導線のみ。ボタン行・新ウィンドウは作らない。**

メニュー拡張はGUIレイアウト変更ゼロで描画地雷（G節）に一切触れない唯一の方式。フッターロゴのアンカー（1631-1644行、Tab3下端の1点アンカー）に触れるボタン行案は過去の修正履歴（コミット8e19aff）を踏まえ却下。

### 問い4: MVP

**第0歩（削除の永続反映）＋第1歩（メニュー拡充・新設）**。

## C. 具体的な文言・コード変更案

### C-1. 履歴タブ右クリックメニュー（`LauncherContextMenu` 2957行を置換）

```
このファイルを開く／このフォルダを開く   ← 既存・実在パス時のみ
定型文に登録                       ← 既存・textのみ
コピーのみ（貼り付けない）             ← 新規・text/image両対応
─────────────
この履歴を削除                     ← 既存＋永続反映(C-3)
履歴を全削除...                    ← 既存＋確認(C-4)
─────────────
管理画面で履歴を見る                 ← 新規(C-5)
```

**規約: クロージャには`idx`でなく要素参照`v`を束縛する**（A-8のずれバグ対策）。

```ahk
LauncherContextMenu(g, ctrl, item, isRC, x, y) {
    global LauncherLvH, LauncherLvS, ClipHistory, LauncherGui, Snippets
    if (ctrl = LauncherLvH) {
        idx := ResolveHistRow(LauncherLVItemUnderMouse(LauncherLvH))
        if (idx < 1 || idx > ClipHistory.Length)
            return
        v := ClipHistory[idx]                 ; 参照を掴む。以降idxは使わない
        SetTimer(CheckLauncherFocus, 0)
        m := Menu()
        if (v.type = "text") {
            if (p := RunnablePathFrom(v.text))
                m.Add(InStr(FileExist(p), "D") ? "このフォルダを開く" : "このファイルを開く", (*) => OpenHistoryPath(p))
            m.Add("定型文に登録", (*) => PromoteHistoryItem(v))
        }
        m.Add("コピーのみ（貼り付けない）", (*) => CopyHistoryItem(v))
        m.Add()
        m.Add("この履歴を削除", (*) => DeleteHistoryItem(v))
        m.Add("履歴を全削除...", (*) => ConfirmDeleteHistoryAll())
        m.Add()
        m.Add("管理画面で履歴を見る", (*) => OpenHistoryManagerFromLauncher())
        m.Show()
        if IsObject(LauncherGui)
            SetTimer(CheckLauncherFocus, 150)
    } else if (ctrl = LauncherLvS) {
        ; --- 定型文タブ: 新設(C-2) ---
    }
}
```

参照ベースのヘルパー（既存`DeleteHistoryAt(idx)`/`PromoteHistoryAt(idx)`のidx経路＝数字キー選択等は残す。新規メニュー経路のみ以下を使う）:

```ahk
DeleteHistoryItem(v) {
    global ClipHistory
    for i, x in ClipHistory
        if (x = v) {                          ; オブジェクト同一性比較(AHK v2は参照比較)
            ClipHistory.RemoveAt(i)
            if (v.type = "text")
                HistStoreMarkDeleted(v.text)   ; C-3
            break
        }
    RefreshLauncherHistory()
}

CopyHistoryItem(v) {
    CloseLauncher()
    if (v.type = "image") {
        if (dib := GetImageDib(v)) && SetClipboardImage(dib)
            Flash("画像をコピーしました", 1200)
    } else {
        A_Clipboard := v.text                 ; 監視が拾い先頭昇格するのは意図どおり
        Flash("コピーしました（貼り付けはしていません）", 1400)
    }
}
```

### C-2. 定型文タブ右クリックメニュー（新設）

snippets.ini書き換えロジックは`SnipMgr*`が正本。ランチャー側に削除/編集の複製実装はしない（正本1つ原則）。導線に徹する:

```
この定型文を使う           ← 行上のときのみ
─────────────
編集・削除（定型文の管理）    ← SnipMgrを開き定型文タブ
新規登録（定型文の管理）     ← SnipMgrを開き新規フォーム
```

```ahk
    } else if (ctrl = LauncherLvS) {
        idx := ResolveSnipRow(LauncherLVItemUnderMouse(LauncherLvS))
        SetTimer(CheckLauncherFocus, 0)
        m := Menu()
        if (idx >= 1 && idx <= Snippets.Length) {
            m.Add("この定型文を使う", (*) => UseSnippetAt(idx))
            m.Add()
        }
        m.Add("編集・削除（定型文の管理）", (*) => (CloseLauncher(), ShowSnippetManager()))
        m.Add("新規登録（定型文の管理）", (*) => (CloseLauncher(), ShowSnippetManager(), SnipMgrNewForm()))
        m.Show()
        if IsObject(LauncherGui)
            SetTimer(CheckLauncherFocus, 150)
    }
```

### C-3. 削除の永続反映（第0歩・蘇りバグ修理）

方針: ストア全体をメモリ内容で書き直す方式は採らない（`ClipHistLoadMax`既定10000件打ち切りでメモリに無い古い行が消えるとデータロス）。**削除本文リストによる差分書き直し**:

```ahk
global HistStoreDeletedTexts := []            ; 「この履歴を削除」された本文。書き直し確定でクリア

HistStoreMarkDeleted(text) {
    global HistStoreDeletedTexts, ClipHistoryPersist, HistStoreRewritePending
    if !ClipHistoryPersist
        return
    HistStoreDeletedTexts.Push(text)
    HistStoreRewritePending := true
    SetTimer(RewriteHistStoreIfPending, -2000)   ; 連続削除を1回にまとめる
}

RewriteHistStoreIfPending() {
    global HistStoreRewritePending, HistStoreDeletedTexts
    if !HistStoreRewritePending
        return
    HistStoreRewritePending := false
    path := HistoryStorePath()
    if !FileExist(path)
        return (HistStoreDeletedTexts := [])
    del := Map()
    for t in HistStoreDeletedTexts
        del[t] := 1
    try {
        rows := ParseCsv(RegExReplace(FileRead(path, "UTF-8"), "^\x{FEFF}"))
        out := "time,type,text`r`n"
        for i, row in rows {
            if (i = 1 && row.Length >= 3 && Trim(row[1]) = "time")
                continue
            if (row.Length < 3 || del.Has(row[3]))
                continue
            out .= CsvField(row[1]) . "," . CsvField(row[2]) . "," . CsvField(row[3]) . "`r`n"
        }
        tmp := path . ".tmp"
        try FileDelete(tmp)
        FileAppend(out, tmp, "UTF-8")
        FileMove(tmp, path, 1)                 ; 一時ファイル→原子的差し替え
        HistStoreDeletedTexts := []            ; 成功時のみクリア
    }
}
OnExit((*) => RewriteHistStoreIfPending())     ; 削除直後2秒以内の終了でも蘇らせない
```

### C-4. 全削除の確認ダイアログ

```ahk
ConfirmDeleteHistoryAll(*) {
    global ClipHistory
    CloseLauncher()                            ; MsgBoxより先に閉じる(G-4)
    if (MsgBox("クリップボード履歴 " . ClipHistory.Length . " 件をすべて削除します。`n"
        . "保存済みの履歴ファイルも消え、元に戻せません。よろしいですか？",
        "履歴を全削除", "YesNo Icon! Default2") = "Yes")
        DeleteHistoryAll()
}
```

トレイメニュー3200行付近「クリップボード履歴を全削除」も`ConfirmDeleteHistoryAll`に差し替え（確認の正本を1つにする）。

### C-5. 管理画面への導線

```ahk
OpenHistoryManagerFromLauncher(*) {
    global SnipMgrTab, SnipMgrHistEd, LauncherSearchEdit
    q := IsObject(LauncherSearchEdit) ? Trim(LauncherSearchEdit.Value) : ""
    CloseLauncher()
    ShowSnippetManager()
    SnipMgrTab.Value := 2
    if (q != "")
        SnipMgrHistEd.Value := q               ; 検索語を引き継ぐ
    SnipMgrHistRefresh()                       ; Tab.Value代入はChangeイベント非発火のため明示呼び出し必須
}
```

### C-6. 検索の日時対応

`FillLauncherHistoryLV` 3116行を:

```ahk
        if (query != "" && !InStr(s, query) && !InStr(v.time, query))
            continue
```

### C-7. （第2歩・別設計書に切り出し）ピン留め概略

- `v.pinned := true`。メニューに「ピン留め／解除」トグル。
- `FillLauncherHistoryLV`を2パス化（ピン行→通常行）。視覚表現は行頭「📌 」のみ、`LauncherLVCustomDraw`には触れない。
- dedup昇格時、ピン項目は時刻のみ更新し位置は動かさない。
- 永続化は`type`列に`pin`を追加。旧ローダーは未知typeを無視するため前方互換。

### C-8. （第3歩・任意）500件打ち切りの可視化

打ち切り行数をカウントし「…残りN件は検索で絞り込み」を末尾に追加表示。`LauncherHistFilterMap`に積まないため誤クリックしても既存の境界チェックで無害。

## D. 実装順序

| 順 | 内容 | 触る関数 | リスク |
|---|---|---|---|
| 第0歩 | 削除の永続反映（C-3） | `DeleteHistoryAt`系, 新規2関数, OnExit | 低（GUI非接触・fail-closed） |
| 第1歩 | メニュー拡充・新設+全削除確認+日時検索（C-1,2,4,5,6） | `LauncherContextMenu`, トレイ1項目, 3116行 | 低（レイアウト変更ゼロ） |
| 第2歩 | ピン留め（C-7） | `FillLauncherHistoryLV`, `PushClipHistory`, ストア | 中（別設計書） |
| 第3歩 | 打ち切り表示（C-8） | — | 低 |

各歩で個別コミット。第0歩の検証: 「履歴を1件削除→アプリ再起動→蘇らないこと」＋「history-store.csvに他の行が残っていること」。第1歩の検証: 「メニュー表示中に別アプリでコピー→削除しても対象がずれないこと」。

## E. MVP

**第0歩＋第1歩**。ユーザーの原要望（右クリックメニューが無い）に正面から答えつつ、その裏で腐っていた削除の永続化を先に修理する。編集・並び替えは載せず、「管理画面で履歴を見る」導線で既存フル機能画面に接続することで新規UI開発ゼロのまま体感を成立させる。

## F. 却下案と理由

| 案 | 出所 | 却下理由 |
|---|---|---|
| 履歴の「編集」 | ユーザー要望(誤認由来) | 追記式ストアと矛盾し再起動で巻き戻る。画像は編集不能 |
| 手動↑↓並び替え | 同上 | 先頭積み不変条件+dedup昇格で即崩壊。代替はピン留め |
| 重複排除 | 会議(qwen) | 既に実装済み（619行・2599行） |
| 検索機能の新設 | 会議全体 | 既存。やるのは日時対応の1行だけ |
| 頻度順ソート | 会議(qwen) | 使用回数の追跡基盤が無く、dedup昇格が実質「最近使った順」を既に作っている |
| 種類フィルタ | 会議(qwen) | 幅460pxに置き場が無い。要望が出たら管理画面側で検討 |
| 日付フィルタドロップダウン | 会議(gpt-oss) | UI追加なしの日時検索（C-6）で大半の用が足りる |
| リスト下部のボタン行/フィルタバー | 会議(gpt-oss, llama) | フッターアンカー地雷（G-2）に正面衝突 |
| ページ切り替え | 会議(llama) | 検索が正・スクロールは直近用という既存構造が正しい |
| セッショングルーピング | 会議(qwen) | 独自色過剰・Clibor同等という製品方針から逸脱 |
| Ctrl+Shift+N/F のランチャー実装 | ユーザー要望(誤認由来) | コードに存在しない表記。ランチャーは開いた瞬間に検索Editへフォーカス済みでCtrl+Fは無意味 |
| ランチャー側での定型文削除・編集の直接実装 | 検討・却下 | 正本は`SnipMgr*`。複製は正本1つ原則違反 |

## G. 地雷と回避策

1. **WS_EX_COMPOSITED再提案は絶対禁止**（メモリ[[feedback_ws_ex_composited_causes_blankout]]、e279f14で撤回済み）。本設計はGUIスタイルに触れないので抵触しないが、実装時に「チラつき対策」として提案されたら即却下。
2. **フッターロゴのアンカー**（1631-1644行）: `footerY := tY + tH`はTab3下端の1点アンカー。Tab3高さ・リスト高さ・コントロール追加をしないこと。ボタン行案を却下した主因。
3. **`LauncherLVCustomDraw`の不変条件**（372-374行）: 描画状態を書き換えるAPIを呼ばない。ピン留めの視覚表現は行頭「📌」のみで、カスタムドローには触れない。
4. **`CheckLauncherFocus`タイマー**: メニュー/ダイアログ表示前に停止、後に再開。MsgBoxを出す処理は必ず先に`CloseLauncher()`。
5. **`-Redraw`〜`+Redraw`区間へのタイマー割り込み**（3058-3061行）: `FillLauncher*`改変時は`Critical("On")`区間と`RedrawWindow`呼び出しを崩さない。
6. **idxクロージャのずれ**: メニュー表示中も監視が生きて`InsertAt(1)`が走る。新規・既存とも要素参照`v`を束縛する規約に統一（C-1）。
7. **絞り込み中の行番号**: 必ず`ResolveHistRow`/`ResolveSnipRow`を経由。
8. **`+0x40`（LVS_SHAREIMAGELISTS）**（1592-1593行）: 履歴ListView再生成に関わる変更では維持必須。本設計では触れない。
9. **ストア書き直しのfail-closed**: 一時ファイル+`FileMove`差し替え。失敗時は削除リストを保持し次回再試行。全書き直し方式は`ClipHistLoadMax`打ち切り分のデータロスを招くため禁止。
10. **`SnipMgrTab.Value`代入はChangeイベント非発火**（AHK v2仕様）。C-5では`SnipMgrHistRefresh()`の明示呼び出しが必須。
11. **Windows注意**: 実装検証スクリプトに日本語コメントを書かない（Shift-JIS誤読地雷）。
