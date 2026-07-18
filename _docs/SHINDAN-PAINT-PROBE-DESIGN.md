# 設計: 診断を「描画の真実」まで見えるようにする — ピクセル実測プローブ(Paint Probe)

設計=Fable（claude-fable-5） / 素材集め=司令塔（Claude Sonnet 5・会議ハーネス経由） / 2026-07-18（緊急対応）

## 背景

`+Grid`変更後、定型文タブ・履歴タブでスクショ撮影時に「データはあるのに画面に文字が表示されない/完全空白になる」バグが実機で発生。既存の`/shindan/`診断ページはコピー検知・送信成否のカウンターしか持たず、このGUI描画不具合を一切検知できないことが判明した。前回設計（`SHINDAN-UI-STRUCT-DESIGN.md`、座標・可視性・行数のJSON化）は**今回のバグ検知には無力**（`GetCount()`はデータモデルの件数を返すだけで、画面に描かれたかは見ないため）。

## 結論の骨子

ListViewの実表示面を`GetPixel`で数十点サンプリングし、導出スカラー（インク/罫線/背景の点数と`state`判定）だけを診断JSONに載せる。ピクセル値・画像は一切送らない。既存のプライバシー保証はこの「導出値のみ」という制約で守る。

## 必答論点への回答

1. **座標・可視性・行数のJSONだけでは検知不可能**、UIAutomationも同じ理由（LVM系メッセージ=データモデルに答えるだけ）で不採用。GetUpdateRectも「無効化されずに完了扱い」の状態では空を返すため不採用。**唯一の現実的な検知手段はGetPixelによる実測**。
2. `LVS_OWNERDATA`（仮想ListView）への転換は今日はやらない。大規模書き換えのため、プローブ導入後に技術的負債タスクとして切り離す。
3. キャプチャタイミングは「表示時1回」ではなく「描画に触った節目（Fill*関数末尾・ShowLauncher末尾）の直後+150ms」の一発タイマーに変更。既存の0遅延再描画タイマー経由も自動的にカバーされる。
4. **診断（プローブ）を先に作る**。計器なしで修理を続けるのがモグラ叩きの正体だったため。同日後半でプローブをゲートに最小の修正候補2点を試す。

## A. 理想の体験フロー

1. ユーザーがランチャーを開く/検索する/タブを切り替える。150ms後、アプリが自分でリスト表示面を数十点だけ読み、「インク（文字）が描かれているか」を自己採点する。
2. 白化が起きた瞬間、カウンター`uiBlank`/`uiGridOnly`が加算され、直近のプローブ結果が`paint`フィールドとして診断JSONに載る。開発実行時はToolTipで即時警告（本番exeでは出さない）。
3. `/shindan/`に新セクション「画面の描画（白化検知）」。「rows:7なのに文字ピクセル0点→データはあるのに描画されていません」と機械が断言する。
4. AIは`scripts/verify-paint-probe.ps1`で実機を触らずに白化の有無をPASS/FAILで判定できる。

## B. 統合アーキテクチャ（変更3箇所＋新規1つ）

```
[描画に触る節目]                         [計測(読み取り専用)]
ShowLauncher 末尾 ──┐
FillLauncherHistoryLV 末尾 ──┤→ DiagSchedulePaintProbe()  … SetTimer(-150)一発
FillLauncherSnippetsLV 末尾 ─┘        │
                              DiagProbeLauncherPaint()
                              GetCount(データの真実) × GetPixel数十点(描画の真実)
                              → DiagPaintBody(文字列キャッシュ) ＋ DiagBump("uiBlank"等)
                                       │
BuildDiagText() … キャッシュ連結のみ ──┘ ← 既存送信経路(DiagPush/Async→KV)は無変更
                                       │
/shindan/index.html … KEY_REGISTRY+2キー ＋ paintカード1枚
```

## C. 具体機構

### C-1. プローブ本体（`BuildDiagText`直後に新設）

