# 設計書: 自己検証できる製品(計器の思想)の実装

> 設計=Fable(claude-fable-5) / 素材収集=会議ハーネス(5体召集・4/5成功) / 裏取り=司令塔Claude
> 日付: 2026-07-16 ／ council-fable 3段構えワークフローの手順2〜3の産物
> 踏襲元の正本: `web-ios-android/docs/ai-rules/04_SELF_VERIFICATION.md`（tsuioku-no-kirameki.comで確立）
> 対象: `dist/soushin-suggest.ahk`（v1.12.0時点、約1900行、AutoHotkey v2）

## 背景

実機ユーザーから「スクリーンショットを撮っても履歴に残らないことがある」「ホバーのプレビューが出ないことがある」
「履歴の状態がまだ不安定」という報告が繰り返し出ていた。過去のセッションで2つの原因（ランチャーのタブ・ListViewの
ライブ更新漏れ、ホバーツールチップの非アクティブタブ誤爆）を特定・修正済みだが、それでも「不安定」という体感が
残っていたため、今後同種の不具合をユーザーの目視往復なしにAIが診断できるよう、計器を組み込む。

## 裏取りメモ（司令塔による検証）

会議の外部（実コード読解）で、司令塔が以下を発見・検証済み:
`CaptureMonitorAtCursorToClipboard()`（XButton2短押しの自前スクショ）は`SetClipboardImage(dib)`を呼び、これが
`SelfClipTick`を立てる。`ClipChanged(type)`は冒頭で`A_TickCount - SelfClipTick < 500`なら即returnするため、
**XButton2による自前スクリーンショットは、この経路を通る限り構造的に毎回、自分自身の書き込みとして無視され、
履歴に一度も載らない**。Win+Shift+S（OS標準）はOS側が独自にクリップボードへ書き込むため、この抑制を受けず
正常に履歴へ載る。「ことがある」の実体は、2つの取り込み経路の非対称性だった可能性が高い。

行番号はFableの設計時点（v1.12.0、コミット`d896734`時点）のもので実ファイルと照合済み: `ClipChanged`(1032),
`CaptureClip`(1050), `CaptureClipImage`(1101), `PushClipImage`(1117), `CaptureMonitorAtCursorToClipboard`(1232),
トレイメニュー「設定フォルダを開く」(1904)。

## A. 理想の体験フロー

1. ユーザー「スクショが履歴に残らないことがある」
2. AI「タスクトレイのアイコンを右クリック →『診断情報をコピー』を押して、ここに貼り付けてください」
3. ユーザーがメニュークリック→Ctrl+V（操作はこの2アクションだけ）
4. AIが貼られたJSONを読む。ファネル型カウンターで「どの段階で消えたか」が一目瞭然:
   - `selfSuppress`が伸びて`capImage`が伸びていない → 自己書込抑制で消えている
   - `capImage`は伸びて`rejUserImage`も伸びている → ユーザー操作フィルタで却下
   - `pushImage`まで伸びている → 履歴には載っており表示側の問題
5. **差分プロトコル**: 「診断コピー → 問題の操作を1回 → もう一度診断コピー」の2枚で、その1操作がどの経路を
   通ったかが差分で確定する。
6. 修正後は同じ手順で`shotDirect`が増えることを確認すれば「直った」が数値で言える。

## B. 統合アーキテクチャ（コンポーネント4個）

```
[1] 計器コア                 [2] 計測点（既存経路への1行フック）
 ClipDiag (Map, メモリのみ)    ClipChanged / CaptureClip(Image) /
 DiagBump(key)  ←──────────  PushClipHistory(Image) / XButton2経路
      │                       の各分岐に DiagBump("...") を1行ずつ
      │ 読むだけ
      ▼
[3] ダンプ&コピー                        [4] 経路修正（バグ修正本体）
 BuildDiagText() → トレイ項目            CaptureMonitorAtCursorToClipboard
 「診断情報をコピー」→ A_Clipboard        成功時に PushClipImage を直接呼ぶ
 （SelfClipTickを先に立てて自己書込扱い）  （ClipChanged経路は構造的に通らないため）
```

