# 設計書: 画像クリップボード履歴への実サムネイル表示（soushin-suggest.ahk v1.6.0 → v1.7.0）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 1186行/v1.6.0)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・4/5成功、implement役1体は認証エラーで失敗) / 裏取り=司令塔Claude
> 日付: 2026-07-15
> 前提: [`CLIPBOARD-IMAGE-HISTORY-DESIGN.md`](CLIPBOARD-IMAGE-HISTORY-DESIGN.md)（画像履歴・実装済み）の表示強化

対象: `C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link\dist\soushin-suggest.ahk`（現1186行）

## 裏取りメモ（司令塔による検証）

会議で技術的に対立する2つの主張が出た（fast役の`CreateDIBitmap`5引数コード例 vs critic役の「CreateDIBSection必須」主張）。実地調査でMicrosoft公式ドキュメントを確認したところ、`CreateDIBitmap`の正確なシグネチャは6引数（`hdc, pbmih, flInit, pjBits, pbmi, iUsage`）であり、**fast役のコード例は引数不足・`CBM_INIT`欠落という技術的誤りと確定**。critic役の「CreateDIBSection必須」は言い過ぎだが方向性は妥当と判定していた。

Fableはこの裏取り結果を踏まえ、どちらのAPIも採らず**`StretchDIBits`で等倍HBITMAPを一度も作らず直接縮小描画する**という第三の解を導出。これにより大画像分のGDIメモリ確保自体が不要になり、リーク面もシンプルになる。

## 結論の要約

| 項目 | 判定 |
|---|---|
| サムネイル生成API | **`StretchDIBits`直描き**（CreateDIBitmap/CreateDIBSectionどちらも不採用） |
| 表示先 | **「定型文の管理」ウィンドウのListView(`SnipMgrHistLV`)のみ**。ランチャーのListBox(`LauncherLbH`)は非対応（会議収束どおり） |
| ハンドル管理 | HBITMAPは`MakeHistThumb`関数内で生成→ImageList_Addで内部コピー→即DeleteObject。関数スコープ外に出さない |
| ImageList | 遅延生成、LV破棄時にcomctl32が自動破棄。肥大時のみ明示的な作り直し＋`ImageList_Destroy` |
| 見積もり行数 | 約+82行（1186行 → 約1265〜1275行） |

---

## A. 理想の体験フロー

**「定型文の管理」ウィンドウ → 履歴タブ（`SnipMgrHistLV`）**

1. スクリーンショット等をコピーすると、従来どおり履歴に「📷 画像 1280×720 (1.2MB)」の行が入る。
2. 履歴タブを開くと、その行の左端に32×32の実サムネイルが表示される。テキスト列（コピー日時・本文プレースホルダー）は現状のまま残す。画像の縦横比は保持し、余白は白でレターボックスする。
3. 行選択→既存の全文プレビュー欄の挙動をそのまま維持。ダブルクリック→再コピーも現行のまま。
4. テキスト行にはアイコンを付けない（`Icon0`指定）。ImageListを設定するとListViewの全行の高さがアイコン高（約36px）に揃う（h240のLVで見える行数は約12行→約6行に減る。仕様として受け入れる）。

**クイックペーストランチャー（`LauncherLbH`、ListBox）: サムネイル非対応のまま**

ListBoxは標準で画像を表示できず、`WM_DRAWITEM`のオーナードロー自前実装が必須になる。ランチャーは「マウスサイドボタン→即クリック→即ペースト」の速度特化UIであり、プレースホルダーテキストで選択には十分。会議の収束どおり非対応と明示的に決定する。

## B. 統合アーキテクチャ

