# 設計書: クリップボード履歴の永続ストア（再起動を跨いで「ずっと遡れる」履歴タブ）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, **実測2356行/v1.16.0**)を実地調査した上で設計
> / 素材収集=会議ハーネス(司令塔による取捨選択済み) / 裏取り=司令塔Claude
> 日付: 2026-07-17
> 性格: 非永続原則の3度目の転換。ただし**検疫(quarantine-then-commit)は完全維持**し、
> 既定OFF・明示オプトインの構造も維持したまま、「履歴タブがPC再起動後も遡れる」を実現する。
> 前提: `_docs/CLIBOR-PARITY-JUDGMENT.md` G節(4テスト)と
> `_docs/CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md`(検疫方式)の正統な後継。

対象: `C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link\dist\soushin-suggest.ahk`

## 裏取りメモ（実コード調査で判明した、依頼概要との差分）

1. **日次アーカイブの実体は `.txt` ではなく CSV**。`CommitPendingArchive()`(実測1824-1847行)は
   `clip-archive\history\history-YYYY-MM-DD.csv`(UTF-8 BOM・ヘッダ`time,text`・`CsvField`エスケープ)へ追記している。
   旧設計書(`CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md` C-2節)の`text-YYYY-MM-DD.txt`は実装時にCSVへ進化済み。
   つまり**RFC4180準拠の`ParseCsv()`(428行)・`CsvField()`(550行)という読み書き両対応の資産が既にある**。
   本設計はこの資産を新ストアの形式にそのまま流用する(JSON/SQLiteを新設しない最大の根拠)。
2. **設定の正本は settings.ini(プログラム所有・原子リネーム書き)に移行済み**(1569-1722行、
   `_docs/SETTINGS-UNIFICATION-DESIGN.md`)。旧設計書の`SaveIniKey`/sites.ini書き込みは削除済み。
   新トグルは`SettingDefs`(1595-1603行)への1エントリ追加で永続化まで配線される。
3. 検疫は設計書どおり実装済み: `QueueTextArchive`(1818-1822行)→`CommitPendingArchive`(1824-1847行、
   窓=`ClipAutoClearSec*1000+2000`ms)、自動クリア連動`MaybeDropAutoCleared`(2032-2047行)、
   終了時fail-closed破棄`DiscardPendingArchiveOnExit`(1950-1953行)。
4. 末尾2356行に `ShowSnippetManager()  ; TEMP-VERIFY: remove before commit` が残っている(実装時に削除)。

## 判断の要約（先に結論）

1. **方式: 新設の単一CSVストア `clip-archive\history-store.csv` を新設する**(プログラム所有・追記式)。
   既存の日次CSVログを起動時読み込みに転用する案は却下(F-3節)。日次ログは今後も「人間がexplorerで読む記録」のまま。
2. **検疫は完全維持し、ストアへの書き込みも検疫の下流に置く**。ディスクへの書き込み地点は今後も
   `CommitPendingArchive()`の1箇所だけ。自動クリアされたテキストは履歴・日次ログ・新ストアの
   **3つすべてに一度も書かれずに消える**。会議メンバーの「検疫廃止」提案は司令塔決定どおり不採用。
3. **起動時ロードは「遅延起動＋分割パース」**。起動シーケンスをブロックせず、タイマーで少しずつCSVを
   パースして`ClipHistory`の**末尾**に合流させる(新しいコピーは先頭に積まれるので衝突しない)。
4. **既定OFF・オプトイン維持＋アップデート初回の1回きり選択ダイアログ**で採用率を確保する。
   既定値は変えない(非永続テスト(b)を守る)が、「ずっと残す」への入口を1クリックにする。
5. **メモリロード上限 `history.loadmax` 既定10000件**。Clibor自身の上限(既定1000・最大10000)と同格であり、
   「Cliborのようにずっと遡れる」の実用要件を満たす。999999件のセッション内上限はそのまま。
6. **MVPは テキストのみ永続**。画像はセッション内のみ(既存の`ClipImageMax=5`)＋既存のPNGフォルダ保存が
   ディスク側の受け皿。画像のストア統合はPhase 2(E節)。

---

## A. 理想の体験フロー

1. **アップデート後の初回起動**: 1回だけダイアログが出る——「履歴を再起動後も残せるようになりました。
   Cliborのように過去の履歴をずっと遡れます(パスワード自動クリア連動の検疫付き・ファイルは
   clip-archive フォルダ内)。有効にしますか？(あとから設定でいつでも変更できます)」。
   Yesなら`history.persist=on`がsettings.iniに書かれ、その瞬間から有効。Noなら従来どおり完全非永続。
2. **ONの間に起きること**: コピーのたび、テキストは従来どおり即メモリ履歴に入り、45秒+2秒の検疫を
   通過したものだけが`clip-archive\history-store.csv`に1行追記される。KeePass等が45秒以内にクリップボードを
   クリアすれば、履歴からもストア行きからも消え、**ディスクには1バイトも書かれない**(従来の安全機構がそのまま効く)。