- **[1] 計器コア**（約12行）: `global ClipDiag := Map()`。値は`{n, last}`。書き込み入口は`DiagBump()`の1関数のみ。
- **[2] 計測点**: 既存関数の既存分岐に1行ずつ。新しい分岐・新しいタイマー・新しいスレッド的要素は作らない。
- **[3] ダンプ&コピー**（約40行）: トレイメニュー項目1つ。押した瞬間だけメモリ→JSON文字列→クリップボード。
- **[4] 経路修正**（約8行）: XButton2自前キャプチャの履歴直接登録。`shotDirect`カウンターで効果を観測できる。

## C. 具体機構

### C-1. 計器コア（グローバル定義部、`ClipHistory`宣言付近に追記）

```ahk
; --- 診断計器: メモリのみ・プロセス終了で消える(非永続原則と同居)。書込入口はDiagBumpだけ ---
global ClipDiag := Map()
global ClipDiagStartTick := A_TickCount

DiagBump(key) {
    global ClipDiag
    if ClipDiag.Has(key)
        ClipDiag[key].n += 1, ClipDiag[key].last := A_TickCount
    else
        ClipDiag[key] := {n: 1, last: A_TickCount}
}
```

リセットタイミング: **プロセス再起動のみ**。手動リセット機能は作らない（差分プロトコルで代替でき、リセット
ボタンは「押し忘れ／押した直後の混乱」という新しい嘘の源になるため）。

### C-2. 計測点の全リスト

| キー | 挿入場所（実装時にdist/soushin-suggest.ahkの現在行で再確認） | 意味 |
|---|---|---|
| `selfSuppress` | `ClipChanged`冒頭の`SelfClipTick < 500`分岐 | **自己書込抑制の発動回数**（主症状の直接証拠） |
| `evtClear` | `type = 0`分岐 | クリア通知 |
| `watchOff` | `!ClipWatchOn`分岐 | 監視一時停止中に捨てた数 |
| `ignoreFormat` | `ClipHasIgnoreFormat()`分岐 | パスワードマネージャ除外 |
| `evtText` / `evtImage` | `SetTimer(CaptureClip…)`直前 | デバウンス予約に到達したイベント数 |
| `capText` / `capImage` | `CaptureClip`/`CaptureClipImage`冒頭 | デバウンス後に実行された回数 |
| `rejUserText` / `rejUserImage` | 各ユーザー操作フィルタのreturn | **1000ms窓フィルタでの却下数** |
| `rejSource` | `ClipSourceExcluded()`のreturn（両関数） | 除外元アプリ却下 |
| `rejEmptyLong` | テキスト空/超過のreturn | 空・上限超過 |
| `rejDib` / `rejSize` / `rejMinPx` | 画像側の各return | DIB取得失敗・バイト超過・極小 |
| `pushText` / `pushImage` | `PushClipHistory`/`PushClipImage`冒頭 | 履歴に載った数（ファネルの出口） |
| `shotDirect` / `shotDirectRej` / `shotFail` | C-4の修正コード内 | XButton2直接登録の成功/ガード却下/キャプチャ失敗 |

グローバルに増えるのは`ClipDiag`と`ClipDiagStartTick`の2つだけ。

### C-3. ダンプ&コピー（トレイメニュー「設定フォルダを開く」の下に追加）

```ahk
A_TrayMenu.Add("診断情報をコピー", CopyDiagnostics)
```

```ahk
; メモリ上の計器をJSON文字列化してクリップボードへ。ディスクには一切書かない。
; 履歴本文・クリップボード内容は絶対に含めない(カウンターと設定値のみ)。
CopyDiagnostics(*) {
    global SelfClipTick
    txt := BuildDiagText()               ; ★書き込みの前にスナップショット
    SelfClipTick := A_TickCount          ; PasteTextと同じ流儀で自己書込としてマーク
    A_Clipboard := txt
    Flash("診断情報をコピーしました。AIチャットに貼り付けてください", 1800)
}

BuildDiagText() {
    global ClipDiag, ClipDiagStartTick, AppVersion, ClipWatchOn
    global ClipUserWindowMs, ClipImageMaxBytes, ClipImageMinPx, ClipHistory
    now := A_TickCount
    s := '{"app":"soushin-suggest","ver":"' . AppVersion . '"'
       . ',"uptimeMs":' . (now - ClipDiagStartTick)
       . ',"watchOn":' . (ClipWatchOn ? 1 : 0)
       . ',"histLen":' . ClipHistory.Length
       . ',"cfg":{"userWindowMs":' . ClipUserWindowMs
       . ',"selfSuppressMs":500,"debounceMs":120'
       . ',"imgMaxMB":' . Round(ClipImageMaxBytes / 1048576)
       . ',"imgMinPx":' . ClipImageMinPx . '}'
       . ',"counters":{'
    first := true
    for key, v in ClipDiag {
        s .= (first ? "" : ",") . '"' . key . '":{"n":' . v.n . ',"agoMs":' . (now - v.last) . "}"
        first := false
    }
    return s . "}}"
}
```

