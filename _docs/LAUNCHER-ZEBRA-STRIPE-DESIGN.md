# 設計書: ランチャーListView視認性 — ゼブラストライプ(NM_CUSTOMDRAW)最小実装

設計=Fable（claude-fable-5） / 素材集め・裏取り・統合=司令塔（Claude Sonnet 5） / 2026-07-18 / 3段構えワークフロー手順2の産物

## 背景・この設計書の位置づけ

[`LAUNCHER-SNIPPETS-CLIBOR-VISIBILITY-DESIGN.md`](LAUNCHER-SNIPPETS-CLIBOR-VISIBILITY-DESIGN.md)のMVP（`+Grid`追加）を実装・コミット（v1.22.7）した後、実機検証で**`+Grid`（LVS_EX_GRIDLINES）の罫線色はシステム固定の淡いグレーで色指定不可能、背景色`F0F6FF`とのコントラストがほぼゼロで実質見えない**ことが判明した。本設計書はこの反省を踏まえた追補で、前回設計を上書きせず新規ファイルとして残す。

裏取り済み: 行番号（L1517, L1551-1552, L1565-1566, L1029, L1059, L340, L2832-2840, L3025-3030）・NM_CUSTOMDRAW関連の構造体オフセット・定数値のすべてを、実コードとMicrosoft公式ドキュメント・コミュニティの実働コードの両方で照合し、事実誤認なしと確認済み。

## 判断の要旨

**論点3（Cliborの視認性の本質）**: Cliborで行が読みやすい本質は「各行の帰属が面で判る」ことであり、1px級の線ではない。`+Grid`（1px淡色線）が背景`F0F6FF`上で潰れて見えなかったのがその証拠。再現すべき最小構成は「隣接行と面のコントラストが交互に変わること」＝ゼブラストライプ1本。区切り線・行高・フォント等のClibor外観再現は一切しない。

**論点1（NM_CUSTOMDRAWは本当に安全か）**: 会議では「安全網が整ったから再検討してよい」という理由付けだったが、Fableはこれを「機構自体が白化バグのクラスに構造的に属さないから」と精緻化した。白化バグの真因はWM_SETREDRAWトグルの残留（描画状態の破壊的書き換え）だった。ゼブラストライプはcomctl32が描画中に投げてくる問い合わせに構造体フィールド1個（clrTextBk）と戻り値で答えるだけで、SETREDRAW/InvalidateRect/RedrawWindow等の描画状態APIを一切呼ばない（Paint Probeの不変条件と同じ思想）。前回の不採用理由「表示毎のフック着脱が必要」は誤前提で、OnMessageフックを起動時に1回だけグローバル登録し、フック内でhwndを整数比較して対象外は即素通しする設計にすれば着脱は不要になる。追加防御は3つ: ①killスイッチ（グローバル定数、OFFで即素通し）、②フック全体をtryで包み例外時は既定描画に落とす（fail-open）、③破棄済みコントロールにフック内から触らない（hwndを整数キャッシュ）。

**論点2（背景色）**: 背景色は変更しない。ゼブラの2色は1箇所のstatic定数で定義し、履歴/定型文の両LVを同一の1つのフック関数が塗るため、タブ間で色がズレる経路が構造的に存在しない。

**論点4（MVP）**: 今日作るのは「ゼブラストライプ1本＋無効化した`+Grid`の撤去」だけ。ON/OFF設定のini露出・ホバー行ハイライト・選択色カスタムはすべてやらない。

## A. 理想の体験フロー

1. 長押しでランチャーが開く。背景は今まで通りの落ち着いた水色（F0F6FF）。
2. 履歴タブ・定型文タブとも、奇数行はF0F6FF、偶数行はわずかに濃い同系色（DCE7F8）で交互に塗られ、どの文字がどの行か・行が何件あるかが一目で判る。
3. タブを切り替えても背景も縞も同じ配色。検索で絞り込んでも縞は表示行基準で常に交互（実インデックスではなく表示行で塗るため、絞り込み後も縞が崩れない）。
4. 選択行はOS標準の選択ハイライトがそのまま出る（縞はそれを邪魔しない）。
5. 万一フック内で何かが失敗しても、縞が出ないだけで文字は普通に描画される。

