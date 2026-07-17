# 設計書: CliborエクスポートCSV取り込み機能（soushin-suggest.ahk v1.9.0 → v1.10）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 1615行/v1.9.0)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・4/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-15
> 前提: ユーザー提供の実際のCliborエクスポートファイルをバイト単位で解析し、形式を確定させた上で設計

対象: `C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link\dist\soushin-suggest.ahk`（実測1615行・AHK v2・単一ファイル）

## 裏取りメモ（司令塔による検証）

ユーザー提供の実際のCliborエクスポートCSVをPowerShellでバイト単位解析し、以下を確定させた: エンコーディングはShift-JIS(CP932)、**BOMなし**（先頭バイト`92 E8`は「登」の文字そのもの）。4列CSV、ヘッダ`定型文グループ,定型文,メモ,ホットキー`。

会議で「BOM付きの可能性」を懸念する声があったが、これは事実誤認として却下。また、実データ解析中に判明した重要な安全上の注意: 会議への問い合わせ時、当初のプロンプトに実データのサンプル値（パスワードらしき文字列）を誤って含めてしまい、外部API送信が自動ブロックされた。問いを実データなしの抽象的な形式説明に書き直し、機密データを含む一時ファイルも削除してから再送した。

## 結論の要約

| 項目 | 判定 |
|---|---|
| ラベル生成 | メモ列優先、空なら本文先頭20文字。**重複時は`(2)`(3)`...で一意化**（データ消失防止） |
| グループ情報 | **非空グループが2種類以上あるときのみ**`グループ名/`プレフィックス |
| 統合方法 | `ImportSnippets`内で分岐、変換は専用ローダー関数（完全統合でも別関数でもないハイブリッド） |
| ホットキー列 | 無視 |
| 冪等性 | 同一ファイルを再取込しても増殖しない（本文まで一致すれば真の重複としてスキップ） |
| 見積もり行数 | 約+84行（1615行→約1700行） |

---

## A. 理想の体験フロー

1. ユーザーは今まで通りの入口を使う。定型文管理ダイアログの「取り込み」ボタン（またはトレイメニュー）→既存の`FileSelect`（フィルタは既に`*.csv`を含むためUI変更ゼロ）。
2. CliborのエクスポートCSVを選ぶと、内部でヘッダ行を検知して自動的にClibor変換パスに入る。ユーザーに確認は聞かない。判別できなければ従来の`label,body`CSVパスへ静かにフォールバックする（fail-closed）。
3. ラベルは「メモ列があればメモ、なければ本文先頭20文字」で自動生成。衝突時は`(2)``(3)`…で一意化。グループが2種類以上ある場合のみ`グループ名/`プレフィックスが付く。
4. 完了時は既存のステータス行/Flashに「Clibor形式としてN件を取り込みました（同一内容M件はスキップ）」。既存の`clearFirst`（全クリアして取込）チェックボックスもそのまま効く。
5. 同じファイルをもう一度取り込んでも増殖しない（ラベル衝突時に本文が同一なら「重複」としてスキップする冪等設計）。

## B. 統合アーキテクチャ

**最終判断: `ImportSnippets`内で分岐、変換は専用関数**のハイブリッド。入口（ファイル選択・1MBガード・追記マージ・アーカイブ・結果表示）は既に`ImportSnippets`に揃っており複製する価値がない。一方エンコーディングと列マッピングは別物なので、`LoadSnippetsCsv`に押し込むとUTF-8前提のBOM除去・2列前提が壊れる。よってローダーだけ新設し、合流点は既存のまま。

新設は2関数のみ:

| 関数 | 役割 |
|---|---|
| `TryLoadCliborCsv(path, existing)` | CP932→（失敗時UTF-8）でデコードし、ヘッダ行でClibor形式か判定。非該当なら`false`を返す。該当なら列マッピング＋ラベル生成＋一意化まで済ませた`{label, value}`配列を返す |
| `CliborLabelBase(memo, body)` | ラベル素材の生成とサニタイズ |

`ImportSnippets`の変更は分岐1箇所＋`existing`マップ構築のみ。既存関数（`LoadSnippets`/`LoadSnippetsCsv`/`ParseCsv`/`CsvField`）は一切変更しない。

**重複ラベル対策**: 一意化はローダー内で完結させる。既存の`ImportSnippets`の「重複ラベルは問答無用スキップ」は変更しないため、ローダーが返す時点で既存ラベルとも内部同士とも衝突しない状態にしておく。

**グループ**: 非空グループが2種類以上あるときのみ`グループ名/`をプレフィックス。1種類（実データの「巨大な1塊」ケース）なら情報量ゼロなので付けない。設定項目にはしない。

## C. 具体機構

### C-1. Shift-JIS読み込みとヘッダ判定

```autohotkey
; CliborエクスポートCSV(4列, CP932)の判定＋変換。非該当ならfalse。
; existing: 既存ラベル→本文 のMap（clearFirst時は空Mapを渡す）
TryLoadCliborCsv(path, existing) {
    text := FileRead(path, "CP932")
    rows := ParseCsv(text)
    if !CliborHeaderOk(rows) {
        ; UTF-8で書き出された変種の救済（BOM除去してもう一度だけ）
        text := RegExReplace(FileRead(path, "UTF-8"), "^\x{FEFF}")
        rows := ParseCsv(text)
        if !CliborHeaderOk(rows)
            return false
    }
    ; ...（C-3の変換ループへ）
}