3. **PC再起動・アプリ再起動**: 起動して数秒のうちに、前回までの履歴(新しい方から最大10000件)が
   履歴タブ・ランチャーに静かに戻ってくる。コピー日時(曜日付き)も当時のまま。起動直後にコピーした
   新しい項目は常にリストの先頭にあり、復元された古い項目はその下に続く。
4. **遡る**: ランチャー/履歴タブの検索ボックスはメモリ上の全件(最大10000件)を対象に絞り込める。
   リスト表示自体は先頭500件(ランチャー)/2000件(履歴タブ)に抑え、UIは常に軽い。
   それより古いものは検索で引くか、日次CSVログ(オプトイン時)をexplorerで開いて読む。
5. **消す**: 「この履歴を削除」はストアからも消える(再起動で蘇らない)。「履歴を全削除」は
   ストアファイルごと削除する。設定でOFFに戻すときは「保存済みファイルも削除しますか？」を聞く。
6. **OFFのままのユーザー**: 何も変わらない。履歴はメモリのみ・終了で消える。アプリ内の注記も
   「保存されません」のまま真であり続ける。

## B. 統合アーキテクチャ

### 責務の三層分離（今回の核心）

| ファイル | 所有者 | 役割 | 書き込み経路 |
|---|---|---|---|
| `clip-archive\history-store.csv`(新設) | **プログラム** | 履歴タブ復元用ストア。起動時に読む唯一のファイル | `CommitPendingArchive`(追記) / 全削除・コンパクション(原子リネーム) |
| `clip-archive\history\history-YYYY-MM-DD.csv`(既存) | 人間 | explorerで読む日次ログ。**起動時には読まない(現状維持)** | `CommitPendingArchive`(追記のみ) |
| `settings.ini`(既存) | プログラム | `history.persist` / `history.loadmax` の永続化 | 既存の`FlushSettings`原子リネーム |

日次ログと新ストアは**同じ検疫コミット地点から分岐する2つの下流**。捕捉経路は1本も増えない
(`SelfClipTick`・ユーザー操作限定フィルタ・`ClipHasIgnoreFormat`・`ClipSourceExcluded`・除外exeを全て無条件継承)。

### 新設グローバル・設定キー

| 名前 | 役割 | 既定値 |
|---|---|---|
| `ClipHistoryPersist` | 履歴永続化トグル | `false` |
| `ClipHistLoadMax` | 起動時ロード＆コンパクション上限 | `10000` |
| `HistStoreLoadState` | 分割パースの進行状態(0=停止) | `0` |
| `HistStoreRewritePending` | 項目削除後のストア書き直し予約 | `false` |
| settings.ini `[history] persist=on/off` | 永続化の設定(SettingDefs経由) | off |
| settings.ini `[history] loadmax=<n>` | ロード上限(UIなし・手編集用) | 10000 |
| settings.ini `[state] histpersistprompted=0/1` | 初回案内ダイアログ表示済みフラグ | 0 |

### 新設関数

| 関数 | 役割 |
|---|---|
| `HistoryStorePath()` | `ArchiveBaseDir() . "\history-store.csv"`(archivedir上書きを自動継承) |
| `AppendHistoryStore(timeStr, text)` | ストアへ1行追記(BOM+ヘッダは新規時のみ)。`CommitPendingArchive`から呼ぶ |
| `StartHistoryStoreLoad()` | 起動時: ファイル読取→分割パースのタイマー起動 |
| `HistoryStoreLoadChunk()` | `ParseCsv`と同じ状態機械を約20万字/回ずつ進める(UIフリーズ回避) |
| `FinishHistoryStoreLoad(rows)` | 重複除去(新しい方優先)→`loadmax`件に切詰→`ClipHistory`末尾へ合流→必要ならコンパクション |
| `CompactHistoryStore()` | メモリ内容から全文再生成→tmp→`MoveFileExW`原子リネーム(`FlushSettings`と同型) |
| `RequestHistoryStoreRewrite()` | 項目単位削除のデバウンス(-500ms)書き直し予約 |
| `ApplyHistoryPersistSetting(v)` | SettingDefsのapply先(名前付き関数・fat arrow禁止の掟に従う) |
| `ToggleHistoryPersist(chk)` | 設定ウィンドウのチェックボックス処理(ON時警告/OFF時ファイル削除確認) |
| `MaybePromptHistoryPersist()` | アップデート初回の1回きり選択ダイアログ |

## C. 具体機構

### C-1. ストア形式（既存CSV資産の流用）

- 1ファイル・UTF-8 BOM・ヘッダ `time,type,text`・`CsvField`エスケープ(改行含む本文もRFC4180で安全)。
- `time`は**`NowWithWeekday()`の完全文字列**(例 `2026/07/17(金) 14:30:12`)をそのまま格納する。
  日次ログの`HH:mm:ss`と違い、復元後の表示・検索が捕捉時と完全に同一になる(再導出しない)。
- `type`は当面`text`固定。Phase 2で`image`行(PNGパス参照)を追加できる前方互換の席。
- ファイル内は**古→新の追記順**。ロード時に末尾から`loadmax`件を採用する。

### C-2. 書き込み: 検疫コミットの1箇所から分岐

`PushClipHistory()`(313-328行)の325行の条件を拡張し、**どちらかのトグルがONなら検疫キューへ**:

```autohotkey
    ; テキストは検疫キューへ。自動クリアで消えれば一度もディスクに書かれない(検疫の核心・変更禁止)
    if (ClipArchiveText || ClipHistoryPersist)
        QueueTextArchive(text)
```

`CommitPendingArchive()`(1824-1847行)の検疫通過ブロック内を「日次ログ(ClipArchiveText時)＋
ストア(ClipHistoryPersist時)」の2書き込みに拡張する。**通過判定・窓幅・タイマー制御は一切変えない**:

```autohotkey
        if (A_TickCount - p.tick >= windowMs) {
            if ClipArchiveText {
                ; ...既存の日次CSV追記(1831-1840行)そのまま...
            }
            if ClipHistoryPersist
                AppendHistoryStore(p.HasOwnProp("time") ? p.time : NowWithWeekday(), p.text)
            PendingArchive.RemoveAt(i)
        }
```

捕捉時刻を保持するため`QueueTextArchive`(1818-1822行)のキュー要素に`time: NowWithWeekday()`を足す
(`PushClipHistory`が履歴要素に入れたのと同じ値を渡すのがより正確。統合ポイント表D節参照)。

```autohotkey
AppendHistoryStore(timeStr, text) {
    path := HistoryStorePath()
    if (path = "")
        return
    isNew := !FileExist(path)
    try {
        out := isNew ? Chr(0xFEFF) . "time,type,text`r`n" : ""
        out .= CsvField(timeStr) . ",text," . CsvField(text) . "`r`n"
        FileAppend(out, path, "UTF-8")
    }
}
```

### C-3. 起動時ロード: 遅延起動＋分割パース（UIフリーズ回避）

AutoHotkey v2はシングルスレッドであり、`ParseCsv`は1文字ずつ回す状態機械のため、数MBの一括パースは
数秒のブロックになりうる(会議の指摘のうち妥当と採択された論点1)。対策は2段:

1. **遅延起動**: 起動シーケンス(2312-2330行)では読み込みを開始しない。`OnClipboardChange`登録・
   トレイ構築が終わった後に`SetTimer(StartHistoryStoreLoad, -50)`で予約する。ホットキーと監視は
   起動直後から生きており、ロードは裏で進む。
2. **分割パース**: `ParseCsv`のループ変数(位置i・row・field・inQuotes・rows)を状態オブジェクトに持ち、
   1タイマーtickあたり約20万字だけ進めて返す。3MBのストアでも1tick≦数十msに収まり、
   tick間でホットキー・クリップボードイベントが普通に処理される。

```autohotkey
StartHistoryStoreLoad() {
    global ClipHistoryPersist, HistStoreLoadState
    if !ClipHistoryPersist
        return
    path := HistoryStorePath()
    if (path = "" || !FileExist(path))
        return
    txt := ""
    try txt := RegExReplace(FileRead(path, "UTF-8"), "^\x{FEFF}")
    if (txt = "")
        return
    HistStoreLoadState := {text: txt, i: 1, len: StrLen(txt), row: [], field: "", inQ: false, rows: []}
    SetTimer(HistoryStoreLoadChunk, 10)
}

HistoryStoreLoadChunk() {
    global HistStoreLoadState
    st := HistStoreLoadState
    if !IsObject(st) {
        SetTimer(HistoryStoreLoadChunk, 0)
        return
    }
    budget := 200000                       ; 1tickあたりの処理文字数(実測で調整可)
    ; ...ParseCsv(428-459行)と同一の分岐を st.i から budget 文字だけ進める...
    if (st.i > st.len) {
        SetTimer(HistoryStoreLoadChunk, 0)
        HistStoreLoadState := 0
        FinishHistoryStoreLoad(st.rows)
    }
}
```

**合流(`FinishHistoryStoreLoad`)の規則**——ここが順序・重複の正しさの全て:

1. ヘッダ行と`type!="text"`行を捨てる。
2. **末尾(新)から先頭(古)へ**走査し、`seen`Map(キー=本文)で重複除去(同文の再コピーは最新だけ残る)。
3. 現在の`ClipHistory`に既にある本文(起動後セッション中に既にコピーされたもの)もスキップ。
4. `ClipHistLoadMax`件で打ち切り。
5. 集めた「新→古」順の配列を、そのまま`ClipHistory.Push(...)`で**末尾に追加**していく
   (`ClipHistory`は常に新しい順・`InsertAt(1)`で先頭積みという既存不変条件(850行コメント)を保つ)。
6. `RefreshLauncherHistory()`(2218-2225行)を呼び、開いたままのランチャーにも反映。
7. パース総行数が`loadmax + 2000`を超えていたら`CompactHistoryStore()`を予約(-1000ms)。

### C-4. 削除の同期（再起動で蘇らせない）

- **全削除** `DeleteHistoryAll()`(2200-2206行): 既存処理に加えて`try FileDelete(HistoryStorePath())`。
  日次ログは消さない(人間所有・現状維持)。ロード進行中なら`HistStoreLoadState := 0`で中断も行う。