## B. 統合アーキテクチャ（変更箇所4つ）

| # | 場所 | 変更 |
|---|------|------|
| 1 | L1552 / L1566（両ListViewのオプション文字列） | `+Grid` を削除（視覚効果ゼロが実証済み。ゼブラと重なると余計なノイズ）。`BackgroundF0F6FF`・`+0x40`・`+LV0x10000`は現状維持 |
| 2 | ShowLauncher内（L1552直後とL1566直後） | `LauncherLvHHwnd := LauncherLvH.Hwnd` / `LauncherLvSHwnd := LauncherLvS.Hwnd` をグローバルに整数キャッシュ。CloseLauncher（L2839付近の`LauncherGui := 0`と並べて）で両方を0クリア |
| 3 | スクリプト起動部（auto-execute区間） | `OnMessage(0x004E, LauncherLVCustomDraw)` を1回だけ登録＋killスイッチ定数。表示毎の着脱は行わない |
| 4 | DiagProbeLauncherPaint L340の背景判定 | ゼブラ色DCE7F8も`bg++`に分類する分岐を1本追加（診断の意味を保つ） |

配線: comctl32はListViewの各行を描く直前に親Gui宛てへWM_NOTIFY(NM_CUSTOMDRAW)をSendMessageする → AHKのOnMessageが受ける → hwndFromが両LVのキャッシュ値と一致した時だけ処理し、それ以外（SnipMgrのLV含む全コントロール）は即returnで既定処理へ素通し。FillLauncher*のCritical区間（L3013/3060付近）とは衝突しない: RedrawWindowはRDW_UPDATENOWを含まないため実描画はCritical("Off")後に走る。仮にCritical中にNM_CUSTOMDRAWが届いてもAHKは既定値0(=CDRF_DODEFAULT)を返すだけで、最悪「その1フレームだけ縞なし」で自己回復する。

## C. 具体機構（AHK v2実コード、裏取り済み）

### C-1. フック本体（新規関数1個＋登録2行）

```autohotkey
; --- 起動部(auto-execute)に追加 ---
global LauncherZebraOn := true      ; killスイッチ。falseで完全素通し(既定描画)
global LauncherLvHHwnd := 0, LauncherLvSHwnd := 0
OnMessage(0x004E, LauncherLVCustomDraw)   ; WM_NOTIFY。登録は起動時1回のみ・着脱しない

; ランチャーListViewのゼブラストライプ(NM_CUSTOMDRAW)。
; 【不変条件】描画状態を書き換えるAPI(SETREDRAW/RedrawWindow等)は絶対に呼ばない。
; comctl32の問い合わせにclrTextBkと戻り値で答えるだけ。例外時はfail-open(縞なし既定描画)。
LauncherLVCustomDraw(wParam, lParam, msg, hwnd) {
    global LauncherZebraOn, LauncherLvHHwnd, LauncherLvSHwnd
    static NM_CUSTOMDRAW := -12
        , CDDS_PREPAINT := 0x1, CDDS_ITEMPREPAINT := 0x10001
        , CDRF_DODEFAULT := 0x0, CDRF_NOTIFYITEMDRAW := 0x20
        , ZEBRA_A := 0xFFF6F0    ; COLORREF(BGR) = RGB F0F6FF 既存背景そのまま
        , ZEBRA_B := 0xF8E7DC    ; COLORREF(BGR) = RGB DCE7F8 同系色をひと目盛り濃く
        , OFF_CODE      := A_PtrSize * 2            ; NMHDR.code
        , OFF_STAGE     := A_PtrSize * 3            ; NMCUSTOMDRAW.dwDrawStage
        , OFF_ITEMSPEC  := A_PtrSize * 5 + 16       ; NMCUSTOMDRAW.dwItemSpec(rc RECT16バイトの後)
        , OFF_CLRTEXTBK := (A_PtrSize = 8) ? 84 : 52  ; NMLVCUSTOMDRAW.clrTextBk
    if !LauncherZebraOn
        return                                       ; 未処理return=既定処理へ
    try {
        from := NumGet(lParam, 0, "Ptr")             ; NMHDR.hwndFrom
        if (from != LauncherLvHHwnd && from != LauncherLvSHwnd) || !from
            return
        if (NumGet(lParam, OFF_CODE, "Int") != NM_CUSTOMDRAW)
            return
        stage := NumGet(lParam, OFF_STAGE, "UInt")
        if (stage = CDDS_PREPAINT)
            return CDRF_NOTIFYITEMDRAW               ; 行ごとの通知を要求
        if (stage = CDDS_ITEMPREPAINT) {
            row := NumGet(lParam, OFF_ITEMSPEC, "UPtr")   ; 0始まりの表示行番号
            NumPut("UInt", Mod(row, 2) ? ZEBRA_B : ZEBRA_A, lParam, OFF_CLRTEXTBK)
            return CDRF_DODEFAULT                    ; 塗りは既定処理に任せる(自前GDI描画なし)
        }
    } catch {
        ; fail-open: 解析に失敗したら既定描画に落とす(縞が消えるだけ)
    }
    return
}
```