```ahk
global DiagPaintBody := ""      ; DiagEndpoint直後に追加
global DiagPaintTick := 0

; 描画実測プローブ。読み取り専用(GetDC/GetPixel/ReleaseDC/GetCount/LVM_GETITEMRECT)のみで、
; 【不変条件】SETREDRAW/InvalidateRect/RedrawWindow/Move等、描画状態を書き換えるAPIは絶対に呼ばない。
; よって白化バグのクラス(描画状態の破損)をプローブ自身が起こすことは構造的にない。
DiagSchedulePaintProbe() {
    SetTimer(DiagProbeLauncherPaint, -150)   ; WM_PAINT処理後に読む。多重呼びは一発タイマーが自然に合流
}

DiagProbeLauncherPaint() {
    global LauncherGui, LauncherTab, LauncherLvH, LauncherLvS, DiagPaintBody, DiagPaintTick
    if !(IsObject(LauncherGui) && IsObject(LauncherTab))
        return
    lv := (LauncherTab.Value = 1) ? LauncherLvH : LauncherLvS
    rows := 0
    try rows := lv.GetCount()
    ink := 0, other := 0, bg := 0
    if (rows > 0) {
        hdc := DllCall("GetDC", "Ptr", lv.Hwnd, "Ptr")
        rect := Buffer(16, 0)
        Loop Min(rows, 3) {                       ; 先頭3行×8点=最大24点
            NumPut("Int", 2, rect, 0)             ; LVIR_LABEL
            if !SendMessage(0x100E, A_Index - 1, rect.Ptr, lv)   ; LVM_GETITEMRECT
                continue
            l := NumGet(rect, 0, "Int"), t := NumGet(rect, 4, "Int")
            r := NumGet(rect, 8, "Int"), b := NumGet(rect, 12, "Int")
            y := (t + b) // 2
            Loop 8 {
                x := l + 6 + (r - l - 12) * (A_Index - 1) // 7
                px := DllCall("GetPixel", "Ptr", hdc, "Int", x, "Int", y, "UInt")
                if (px = 0xFFFFFFFF)
                    continue
                rr := px & 0xFF, gg := (px >> 8) & 0xFF, bb := (px >> 16) & 0xFF
                lum := (rr * 3 + gg * 6 + bb) // 10
                if (lum < 0x60)
                    ink++                          ; 文字(濃色)が実際に描かれている
                else if (Abs(rr-0xF0) <= 8 && Abs(gg-0xF6) <= 8 && Abs(bb-0xFF) <= 8)
                    bg++                           ; 背景F0F6FFそのまま
                else
                    other++                        ; 罫線・選択ハイライト等
            }
        }
        DllCall("ReleaseDC", "Ptr", lv.Hwnd, "Ptr", hdc)
    }
    state := (rows = 0) ? "na" : (ink > 0) ? "full" : (other > 0) ? "gridOnly" : "blank"
    DiagPaintBody := '"tab":' . LauncherTab.Value . ',"rows":' . rows
        . ',"ink":' . ink . ',"other":' . other . ',"bg":' . bg . ',"state":"' . state . '"'
    DiagPaintTick := A_TickCount
    if (state = "blank")
        DiagBump("uiBlank")
    else if (state = "gridOnly")
        DiagBump("uiGridOnly")
    if (state != "full" && rows > 0 && !A_IsCompiled)
        ToolTip("⚠描画異常検知 state=" . state . " rows=" . rows), SetTimer(() => ToolTip(), -2500)
}
```

ピクセル値そのもの・座標対応表はJSONに**載せない**（点数3つと判定語のみ）。`GetDC(lv.Hwnd)`はDWMのリダイレクトサーフェス＝「実際に描かれた面」を読む。**`PrintWindow`/`WM_PRINT`は使用禁止**（コントロールに描き直させてしまい、白い画面を健康と誤判定する＝バグを隠す側に働く）。

### C-2. 呼び出し3行（すべて既存関数の末尾に1行ずつ）

- `FillLauncherSnippetsLV` — `InvalidateRect`行の後に`DiagSchedulePaintProbe()`
- `FillLauncherHistoryLV` — `lv.Opt("+Redraw")`の後に`DiagSchedulePaintProbe()`
- `ShowLauncher` — `LauncherSearchEdit.Focus()`の後に`DiagSchedulePaintProbe()`

不変条件（更新版）: 「5分送信タイマーはWin32 UIに触れない（キャッシュ文字列連結のみ）。UIに触る計測は読み取り専用APIに限定し、描画状態を書き換えるAPIは計測経路で禁止」。

### C-3. JSONスキーマと配線

`BuildDiagText`の`return s . "}}"`を:

```ahk
    s .= "}"                                  ; countersを閉じる
    if (DiagPaintBody != "")
        s .= ',"paint":{"agoMs":' . (now - DiagPaintTick) . ',' . DiagPaintBody . '}'
    return s . "}"
```

出力例: `"paint":{"agoMs":1200,"tab":2,"rows":7,"ink":0,"other":9,"bg":15,"state":"gridOnly"}`（約90バイト）。

`shindan/index.html`:
- セクション追加: `<section data-sec="paint"><h2>画面の描画（白化検知）</h2><div class="grid"></div></section>`
- `KEY_REGISTRY`に2エントリ: `uiBlank`（白化検知・完全空白）/ `uiGridOnly`（白化検知・文字未描画）、いずれも`kind: 'rej'`
- 判定ルールに1つ追加: `uiBlank`または`uiGridOnly`が観測されていたら赤カード、message「リストにデータはあるのに画面に描かれていない状態がn回起きています」。`snapshot.paint`があれば`state`と`rows/ink`を併記。**総合verdictに合流させる**（前回設計と違い、本番ユーザーにも起きて困る実バグの検知なので隔離しない）。