- **項目削除** `DeleteHistoryAt(idx)`(2193-2198行): 既存処理に加えて
  (a) `PendingArchive`から同一本文を除去(**既存の取りこぼし**: 現状は全削除しか検疫キューを掃除しておらず、
  削除済み項目が47秒後に日次ログへ書かれる。ストア導入を機にここで塞ぐ)、
  (b) `RequestHistoryStoreRewrite()`でストア書き直しを予約。
- **書き直し** `CompactHistoryStore()`: `ClipHistory`のテキスト項目を古→新順で全文組み立て→
  `.tmp`書き→`MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH)`原子リネーム(`FlushSettings`1643-1661行と同型)。
  起動時コンパクション完了後は「ストア内容⊆メモリ内容」が常に成り立つため、メモリからの再生成で
  取りこぼしが構造的に起きない。**ロード完了前は書き直し禁止**(未ロードの古い履歴を消してしまうため、
  `HistStoreLoadState`が生きている間は`HistStoreRewritePending := true`で保留し、`FinishHistoryStoreLoad`後に実行)。

### C-5. 自動クリアとの関係（検疫維持の証明）

`MaybeDropAutoCleared()`(2032-2047行)は**変更不要**。理由:
自動クリアの検知窓は`ClipAutoClearSec*1000`ms以内(2034行のガード)、ストア書き込みは
`ClipAutoClearSec*1000+2000`ms以降(1826行)。つまり**自動クリアが起きうる時間帯にストアに行が存在する
ことは構造的にない**。クリア検知時は履歴と`PendingArchive`(2043-2045行)から消えるだけで足りる。
+2秒マージンも旧設計(G-2節)のまま。コメントに「ストアも同じ検疫の下流なので追加処理不要」の1行を足す。

### C-6. 表示の上限（メモリ10000件でもUIが固まらない）

- `FillLauncherHistoryLV()`(2263-2279行): 表示行が500に達したらbreak。検索(`query`)は全件走査のまま
  (InStrの1万件走査は数十ms・体感なし)。842-843行の「最大30件なので総入れ替えでよい」という**陳腐化コメントを更新**。
- `SnipMgrHistRefresh()`(844-861行): 表示2000件で打ち切り、カウント表記を
  「表示2000件 / 全N件(検索は全件対象)」へ。
- ランチャーの`rows`計算(1083行)は`Min(...,10)`で既に安全・変更不要。

### C-7. 設定UI・初回案内

- `SettingDefsInit()`(1595-1603行)に3キー追加:
  `"history.persist" {section:"history", default:"off", apply:ApplyHistoryPersistSetting}`、
  `"history.loadmax" {section:"history", default:"10000", apply:ApplyHistLoadMaxSetting}`、
  `"state.histpersistprompted" {section:"state", default:"0", apply:空関数}`。
  既存の`FlushSettings`/`LoadSettingsIni`がそのまま永続化・復元を面倒みる(新規書き込み機構ゼロ)。
- 設定ウィンドウ(1857-1898行)に「履歴」GroupBoxを追加:
  チェックボックス「履歴を再起動後も残す(Clibor方式・検疫付き)」＋灰色注記
  「保存先: clip-archive\history-store.csv ／ パスワード自動クリアで消えたものは保存されません」。
  ON時は`ApplyArchiveToggle`(1928-1946行)と同型の警告ダイアログ(OneDrive同期の1行を含める)。
  OFF時は「保存済みのファイルも削除しますか？」(Yes=`FileDelete`/No=残す)。ウィンドウ高を約80px拡張。
- 初回案内`MaybePromptHistoryPersist()`: 起動シーケンス末尾(2349-2355行の初回起動プロンプトと同じ流儀)で
  `state.histpersistprompted`未設定時に1回だけ表示。Yes=`SetSetting("history.persist","on")`。
  **どちらを選んでもフラグを立て、二度と出さない。**

### C-8. 上限999999件とディスク使用量

| 項目 | 値 | 根拠 |
|---|---|---|
| セッション内メモリ上限 | 999999(現状維持) | 30行コメントの方針のまま。sites.ini `max=`で上書き可(143-144行) |
| 再起動を跨ぐ件数 | `loadmax`=10000(既定) | Cliborの最大値と同格。10000件で「ずっと遡れる」体感を満たす |
| ストアの平常サイズ | 1行平均~300Bとして約3MB | コンパクションで`loadmax`件に定期的に切詰められる |
| 理論最悪(1件100KB×1万) | 約1GB | `ClipMaxLen=100000`(47行)が捕捉時に効くため1件100KB超は存在しない。コンパクション時に**総量50MB超なら古い方から追加で間引く**セーフティを入れる |
| メモリ増 | 10000件×~600B(UTF-16)≒6MB | 常駐アプリとして許容範囲 |

### C-9. GDI+画像パイプラインとの統合（Phase 2・MVP外）

MVPでは画像は永続化しない(理由はF-9節)。Phase 2の席だけ用意する:
`PushClipImage`(1331-1352行)の既存PNG保存(1349-1350行)を`ClipHistoryPersist`時にも発火させ、
ストアに`time,image,<PNG相対パス>`行を書く。起動時は`GdipCreateBitmapFromFile`→`GdipCreateHBITMAPFromBitmap`
→`GetDIBits`でCF_DIB Bufferへ逆変換して復元(既存`SaveDibAsPng`(1779-1814行)の逆走。
GDI+初期化・解放パターンは同関数の`static gdipToken`方式を流用)。サムネイルは既存`HistThumbIndex`(2002-2008行)が
復元後のdibからそのまま作れる。ストア形式(C-1)の`type`列はこのための前方互換。