構造体オフセットの根拠（x64/x86両対応、裏取り済み）: NMHDRは`hwndFrom(Ptr)@0 / idFrom(UPtr)@A_PtrSize / code(Int)@A_PtrSize*2`。NMCUSTOMDRAWは続けて`dwDrawStage@A_PtrSize*3 / hdc@A_PtrSize*4 / rc(RECT 16B)@A_PtrSize*5 / dwItemSpec@A_PtrSize*5+16 / uItemState / lItemlParam`。NMLVCUSTOMDRAWの`clrText`はx64で80・x86で48、`clrTextBk`はx64で84・x86で52（lItemlParamのポインタ整列でx64は72まで押し出されるため）。この計算はMicrosoft公式ドキュメントとAutoHotkeyコミュニティの実働コード（LV_SetSelColors / LV_Colorsクラス）の両方で独立に一致確認済み。

### C-2. hwndキャッシュ配線

```autohotkey
; ShowLauncher内 L1552の直後
LauncherLvHHwnd := LauncherLvH.Hwnd
; L1566の直後
LauncherLvSHwnd := LauncherLvS.Hwnd

; CloseLauncher(L2839付近)の LauncherGui := 0 の行に並べて
LauncherLvHHwnd := 0, LauncherLvSHwnd := 0
```

フック内から`LauncherLvH.Hwnd`等のオブジェクトプロパティに触らないことが重要（Paint Probeで実証済みの「破棄後アクセスで例外」地雷を、整数比較だけにすることで構造的に回避。0クリアはhwnd値のOS再利用による誤爆も防ぐ）。

### C-3. オプション文字列変更

- L1552: `"w460 r" . rows . " -Hdr -Multi NoSort +0x40 BackgroundF0F6FF"`（`+Grid`削除）
- L1566: `"w460 r" . rows . " -Hdr -Multi NoSort BackgroundF0F6FF"`（同上）
- SnipMgr側（L1029/1059）の`+Grid`は**触らない**（あちらは白背景で罫線が見えている）
- L3025〜3030のコメントは「+Grid導入後」の記述が過去形になるが、RedrawWindow呼び出し自体は削除しない（WM_SETREDRAW残留対策として`+Grid`と独立に有効な修正。コメント先頭に「※+Gridは撤去済みだがこの再描画は残す」の1行だけ追記）

### C-4. Paint Probe整合（L340の隣）

```autohotkey
else if (Abs(rr-0xF0) <= 8 && Abs(gg-0xF6) <= 8 && Abs(bb-0xFF) <= 8)
    bg++                           ; 背景F0F6FFそのまま
else if (Abs(rr-0xDC) <= 8 && Abs(gg-0xE7) <= 8 && Abs(bb-0xF8) <= 8)
    bg++                           ; ゼブラ偶数行DCE7F8(縞も「正常な背景」として扱う)
```

これを入れないと縞ピクセルが`other`に分類され、文字が消えた異常時に`blank`ではなく`gridOnly`と誤報告される（uiBlank/uiGridOnlyカウンタの意味が濁る）。

## E. MVP（今日中・1件だけ）

「C節の全部」= ゼブラ1機構が今日のMVPそのもの。内訳は新規関数1個（約35行）＋起動部3行＋hwndキャッシュ4行＋オプション文字列2箇所の`+Grid`削除＋Probe分岐1本。iniオプション化・色の設定UI・ホバーハイライトは含めない。