キー・値とも自前生成の固定文字列と整数のみなのでJSONエスケープ処理は不要（ユーザー由来文字列を入れない仕様）。
JSONライブラリは導入しない。

### C-4. XButton2スクショの履歴直接登録（バグ修正本体）

```ahk
CaptureMonitorAtCursorToClipboard() {
    global ClipImageMaxBytes, ClipImageMinPx
    rect := MonitorRectAtCursor()
    if !IsObject(rect) {
        DiagBump("shotFail")
        return false
    }
    dib := CaptureRectToDib(rect.l, rect.t, rect.w, rect.h)
    if !dib {
        DiagBump("shotFail")
        return false
    }
    ok := SetClipboardImage(dib)
    if ok {
        FlashScreenRect(rect.l, rect.t, rect.w, rect.h)
        ; SelfClipTickにより ClipChanged→CaptureClipImage 経路は自己書込として遮断される(仕様通り)。
        ; そのためここで直接履歴へ載せる。通常経路と同じサイズガードを通す(fail-closed)。
        if (dib.Size <= ClipImageMaxBytes && rect.w >= ClipImageMinPx && rect.h >= ClipImageMinPx) {
            PushClipImage(dib, rect.w, rect.h)
            DiagBump("shotDirect")
        } else
            DiagBump("shotDirectRej")
    } else
        DiagBump("shotFail")
    return ok
}
```

安全性の根拠:
- **二重登録なし**: `ClipChanged`側は`SelfClipTick`で遮断されたまま（既存の抑制は一切触らない）。直接Pushと
  クリップボード監視Pushが同一イベントで両方走ることは構造的にない。
- **Buffer所有権**: `SetClipboardImage`は`hMem`へ**コピー**してOSに所有権を渡す。手元の`dib` Bufferは独立所有
  のままなので、`PushClipImage`が履歴に保持してよい。
- **クリップボード開閉**: `SetClipboardImage`内の`try/finally CloseClipboard`は無変更。
- Win+Shift+S経路（XButton2長押し）は無変更。

## D. 「診断が嘘をつかない」ための内訳つきカウンター設計

1. **スナップショットは書込前に取る**: `CopyDiagnostics`は`A_Clipboard`代入の**前**に`BuildDiagText()`を呼ぶ。
   診断コピー自体が発生させる`selfSuppress`+1がダンプに混入しない。
2. **却下理由は合算しない**: `rejUser`/`rejSource`/`rejSize`/`rejMinPx`/`rejDib`/`rejEmptyLong`を独立キーで持つ。
3. **全キーに`agoMs`（最終発生からの経過ms）を付ける**: 差分プロトコルと併用すると単発イベントの経路が特定できる。
4. **ファネルは不等式で読む**: デバウンス（-120ms合流）により`evtImage ≧ capImage`は正常。この2つが一致しない
   のはバグではない。AIが「数が合わない＝異常」と誤読しないよう運用知識として固定する（ダンプ自体には
   注記を入れない — 肥大化防止）。
5. **現在状態を同梱**: `watchOn`・`histLen`・`cfg`をカウンターと一緒に出す。
6. **ユーザーデータ非混入**: ダンプに履歴本文・クリップボード内容・ウィンドウタイトル・アプリ名を含めない。
   カウンターと固定設定値のみ。クリップボードという公開媒体に出す以上、これは仕様として固定する。

## E. MVP