| 新設 | 種別 | 役割 |
|---|---|---|
| `HistThumbIL` | global（HIMAGELIST、初期値0） | 履歴タブ専用ImageList。セッション中1個だけ生きる唯一の永続GDIオブジェクト |
| `EnsureHistThumbIL()` | 関数 | ImageList遅延生成＋`SnipMgrHistLV.SetImageList(IL, 1)`でLVに紐付け |
| `DibBitsOffset(dib)` | 関数 | CF_DIBバッファ先頭からピクセルデータ先頭までのオフセット計算。非対応形式は0を返す（fail-closed） |
| `MakeHistThumb(v)` | 関数 | 画像要素1件のサムネイルを生成しImageListに追加、0始まりindexを返す（失敗-1）。HBITMAPは関数内で生成→即破棄 |
| `HistThumbIndex(v)` | 関数 | `v.thumbIdx`キャッシュ付きの`MakeHistThumb`ラッパ。1画像につき生成は1回だけ |
| 要素の追加プロパティ`thumbIdx` | データ | 画像要素オブジェクトに遅延で生える。ImageList内の0始まりindex（失敗時-1）。HBITMAPは絶対に持たせない |

**データフローとハンドル寿命**:

```
コピー時:  CF_DIB → Buffer即コピー（現行のまま、変更なし。ハンドル持ち越しゼロを維持）
表示時:    v.dib(Buffer) ──StretchDIBits──▶ 32×32 HBITMAP ──ImageList_Add(コピー)──▶ ImageList
                                            └── 直後にDeleteObject（生成関数を出る前に必ず死ぬ）
破棄:      ImageListはLV破棄時にcomctl32が自動破棄（LVS_SHAREIMAGELISTS非指定のため）。
           肥大時のみ明示的に作り直し＋ImageList_Destroy。
```

## C. 具体機構

### C-1. CF_DIBのオフセット計算（本設計の核心）

CF_DIBはBITMAPFILEHEADERなし、バッファ先頭＝BITMAPINFOHEADER。

```autohotkey
; CF_DIB(BITMAPFILEHEADERなし)先頭からピクセルデータまでのオフセット。0=描画非対応(fail-closed)
DibBitsOffset(dib) {
    biSize  := NumGet(dib,  0, "UInt")    ; 40=INFOHEADER / 108=V4 / 124=V5
    bitCnt  := NumGet(dib, 14, "UShort")  ; biBitCount
    comp    := NumGet(dib, 16, "UInt")    ; biCompression
    clrUsed := NumGet(dib, 32, "UInt")    ; biClrUsed
    if (comp != 0 && comp != 3)           ; BI_RGB(0)/BI_BITFIELDS(3)以外(RLE/JPEG/PNG)は描かない
        return 0
    entries := (bitCnt <= 8) ? (clrUsed ? clrUsed : 1 << bitCnt) : clrUsed
    masks := (comp = 3 && biSize = 40) ? 12 : 0   ; V4/V5ヘッダはマスクをヘッダ内に内包する
    off := biSize + masks + entries * 4
    return (off < dib.Size) ? off : 0
}
```

### C-2. サムネイル生成（採用API: StretchDIBits）

等倍のHBITMAPを一度も作らず、CF_DIBバッファから32×32のメモリDCへ`StretchDIBits`で直接縮小描画する。