CliborHeaderOk(rows) {
    return rows.Length >= 2 && rows[1].Length >= 4
        && Trim(rows[1][1]) = "定型文グループ" && Trim(rows[1][2]) = "定型文"
        && Trim(rows[1][3]) = "メモ" && Trim(rows[1][4]) = "ホットキー"
}
```

BOMなし・CP932が実測済みの正なのでCP932を第一候補にする。誤ったコードページで読んだ場合はヘッダの日本語が化けて必ず不一致→`false`→従来パスへ落ちる。「文字化けしたまま取り込まれる」経路は存在しない。

### C-2. ラベル生成

```autohotkey
CliborLabelBase(memo, body) {
    s := Trim(memo)
    if (s = "") {
        s := Trim(StrSplit(body, "`n", "`r")[1])   ; 本文の1行目
        s := SubStr(s, 1, 20)
    }
    s := StrReplace(s, "=", " ")          ; ini区切りの破壊防止
    s := RegExReplace(s, "^[;\[]+")       ; 行頭;/[ はコメント/セクション誤認
    s := Trim(RegExReplace(s, "\s+", " "))
    return (s != "") ? s : "取込"
}
```

### C-3. グループ判定＋一意化＋冪等スキップ（変換ループ本体）

```autohotkey
    ; パス1: 非空グループの種類数を数える
    groups := Map()
    for idx, row in rows
        if (idx > 1 && row.Length >= 1 && Trim(row[1]) != "")
            groups[Trim(row[1])] := 1
    multi := groups.Count >= 2

    ; パス2: 変換
    items := [], seen := Map()            ; seen: この取込内で確定したラベル→本文
    for idx, row in rows {
        if (idx = 1 || row.Length < 2)
            continue
        body := StrReplace(row[2], "`r`n", "`n")   ; クォート内CRLF正規化
        if (body = "")
            continue
        memo := row.Length >= 3 ? row[3] : ""
        base := (multi && Trim(row[1]) != "" ? Trim(row[1]) . "/" : "")
              . CliborLabelBase(memo, body)
        label := base, n := 1
        while (existing.Has(label) || seen.Has(label)) {
            ; 同一本文なら真の重複 → スキップ（再取込の冪等性）
            if ((existing.Has(label) && existing[label] = body)
             || (seen.Has(label) && seen[label] = body)) {
                label := ""
                break
            }
            n++, label := base . " (" . n . ")"
        }
        if (label = "")
            continue
        seen[label] := body
        items.Push({label: label, value: body})
    }
    return items
```

### C-4. `ImportSnippets`への差分（分岐のみ）

```autohotkey
    if RegExMatch(f, "i)\.csv$") {
        existing := Map()
        if !clearFirst
            for s in LoadSnippets()
                existing[s.label] := s.value
        incoming := TryLoadCliborCsv(f, existing)
        if !incoming
            incoming := LoadSnippetsCsv(f)   ; 従来のlabel,body形式
    } else
        incoming := LoadSnippets(f)
```

以降の追記マージ・`ArchiveSnippetsCsv()`・結果メッセージは既存のまま流用。

## D. 既存機能との関係

- **`ParseCsv`**: そのまま使い回す。エンコーディング非依存（デコード済み文字列を受ける）という既存設計がそのまま効く。変更ゼロ。
- **`LoadSnippetsCsv`**: 変更ゼロ。Clibor判定に失敗したCSVのフォールバック先として現役続行。
- **`ImportSnippets`**: 分岐追加のみ。1MBガード・`clearFirst`・追記マージ・`ArchiveSnippetsCsv`呼び出しは全て素通しで再利用。
- **`CsvField`**: 本機能では未使用（読み取り専用のため）。
- **snippets.ini形式**: 不変。ラベルサニタイズと本文正規化で不変条件を守る。

## E. MVP

上記が既にMVP:
1. `TryLoadCliborCsv`（判定＋変換＋一意化、約55行）
2. `CliborLabelBase`（約12行）
3. `ImportSnippets`の分岐差し替え（約+9/−1行）

UI追加なし・設定項目なし・新メニューなし・確認ダイアログなし。

## F. 捨てた案と理由

| 案 | 理由 |
|---|---|
| BOM対応（会議で懸念） | 実ファイルのバイト確認でBOMなし確定。事実誤認のため不採用。UTF-8変種のBOMのみ既存流儀で除去 |
| グループを常にプレフィックス | 実データは「1グループに大半が集中」。単一グループ時は全ラベルに同じ雑音が付くだけ |
| グループ→iniセクション化 | snippets.ini形式の変更は制約違反。全読み書き経路の改修になる |
| 専用メニュー項目「Cliborから取込」 | ヘッダ自動判別で足りる。入口が増えると保守コストだけ増える |
| `ImportSnippets`と完全統合（1関数化） | エンコーディング判定＋4列マッピング＋一意化を既存関数に押し込むと`LoadSnippetsCsv`の契約が壊れる |
| ホットキー列の移植 | 会議全員一致で無視。自アプリにホットキー概念がなく、マッピング先が存在しない |
| エンコーディング自動推定 | ヘッダ一致がそのままエンコーディング検証を兼ねる。推定ロジックは過剰設計 |
| 取込プレビューGUI | 既存のimport UXに存在しない水準の作り込み |

## G. 地雷と回避策

1. **重複ラベル→データ消失（最重要）**: 既存マージはラベル衝突を無言スキップ。メモ空欄が多いClibor実データでは本文先頭由来のラベルが高頻度で衝突する。→ローダー内で`existing`＋`seen`の二重チェックで`(n)`サフィックス一意化。マージ層は無改修のまま消失ゼロ。
2. **再取込での増殖**: 一意化だけだと同じCSVを2回取り込むと全件`(2)`付きで倍増する。→衝突時に本文まで一致したら「真の重複」としてスキップ（冪等）。
3. **ラベル内の`=`/行頭`;``[`**: `LoadSnippets`は最初の`=`で分割、`;`/`[`開始行を読み飛ばす。メモや本文先頭にこれらが来ると次回起動時に読めない/化ける。→`CliborLabelBase`でサニタイズ。
4. **クォート内CRLF**: `ParseCsv`はクォート内の`\r`を保持する。そのまま書くとini行内に裸のCRが混入する。→取込時にCRLF→LF正規化。
5. **エンコーディング指定漏れ**: AHK v2の`FileRead`既定はUTF-8。`"CP932"`を明示しないと必ず化ける。化けた場合もヘッダ不一致で従来パスに落ちるため「化けたまま取り込む」事故は構造上ない（fail-closed）。
6. **`run:`で始まる本文**: 既存仕様で本文`run:`は起動コマンド扱い。Clibor由来データが偶然`run:`始まりだと貼り付けでなく起動になる。データを書き換える方が害が大きいため無加工とし、既知の残存リスクとして記録するに留める。
7. **1MBガード**: 既存のまま維持。数百件規模のClibor定型文はCP932で通常数十KB〜数百KB。撤廃・拡大は不要。
8. **機密データの取り扱い**: 本文に機密が混在しうるが、経路は既存import（ローカルファイル→snippets.ini追記）と同一で、新たな出力先・ログ・一時ファイルを一切作らない。

## 行数見積もり

| 項目 | 増分 |
|---|---|
| `TryLoadCliborCsv`（判定＋2パス変換＋一意化＋コメント） | +55 |
| `CliborHeaderOk` | +6 |
| `CliborLabelBase` | +12 |
| `ImportSnippets`分岐差し替え | +9 / −1 |
| 冒頭コメント・区切り | +3 |

**合計 +84行前後 → 1615行 → 約1700行**（±15行）。UI・設定・ini形式の変更ゼロ、既存関数の変更は`ImportSnippets`の分岐1箇所のみ。

## 追記（v1.18.2, 2026-07-17）: グループプレフィックス機能を廃止

ユーザー判断: 「Cliborでグループ1グループ2あったけど使いづらかったのでこれは入れたくない」。

Cliborの実エクスポートには実際に2グループ（グループ1=営業メッセージ大半、グループ2=開発メモ数件）が存在し、上記B節「非空グループが2種類以上あるときのみ`グループ名/`プレフィックス」の設計判断どおりにロジックは正しく動作していた（バグではなかった）。しかしユーザーはClibor本体でもこのグループ機能を使いづらいと感じていたため、soushin-suggest.linkでは今後インポートするラベルに一切`グループ名/`プレフィックスを付与しないことに変更した。

- `TryLoadCliborCsv`（`dist/soushin-suggest.ahk`）から「パス1: 非空グループの種類数を数える」ブロックと`multi`判定を削除。ラベルは常に`CliborLabelBase(memo, body)`のみで生成
- 既存の`snippets.ini`に残る`グループ1/`等のプレフィックス付きラベルはそのまま（自動移行はしない、必要ならユーザーが手動リネーム）
- 定型文管理ウィンドウのグループ列・グループ絞り込みUI（`SNIPPET-MANAGER-CLIBOR-PARITY-DESIGN.md`のC-1/C-2節）は変更なし。今後のインポートでプレフィックスが付かなくなる分、「グループなし」表示が増えるのみ
- `scripts/verify-clibor-import.ps1`のFixture Eを「複数グループでもプレフィックスが付かないこと」を検証する内容に更新済み