## D. 既存機能との関係（統合ポイント一覧・実測行番号付き）

| 行 | 既存コード | 変更 |
|---|---|---|
| 30-35 | 履歴グローバルと非永続コメント | `ClipHistoryPersist`/`ClipHistLoadMax`追加。コメントを「既定は非永続。history.persist(検疫付き)とarchive系(検疫付き)の2系統のオプトイン例外あり」へ更新 |
| 313-328 | `PushClipHistory()` | 325行の条件を `if (ClipArchiveText \|\| ClipHistoryPersist)` へ。`QueueTextArchive(text)`→`QueueTextArchive(text, ClipHistory[1].time)`で捕捉時刻を渡す |
| 331-334 | `NowWithWeekday()` | 変更なし(ストアのtime列の正本) |
| 762-783 | 履歴タブUI・783行の注記 | 注記を動的化: OFF時「…保存されません」/ ON時「…clip-archiveに保存中(設定で変更可)」。762行の「非永続のClipHistoryを…」コメント更新 |
| 842-861 | `SnipMgrHistRefresh()` | 表示2000件打ち切り(C-6)。842-843行の「最大30件」陳腐化コメント更新 |
| 1216-1242 | `ClipChanged()` | **変更なし**(捕捉経路・フィルタは不可侵) |
| 1244-1266 | `CaptureClip()` | **変更なし** |
| 1331-1352 | `PushClipImage()` | MVPでは**変更なし**(Phase 2でC-9のフック) |
| 1595-1603 | `SettingDefsInit()` | `history.persist`/`history.loadmax`/`state.histpersistprompted`の3キー追加(C-7) |
| 1724-1736 | `ArchiveBaseDir()`/`ArchiveSubDir()` | 変更なし。`HistoryStorePath()`が`ArchiveBaseDir()`を参照(archivedir上書きを自動継承) |
| 1818-1822 | `QueueTextArchive()` | 第2引数`timeStr`を受け、キュー要素に`time`を追加 |
| 1824-1847 | `CommitPendingArchive()` | 検疫通過ブロック内で日次ログ(ClipArchiveText時)＋ストア(ClipHistoryPersist時)の2分岐(C-2)。**窓幅・判定・タイマー制御は不変** |
| 1857-1898 | `ShowSettingsWindow()` | 「履歴」GroupBox＋チェックボックス追加(C-7)。ウィンドウ高拡張 |
| 1950-1953 | `DiscardPendingArchiveOnExit()` | **変更なし**(検疫中項目はストアにも書かずに死ぬ=fail-closed継承) |
| 2032-2047 | `MaybeDropAutoCleared()` | **変更なし**(C-5の証明どおり)。コメント1行追記のみ |
| 2193-2198 | `DeleteHistoryAt()` | `PendingArchive`同文除去(既存の取りこぼし修正)＋`RequestHistoryStoreRewrite()`(C-4) |
| 2200-2206 | `DeleteHistoryAll()` | ストアファイル削除＋ロード中断を追加(C-4) |
| 2218-2225 | `RefreshLauncherHistory()` | 変更なし(ロード完了時にも呼ばれるだけ) |
| 2263-2279 | `FillLauncherHistoryLV()` | 表示500件打ち切り(C-6) |
| 2312-2330 | 起動シーケンス | `LoadSettingsIni`後に`SetTimer(StartHistoryStoreLoad, -50)`。末尾に`MaybePromptHistoryPersist()`。**2356行のTEMP-VERIFY行を削除** |

### 安全機構の継承マトリクス

| 既存機構 | ストアへの効き方 |
|---|---|
| 検疫(45秒+2秒) | ストア書き込みも検疫通過後のみ。**完全継承** |
| `MaybeDropAutoCleared` | クリア検知→履歴＋検疫キューから除去→ストアには元々未着。**完全継承** |
| `ClipHasIgnoreFormat`/`ClipExcludeExes`/ユーザー操作限定フィルタ | 捕捉経路不変のため**完全継承** |
| `DiscardPendingArchiveOnExit` | 終了直前のコピーはストアにも書かれない。**完全継承** |
| 履歴削除UI | ストアにも同期(全削除=ファイル削除/項目削除=書き直し)。**強化** |

## E. MVP（2段階）

- **MVP-1(コア)**: ストア追記(C-2)＋分割ロード(C-3)＋全削除同期＋表示上限(C-6)＋設定キー/チェックボックス＋
  初回案内(C-7)＋注記の動的化＋コメント更新。約+230行。
- **MVP-2(仕上げ)**: 項目削除同期＋コンパクション＋OFF時のファイル削除確認＋総量50MBセーフティ。約+80行。
- **Phase 2(MVP外)**: 画像のストア統合(C-9)、ランチャー「さらに表示」ページング、日次ログからの過去分一括取込。

## F. 捨てた案と理由