検収手順（既存の安全網をそのまま使う）:
1. ランチャーを開き、両タブで縞が目視できること・タブ切替で配色が同一なこと
2. 検索絞り込み→縞が表示行基準で交互のままなこと
3. 診断ページで`paint.state`が`full`・`uiBlank`/`uiGridOnly`が増えないこと
4. 既存モンキーテスト（`scripts/monkey-test.ps1`）を50回試行で再実行し異常なしを確認
5. `LauncherZebraOn := false`で完全に従来表示へ戻ることを1回確認（killスイッチの実効性）

## F. 捨てた案と理由

| 案 | 理由 |
|---|---|
| **行下端1px自前線（会議の発散役案）** | `+Grid`の失敗（淡背景上の1px線は見えない）と同じクラスの再演。しかもITEMPOSTPAINTでのGDIペン生成/選択/復元が必要になり、描画状態に触らない不変条件を破る。ゼブラより危険で効果が薄い |
| **背景色の微調整（会議のE0E8F5案）** | 2026-07-18に確定したばかりの統一色を再度動かす後退リスクのみでリターンなし。ゼブラ単独で目的達成 |
| **F5F5F5への変更（会議の速報役案）** | 水色ブランドの毀損。会議内でも司令塔でも既に否決 |
| **タイポグラフィ・行間調整案** | 行高は既にImageList実測で決まっており、触るとロゴ位置バグの再発温床。効果も不確実 |
| **Class_LV_Colors.ahk** | 不採用継続（外部ファイル同梱の保守・ライセンスコスト、再考不要） |
| **ON/OFFのini設定露出** | グローバル定数で開発者killスイッチとしては足りる。ユーザー設定項目に昇格させるのは需要が確認されてから |
| **表示毎のOnMessage着脱** | 前回不採用の主因だったが、グローバル常駐＋hwnd整数ゲートで不要になった（着脱コード自体が存在しない＝着脱漏れバグも存在しない） |

## G. 地雷と回避策

1. **フック内で破棄済みコントロールに触る**: `LauncherLvH.Hwnd`はGui破棄後に例外。→ hwndを整数キャッシュし整数比較のみ（C-2）。Close時0クリアでhwnd再利用誤爆も防止
2. **未処理メッセージで値を返してしまう**: OnMessageで対象外のWM_NOTIFYに0以外を返すと他コントロール（SnipMgrのLV・Tab3等）の通知処理を壊す。→ 対象外は必ず「値なしreturn」。フック冒頭のhwndゲートを最初の条件にする
3. **Critical区間との交錯**: FillLauncher*のCritical中はOnMessageが呼ばれず既定値0が返る。0=CDRF_DODEFAULTなので害はゼロ（縞なし1フレーム）だが、「縞が一瞬出ない」を白化と誤診しないこと。RedrawWindowにRDW_UPDATENOWを**追加しない**（追加するとCritical中に同期描画が走り、この安全な性質が崩れる）
4. **構造体オフセットのアーキ違い**: x86でx64オフセット(84)を使うとlItemlParamを破壊してクラッシュ相当の壊れ方をする。→ C-1の`A_PtrSize`分岐を必ず維持。コンパイル版(A_IsCompiled)が32bitビルドになっていないかを一度だけ確認
5. **Paint Probeの分類ズレ**: C-4を入れ忘れると診断カウンタが誤報する。実装コミットにC-4を必ず同梱（別コミットに分けない）
6. **一列幅436px問題**: clrTextBkが塗るのは列領域のみで、右端約24px（スクロールバー際）はF0F6FFのまま。縞との境目がわずかに見えるが実害なし。気になった場合のみModifyColの幅を広げて調整（先回り調整はしない）
7. **選択行との干渉**: テーマ有効環境では選択ハイライトがclrTextBkに優先する（望ましい挙動）。クラシックテーマ環境で縞が選択色を上書きして見える報告があれば、ITEMPREPAINTで`uItemState`(オフセット`A_PtrSize*6+16`)のCDIS_SELECTED(0x1)を見て素通しする1行を足す（報告が出てから対応、先回り不要）