```autohotkey
; 画像要素1件→ImageListへ追加し0始まりindexを返す。失敗は-1(プレースホルダー表示のまま)
MakeHistThumb(v) {
    global HistThumbIL
    static TW := 32, TH := 32, SRCCOPY := 0x00CC0020, HALFTONE := 4, WHITE_BRUSH := 0
    off := DibBitsOffset(v.dib)
    if (!off || v.w < 1 || v.h < 1)
        return -1
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcM := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    hBmp := DllCall("CreateCompatibleBitmap", "Ptr", hdcS, "Int", TW, "Int", TH, "Ptr")
    idx := -1
    if (hdcM && hBmp) {
        hOld := DllCall("SelectObject", "Ptr", hdcM, "Ptr", hBmp, "Ptr")
        rc := Buffer(16), NumPut("Int",0,rc,0), NumPut("Int",0,rc,4)
        NumPut("Int",TW,rc,8), NumPut("Int",TH,rc,12)
        DllCall("FillRect", "Ptr", hdcM, "Ptr", rc
            , "Ptr", DllCall("GetStockObject", "Int", WHITE_BRUSH, "Ptr"))
        scale := Min(TW / v.w, TH / v.h)               ; アスペクト比保持・中央寄せ
        dw := Max(1, Round(v.w * scale)), dh := Max(1, Round(v.h * scale))
        dx := (TW - dw) // 2, dy := (TH - dh) // 2
        DllCall("SetStretchBltMode", "Ptr", hdcM, "Int", HALFTONE)
        DllCall("SetBrushOrgEx", "Ptr", hdcM, "Int", 0, "Int", 0, "Ptr", 0)  ; HALFTONE後は必須(MSDN)
        DllCall("StretchDIBits", "Ptr", hdcM
            , "Int", dx, "Int", dy, "Int", dw, "Int", dh
            , "Int", 0, "Int", 0, "Int", v.w, "Int", v.h
            , "Ptr", v.dib.Ptr + off       ; pjBits: ヘッダ＋カラーテーブルの直後
            , "Ptr", v.dib                 ; pbmi:   CF_DIBは先頭がそのままBITMAPINFO
            , "UInt", 0                    ; DIB_RGB_COLORS
            , "UInt", SRCCOPY)
        DllCall("SelectObject", "Ptr", hdcM, "Ptr", hOld, "Ptr")  ; Add前に必ずDCから外す
        idx := DllCall("comctl32\ImageList_Add", "Ptr", HistThumbIL, "Ptr", hBmp, "Ptr", 0, "Int")
    }
    if hBmp
        DllCall("DeleteObject", "Ptr", hBmp)   ; ImageList_Addは内部コピーなので即破棄で安全
    if hdcM
        DllCall("DeleteDC", "Ptr", hdcM)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
    return idx
}

HistThumbIndex(v) {                        ; 生成は要素につき1回。以後はキャッシュ
    if !v.HasOwnProp("thumbIdx")
        v.thumbIdx := MakeHistThumb(v)
    return v.thumbIdx
}
```

### C-3. ImageListの構築と破棄

```autohotkey
global HistThumbIL := 0

EnsureHistThumbIL() {
    global HistThumbIL, SnipMgrHistLV
    if HistThumbIL
        return
    HistThumbIL := DllCall("comctl32\ImageList_Create"
        , "Int", 32, "Int", 32, "UInt", 0x20, "Int", 4, "Int", 4, "Ptr")  ; ILC_COLOR32
    SnipMgrHistLV.SetImageList(HistThumbIL, 1)   ; 1=Small: レポート表示で使われるリスト
}
```

呼び出し箇所: `ShowSnippetManager`内、`SnipMgrHistLV`生成直後に1行追加。

## D. 既存機能との関係

`SnipMgrHistRefresh`の変更は実質1行:

```autohotkey
        ; 変更前: SnipMgrHistLV.Add(, v.time, SubStr(disp, 1, 100))
        opt := (v.type = "image") ? "Icon" . (HistThumbIndex(v) + 1) : "Icon0"
        SnipMgrHistLV.Add(opt, v.time, SubStr(disp, 1, 100))
```

- AHKのアイコン番号は1始まり、`ImageList_Add`の戻りは0始まりなので`+1`。生成失敗（-1）は`Icon0`＝アイコンなしに自然に落ち、プレースホルダーテキスト表示が生き残る（fail-closed）。
- テキスト行の`Icon0`は省略不可。ImageList設定済みLVで無指定だと1番目のアイコンが全行に出る（AHK既知の仕様）。
- `SnipMgrHistRows`は要素参照ベースなので行↔要素対応・NoSort前提は無傷。
- `SnipMgrHistOnSelect`/`SnipMgrHistCopy`/`PushClipImage`/`SetClipboardImage`/`PasteImage`: 無改造。
- `LauncherLbH`（ListBox）: 非対応。`HistoryListItems()`も無改造。