1. **検疫の廃止・即時書き込み**(会議の多数派提案): 却下(司令塔決定)。検疫はパスワードマネージャの
   自動クリアを「ディスク書き込みの拒否権」として使う安全機構の核心。性能・実装簡潔さは対価にならない。
   本設計は検疫の下流に書き込みを増やしただけで、検疫そのものに指一本触れない。
2. **既存の日次CSVログを起動時に読み込んでストアを兼用させる**: 却下。日次ログは追記専用の人間所有ログで、
   (a)UIで削除した項目が再起動で蘇る(削除同期の受け皿がない)、(b)同文再コピーが複数行あり重複除去の正本にできない、
   (c)`archive.text`トグルと意味的に癒着する(ログは要らないが履歴は残したい人が表現できない)、
   (d)日跨ぎで複数ファイル読みになる、(e)time列が`HH:mm:ss`のみで曜日付き表示を再現できない。
   「所有権の分離」(SETTINGS-UNIFICATION-DESIGNの核)に従い、プログラム所有の別ファイルを新設する。
3. **SQLite**: AHK v2に組み込みなし。DLL同梱は「単一ファイル・非依存」の製品規格に反する。1万件のCSVで十分速い。
4. **JSON/JSONL**: AHK v2にネイティブパーサなし。自前JSONパーサ新設より、実戦投入済みの
   `ParseCsv`/`CsvField`(RFC4180・改行/カンマ/引用符対応)を流用する方が薄い。
5. **既定ON化**: 非永続テスト(b)「既定OFF・警告付きオプトイン」に正面から反する。採用率は
   初回1回きりの選択ダイアログ(1クリックでON)で確保する。看板(LP)の記述も既定値の記述として真を保てる(H節)。
6. **999999件の全量永続・全量ロード**: 1GB級ファイル・数十秒フリーズ・数百MBメモリの現実的リスク。
   Clibor自身が最大10000件である以上、「Cliborのように遡れる」の要件はloadmax=10000で満たされる。
7. **1履歴=1ファイル方式**: 起動時のディレクトリ列挙・数千ファイルのアンチウイルススキャン負荷・
   ファイル名衝突管理が重い。単一ファイル追記が最軽量。
8. **暗号化ストア**: 鍵が同一マシン同一ユーザー権限にある限りセキュリティ演劇(旧設計F-5と同判断)。
9. **画像のMVP内永続化**: 画像はDIB↔PNG往復・数MB/件のロード・サムネイル再構築と複雑さが桁違いに増える一方、
   `ClipImageMax=5`(49行)でセッション内も5件しか持たない設計であり、便益が小さい。既存のPNGフォルダ保存が
   ディスク側の受け皿として既にある。Phase 2の席(type列)だけ確保して見送る。
10. **削除のtombstone(削除レコード追記)方式**: 追記だけで削除を表現できるが、コンパクション必須になり
    状態機械が増える。この規模(≦10000件・数MB)なら「デバウンス付き全文書き直し＋原子リネーム」の方が
    単純で、`FlushSettings`という実証済みの同型がある。
11. **起動時の同期一括ロード**: シングルスレッドのAHKでは数MBのCSVパースが数秒のブロックになり、
    その間ホットキー・クリップボード監視が死ぬ。分割パース(C-3)を採用(会議の妥当論点1・2の採択)。

## G. 地雷と回避策

1. **ロード完了前のストア書き直し**: 未ロードの古い履歴をメモリに持たない状態で`CompactHistoryStore`を
   走らせると、その分が永久に消える。`HistStoreLoadState`生存中は書き直しを保留フラグに退避し、
   `FinishHistoryStoreLoad`後に実行する(C-4)。**この順序制約が本設計最大の地雷。**
2. **ロード中の新規コピーとの合流順序**: 新規は`InsertAt(1)`で先頭、復元は`Push`で末尾。この規約を
   崩すと「新しい順」不変条件(850行・2269行のコメントが依存)が壊れ、表示・数字キー選択がズレる。
3. **重複除去の方向**: ストアは古→新の追記順。**末尾から**走査して`seen`Mapで先勝ちにしないと
   「古い方が残る」逆転が起きる。セッション中に既にコピー済みの本文もスキップ(3重登録防止)。
4. **OneDrive同期**: `A_ScriptDir`はOneDrive配下のため、ストア(=コピー履歴全文)が全同期端末とクラウドに
   複製される。ON時警告ダイアログに1行明記＋`archivedir=`でローカルへ逃がせる(HistoryStorePathが
   ArchiveBaseDirを参照するため自動で効く)。旧設計G-1と同じ判断・同じ逃げ道。
5. **`#SingleInstance Force`の世代交代**: 新旧プロセスが一瞬併存し、旧側のOnExit(検疫破棄・設定Flush)と
   新側の起動ロードが重なりうる。ストアは「追記」と「原子リネーム」しか行わないため破損はしないが、
   旧プロセスが直前に追記した行を新プロセスのロードが取り こぼす可能性はある(次回起動で戻る・実害軽微と受容)。