**「診断情報をコピー」トレイ項目 + 画像経路の6カウンター**（`selfSuppress`/`evtImage`/`capImage`/
`rejUserImage`/`pushImage`/`shotFail`）。合計約50行。

C-4の修正は8行で仮説的にはほぼ確実だが、「ほぼ確実」を「実測で確定」に変えるのがこの製品が今回学ぶべきこと
そのもの。MVPの計器だけで、XButton2短押し→診断コピーで`selfSuppress`+1・`pushImage`+0という仮説確定、
Win+Shift+S→診断コピーで`evtImage`〜`pushImage`が+1という非対称性の実証が実機でできる。

## F. 捨てた案と理由

| 案 | 捨てた理由 |
|---|---|
| 構造化ログファイル（ディスク永続） | 非永続原則という製品の看板に反する。AVスキャン・ハンドルロックでシングルスレッドのタイマー精度を汚し、診断機構自体が新たなタイミングバグ源になる |
| `ClipChanged`側に呼び出し元ホワイトリストで自己抑制免除 | `SelfClipTick`は`PasteText`と共用。免除窓を作ると貼り付けが履歴に再登録される退行リスク |
| `SelfClipTick`の500msを短縮 | タイミング絆創膏。「たまに壊れる」を新製造する |
| `OutputDebug` + DebugView | 外部ツール導入を要求し「軽い操作1回」の設計目標に反する |
| 常駐デバッグGUI／ステータスウィンドウ | 常駐ツールの性格に反する肥大化。GUI破棄タイミングの既知地雷を増やすだけ |
| JSONライブラリ導入 | 出力はカウンターと固定文字列のみ。手組みで足り、依存追加は単一ファイル配布の利点を削る |
| `ClipUserWindowMs`のini化・調整 | 症状と無関係（XButton2は`LastUserCopyTick`を立てているのでこのフィルタは通過している） |
| 手動カウンターリセット機能 | 差分プロトコルで代替可能。リセットは新しい不確定要素になる |

## G. 地雷と回避策

1. **診断コピー自体が`ClipChanged`を発火させる** → `SelfClipTick`を代入前に立てる（`PasteText`と同一パターン）。
   かつスナップショットを先に取る（D-1）。この2つを欠くと「診断テキストが履歴に載る」「診断値が自己汚染される」
   の二重事故。
2. **直接Pushでの既存ガードのバイパス** → C-4で`ClipImageMaxBytes`/`ClipImageMinPx`を明示的に通す。超過時に
   黙って捨てない: `shotDirectRej`が立つので「クリップボードには載るのに履歴に載らない」再発時も計器で即特定できる。
3. **dib Bufferの二重利用の誤解** → `SetClipboardImage`はコピーを渡すので履歴保持は安全。将来`SetClipboardImage`
   を「コピーせず所有権移転」に最適化すると即座に壊れるため、C-4のコメントに所有権の根拠をコードにも書き残す。
4. **Mapキーのtypoによるサイレント計測漏れ** → 書き込み入口を`DiagBump()`1関数に限定。C-2の表を正としてレビュー
   時に照合する。
5. **ファネル等式検証の誘惑** → `evtImage = capImage + …`の等式チェックをコードに入れない。デバウンス合流で
   恒常的に成り立たず、警告が常時鳴る計器は信頼を失う。
6. **`Flash()`のToolTip競合** → 診断コピーの通知は既存`Flash()`を使う（新GUIを作らない）。
7. **将来の「診断項目もっと増やそう」圧力** → 計測点は「returnする分岐に1行」のみ許可、というルールを固定する。
   関数の実行時間計測・履歴内容のプレビュー同梱などは肥大化の典型入口であり、必要になった時に別途設計する。

## 検証手順（実装後・reality-checker向け）

1. 起動→診断コピー（基準値）
2. XButton2短押し1回→診断コピー→`shotDirect`+1 / `selfSuppress`+1 / `pushImage`+1 を確認
3. XButton2長押し→範囲選択→診断コピー→`evtImage`/`capImage`/`pushImage`が+1
4. ランチャーを開き履歴先頭に📷が2件あること
5. ②で`shotDirectRej`が立つ場合はモニタ解像度と`imgMaxMB`をダンプから読み取り境界を疑う