## E. MVP

1. `DibBitsOffset`/`MakeHistThumb`/`HistThumbIndex`/`EnsureHistThumbIL`の4関数＋global1個を追加
2. `ShowSnippetManager`に`EnsureHistThumbIL()`を1行
3. `SnipMgrHistRefresh`のAdd行を2行に差し替え
4. 肥大時リビルド（G-3、リーク厳禁の制約対応としてMVPに含める）

## F. 捨てた案と理由

| 案 | 理由 |
|---|---|
| `CreateDIBitmap`（6引数正式版） | 技術的には可能だが、等倍HBITMAPを一度作ってから縮小する2段構えになり、GDIメモリ確保が増えるだけ。`StretchDIBits`直描きが上位互換 |
| `CreateDIBSection`＋`SetDIBits` | ピクセルへの直接アクセスが要る場合のAPI。表示専用では工程が増えるだけ |
| fast役の5引数`CreateDIBitmap`コード | 技術的誤り（引数不足・`CBM_INIT`欠落）。不採用 |
| ListBoxオーナードロー（ランチャー側サムネイル） | 複雑度が跳ね、既存の軽量設計と乖離。critic役2名の収束どおり不採用 |
| GDI+（`Gdip_*`） | 既存の設計方針（GDI+不使用・外部ライブラリ非依存）に反する |
| 要素に`hThumb`（HBITMAP）を持たせて使い回す | 「ハンドルを持ち越さない」思想に反し、`DeleteObject`漏れの地雷になる |
| キャプチャ時に先行生成 | クリップボード監視パスにGDI処理を混ぜると捕捉の即応性を損なう |
| サムネイルのディスクキャッシュ／大型プレビューペイン | 非永続の原則違反／過剰設計 |

## G. 地雷と回避策

1. **オフセット計算ミス（最大の地雷）**: `+14`（BITMAPFILEHEADER前提）を絶対に持ち込まない。C-1の式で網羅し、`off >= dib.Size`は0返しで弾く。
2. **RLE/JPEG/PNG圧縮DIB**: 実際のCF_DIBではほぼ出ないが、来たら`DibBitsOffset`が0を返しサムネイルなしに落ちる。クラッシュ経路なし。
3. **孤児アイコンによるImageList肥大**: 要素が間引かれてもアイコンはILに残る。`SnipMgrHistRefresh`冒頭に`ImageList_GetImageCount > 32`なら新ILを作って`SetImageList`で差し替え→旧ILを`ImageList_Destroy`→全画像要素の`thumbIdx`を`DeleteProp`。
4. **HBITMAP解放漏れ**: `MakeHistThumb`内で生成→Add→即`DeleteObject`の一方通行。AddするHBITMAPは事前にDCから`SelectObject`で外すこと。
5. **`Icon0`忘れ**: テキスト行に指定しないと1番目のサムネイルが全テキスト行に表示される。
6. **HALFTONEの作法**: `SetStretchBltMode(HALFTONE)`の後に`SetBrushOrgEx`を呼ぶ（MSDN明記）。
7. **トップダウンDIB（biHeight負）**: 最悪ケースでも上下反転サムネイルが出るだけでクラッシュ・リークには至らない。
8. **行高の変化**: ImageList設定でテキスト行も約36px化し表示行数が半減。仕様として受け入れ。
9. **NoSort前提の維持**: `NoSort NoSortHdr`を外さないこと。

## 行数見積もり

| 追加分 | 行数 |
|---|---|
| `DibBitsOffset` | 約13 |
| `MakeHistThumb` | 約36 |
| `HistThumbIndex`＋global宣言 | 約7 |
| `EnsureHistThumbIL`＋呼び出し1行 | 約9 |
| 肥大時リビルド | 約8 |
| `SnipMgrHistRefresh`差し替え差分 | ＋1 |
| 設計意図コメント | 約8 |
| **合計** | **約82行** |

**1186行 → 約1265〜1275行**。