6. **CSV途中破損(強制終了・電源断)**: 追記中断で最終行が欠けても、`ParseCsv`は引用符が閉じないまま
   EOFに達した場合その行だけが不完全になる。`FinishHistoryStoreLoad`で「列数<3の行は捨てる」を入れて
   1行欠損に留める(fail-closed)。原子リネーム側(コンパクション)は構造的に破損しない。
7. **検疫キュー要素の後方互換**: `QueueTextArchive`に`time`を足す際、`p.HasOwnProp("time")`ガードを
   入れる(C-2のコード)。入れ忘れると旧要素が残った状態でのホットリロード時に例外で検疫が止まる。
8. **fat arrowでのグローバル代入**(実機確認済みの既知地雷・1577-1578行コメント): `ApplyHistoryPersistSetting`等の
   apply先は必ず名前付き関数+global宣言で書く。`(v)=>(ClipHistoryPersist:=v)`は握りつぶされる。
9. **表示上限と数字キー/フィルタマップ**: 表示打ち切り後も`LauncherHistFilterMap`は表示行ぶんしか積まれない
   ため、`ResolveHistRow`(1156-1161行)の「マップ空=1:1素通し」規約と矛盾しない形にする——打ち切りが発生した
   場合は必ずマップを積む(空のままにしない)こと。空のままだと表示501行目以降が存在しないのに1:1変換が通ってしまう。
   ※現実装は打ち切りが無いので顕在化していない新規地雷。
10. **注記・コメントの陳腐化**: 783行「保存されません」、842-843行「最大30件」、30-35行「メモリのみ」、
    762行「非永続の…」。実挙動と表示が食い違ったまま出荷すると、H節の看板同期テストに落ちる。
    実装コミットに必ず含める(旧設計G-9と同じ流儀)。
11. **`history.loadmax`の異常値**: 手編集で`0`や負値・巨大値が来る。`Max(100, Min(Integer(val), 100000))`で
    クランプしてから使う(fail-closed)。
12. **2356行のTEMP-VERIFY行**: `ShowSnippetManager()` の検証用呼び出しが残っている。本実装のコミット前に削除。

## H. 非永続原則との整合・LP文言・「第5のテスト」

### 4テストへの通し方（CLIBOR-PARITY-JUDGMENT.md G節）

- **許可リストテスト: 合格(無変更)**。捕捉経路も送信・自動操作の対象も1つも増えない。
- **非永続テスト(改定版(b)): 合格**。既定OFF・ON時警告・自動クリア連動の検疫、の3点を全て備える。
  初回案内ダイアログは「既定を変えずにオプトインの道を1クリックにする」ものであり、
  Noを選んだ(または無視した)ユーザーにとって「保存されません」は引き続き真。
- **OS重複テスト: 合格**。Win+Vの履歴は再起動非保持が既定であり件数上限も25件。Clibor併用案内で
  代替できた旧状況と違い、今回は「なぞってコピー・許可アプリ連動の履歴そのものを遡りたい」という
  本製品固有データへの要望であり、外部ツールでは代替不能。
- **永続化併設テスト(第4): 合格**。ストア書き込みは既存の検疫の下流にのみ存在し、
  自動クリア=ディスク書き込み拒否権の構造を1ミリも動かしていない。

### 第5のテスト(新設提案): 看板同期テスト

> **永続化の状態・既定値・保存先に触れる変更は、(1)アプリ内の注記・警告文 (2)LP/READMEの安全性の記述
> (3)設定UIの説明文 の3点を同一コミットで更新し、「どのトグル状態のユーザーにとっても、
> 目に見える記述が現在の実挙動として真である」ことを出荷前に検査する。1点でも偽になる記述が
> 残るなら、機能が完成していても出荷しない。**

由来: 第4のテストは「安全機構の併設」という**実装側の対価**を要求した。今回の変更で新たに顕在化したのは
**説明責任側の対価**である。「履歴は保存されません」という看板は、オプトイン例外が2系統(archive/persist)に
増えた今、無条件の記述としては偽になりうる。旧判定の洞察「エクスポートを付ければ自動化へ一直線」が
的中し続けている以上、この系統の要望は今後も来る(クラウド同期・端末間共有等)。そのたびに
機構(第4)と看板(第5)の両方の対価を払わせるのが、なし崩しを防ぐ最後の柵である。

### LP・ユーザー案内の文言方針

- 旧看板「履歴はメモリ内のみ・アプリを閉じれば消える」を、**「既定」を主語にした選択の看板**へ差し替える:
  > 「履歴は**既定では**このPCのメモリ内のみ。アプリを閉じれば消え、ディスクに痕跡は残りません。
  > 残したい方は設定の**『履歴をずっと残す(Clibor方式)』**を1クリック——再起動後も過去の履歴を
  > ずっと遡れます。どちらを選んでも、パスワードマネージャーの自動クリアと連動した**検疫**が働き、
  > 自動クリアされたテキストはディスクに一度も書かれません。」
- 「消える安全」と「残る便利」を対立させず、**検疫を両者共通の土台**として前面に出すのが訴求の軸。
  「残すのが不安な機能」ではなく「残しても検疫が守る機能」として語る。