### C-4. 同日後半: バグ修正候補（プローブをゲートに2点だけ）

原因の有力仮説: 0遅延タイマー3連発（`RefreshLauncherHistory`/`RedrawActiveLauncherSnippetsTab`/`RedrawLauncherHeader`）により、`Fill*`実行中（`-Redraw`〜`+Redraw`の間）に別タイマースレッドが割り込み、同一ListViewへWM_SETREDRAWトグルが入れ子で走るとOFFが実効的に残留する。OFF残留のListViewは一切描画されず親背景F0F6FFが見えるだけ＝「罫線もアイテムも無い完全空白」と症状が一致。

修正候補（プローブがFAILと言ってから着手、それ以上は広げない）:
1. `FillLauncherSnippetsLV`/`FillLauncherHistoryLV`の冒頭に`Critical`を1行（`-Redraw`〜`+Redraw`区間へのタイマー割り込みを禁止）
2. `InvalidateRect`を`RedrawWindow`（`RDW_INVALIDATE|RDW_ERASE|RDW_ALLCHILDREN|RDW_FRAME` = 0x0485）に差し替え

検証は目視でなく`verify-paint-probe.ps1`と実機の`/shindan/`赤カード消滅で判定し、reality-checkerに委任する。

### C-5. `scripts/verify-paint-probe.ps1`（新規・verify-diagnostics.ps1の複製改変）

ステージングにダミー定型文3件を配置→起動→ドライバAHKで`^#v`送出→600ms待ち（プローブ150ms+余裕）→F10→`diag-out.json`をアサート: `paint`が存在／`paint.rows >= 1`／`paint.state = "full"`／`counters.uiBlank`が無いこと。

## E. MVP（1つだけ作るなら、今日中）

C-1＋C-2＋C-3のAHK側だけ（新規関数2つ・グローバル2つ・呼び出し3行・BuildDiagText2行、合計70行弱）。これだけで`diag-out.json`と`GET /api/diag/latest`に`paint.state`が載り、今起きている空白が「rows>0なのにink=0」という数値証拠になる。ページ表示・verifyは次点、C-4の修正はプローブが動いてから。

## F. 捨てた案と理由

| 案 | 理由 |
|---|---|
| UIAutomation/IAccessible検証 | LVM系メッセージ=データモデルに答えるので、画面が真っ白でも「10件可視」と返す。今回のバグクラスに原理的に盲目。 |
| `LVS_OWNERDATA`転換 | 構造対策として有望だが大規模書き換え。計器なしの大手術は順序が逆。負債タスクとして切り離し。 |
| カナリア・コントロール | 判定に結局ピクセル読みが要る。本物のListViewを直接読めばよい。 |
| 全ステップのGDI/DWM状態ログ | 将来価値はあるが今日は過剰。プローブの`state`遷移+既存カウンターで十分。 |
| GetUpdateRect指標 | 「無効化されずに完了扱い」の状態では常に空を返し健康と誤判定する。 |
| 前回設計(座標ダンプ)を今日実装 | 白化検知に無力。優先度をプローブの後ろに下げる（設計書自体は破棄しない）。 |
| PrintWindow/WM_PRINT | コントロールに描き直させるため、白い画面を健康と誤判定する（バグ隠蔽側に働く）。 |
| スクリーンショット送信・ピクセル値送信 | プライバシーの一線に抵触。点数3つと判定語のみ送る。 |

## G. 地雷と回避策

- **G-1（プローブ自身が白化を起こす）**: 計測経路では読み取り専用APIのみ許可。SETREDRAW/Invalidate/RedrawWindow/Moveを足したくなったらそれは修正でありC-4側へ。
- **G-2（DPIスケーリング）**: `GetItemRect`と`GetPixel`は同じクライアント座標系なので補正不要。ink判定閾値は輝度0x60（灰色まで拾う）。
- **G-3（選択行の誤判定）**: 選択ハイライト行はink=0になりうるが、先頭3行サンプリングで残り2行の黒文字が拾える。
- **G-4（ランチャーが閉じた後のタイマー発火）**: `IsObject(LauncherGui)`ガードで空振りさせる。
- **G-5（背景色定数の分岐）**: 判定はF0F6FF直値比較。将来色を変える場合は定数を1箇所に寄せる。
- **G-6（「verifyが緑=バグ解決」ではない）**: プローブ配線の緑と実機再現の緑は別項目としてreality-checkerに渡す。
- **G-7（8KB上限）**: paintは約90バイト、余裕あり。将来も最新1件の上書き保持を維持し履歴配列にしない。
- **G-8（本番でのToolTip）**: 検知ToolTipは`!A_IsCompiled`ガード済み、本番ユーザーへの通知はしない。