- アップデート告知(初回ダイアログ・リリースノート)には必ず3点を含める:
  (a)既定は変わらない(何もしなければ今まで通り)、(b)ONにすると何がどこに残るか(clip-archive内・
  OneDrive同期の注意)、(c)検疫により自動クリア分は残らないこと。
- LP更新の実務は`_docs/LP-NEW-FEATURES-REVISION-DESIGN.md`の流儀に従い、別タスクとして切る(下記ハンドオフ)。

## 行数見積もり

| 部品 | 行数 |
|---|---|
| グローバル・SettingDefs3キー・apply関数 | +25 |
| `HistoryStorePath`/`AppendHistoryStore` | +20 |
| `StartHistoryStoreLoad`/`HistoryStoreLoadChunk`/`FinishHistoryStoreLoad` | +85 |
| `CompactHistoryStore`/`RequestHistoryStoreRewrite` | +45 |
| `CommitPendingArchive`分岐・`QueueTextArchive`のtime | +12 |
| 削除2関数へのフック | +12 |
| 表示上限(LV2箇所)＋フィルタマップ規約対応 | +18 |
| 設定UI(GroupBox+トグル+OFF時確認) | +40 |
| 初回案内ダイアログ | +15 |
| 注記動的化・コメント更新・TEMP行削除 | +12 |
| **合計** | **約+284行 → 2356行から約2640行** |

---

## 次のチャットへの引き継ぎ用ハンドオフ

**ゴール**: 履歴タブ・ランチャーの履歴が、PC再起動/アプリ再起動を跨いで遡れるようにする(Clibor方式)。
**絶対制約**: 検疫(`QueueTextArchive`→`CommitPendingArchive`、窓=`ClipAutoClearSec*1000+2000`ms)に触れない。
ディスク書き込み地点は`CommitPendingArchive`内の1箇所のまま。捕捉経路・フィルタ(1216-1266行)は不可侵。

**実装順(MVP-1)**:
1. 2356行の`ShowSnippetManager()  ; TEMP-VERIFY`を削除。
2. グローバル追加(51-52行付近): `ClipHistoryPersist:=false`, `ClipHistLoadMax:=10000`,
   `HistStoreLoadState:=0`, `HistStoreRewritePending:=false`。
3. `SettingDefsInit()`(1595-1603行)に`history.persist`/`history.loadmax`/`state.histpersistprompted`を追加。
   apply先は**名前付き関数**(fat arrow禁止・1577行の地雷コメント参照)。
4. `HistoryStorePath()`(=`ArchiveBaseDir() . "\history-store.csv"`)と`AppendHistoryStore()`(C-2)を
   1747行付近(ArchiveDir系の近く)に追加。
5. `PushClipHistory`325行: `if (ClipArchiveText || ClipHistoryPersist)` + `QueueTextArchive(text, ClipHistory[1].time)`。
   `QueueTextArchive`(1818行)に`timeStr:=""`引数とキュー要素`time`を追加。
6. `CommitPendingArchive`(1824-1847行)の検疫通過ブロックで、日次ログ書きを`if ClipArchiveText`で包み、
   `if ClipHistoryPersist → AppendHistoryStore(...)`を並べる。判定・窓・タイマーは変えない。
7. ロード3関数(C-3)を追加。`ParseCsv`(428-459行)の状態機械を分割実行に写経。合流規則は
   C-3の7項目とG-2/G-3の順序地雷を厳守。
8. 起動シーケンス: 2318行(`MigrateSettingsIfNeeded`)の後に`SetTimer(StartHistoryStoreLoad, -50)`、
   末尾に`MaybePromptHistoryPersist()`。
9. `DeleteHistoryAll`(2200-2206行)にストアファイル削除＋ロード中断。
10. 表示上限: `FillLauncherHistoryLV`(2263-2279行)=500件、`SnipMgrHistRefresh`(844-861行)=2000件。
    **打ち切り発生時はフィルタマップを必ず積む**(G-9)。
11. 設定ウィンドウ(1857-1898行)に「履歴」トグル、783行の注記を動的化、
    30-35/762/842-843行のコメント更新。
12. MVP-2: `DeleteHistoryAt`(2193-2198行)の検疫キュー掃除＋`RequestHistoryStoreRewrite`、
    `CompactHistoryStore`(原子リネームは`FlushSettings`1643-1661行を写経)、OFF時のファイル削除確認。

**検証(reality-checkerに委任)**:
- コピー→47秒待ち→`clip-archive\history-store.csv`に行が増える。
- コピー→45秒以内にクリップボードをクリア(KeePass模擬)→ストア・日次ログとも**書かれない**。
- 再起動→履歴タブに前回の履歴が時刻(曜日付き)ごと戻る。順序=新しい順。再起動直後のコピーが先頭。
- 同文を再コピー→再起動→1件だけ(重複除去)。
- 全削除→再起動→0件。persist=off(既定)→再起動→0件・ストアファイル未作成。
- 1万行のダミーストアで起動→起動直後からホットキーが効く(フリーズなし)→数秒で履歴が現れる。

**別タスクとして切るもの**: LPの安全性コピー差し替え(H節の文言方針・`LP-NEW-FEATURES-REVISION`の流儀)、
Phase 2(画像永続化・ページング・日次ログ過去分取込)。
