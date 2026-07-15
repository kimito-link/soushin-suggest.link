# 設計書: クイックペーストランチャー履歴タブへの実サムネイル表示

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 1280行/v1.7.0)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・4/5成功、implement役1体は認証エラーで失敗) / 裏取り=司令塔Claude
> 日付: 2026-07-15
> 前提: [`CLIPBOARD-IMAGE-THUMBNAIL-DESIGN.md`](CLIPBOARD-IMAGE-THUMBNAIL-DESIGN.md)（「定型文の管理」側サムネイル・実装済み）の対象範囲拡大

対象: `C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link\dist\soushin-suggest.ahk`（v1.7.0, 1280行, AHK v2）

## 裏取りメモ（司令塔による検証）

会議は「ListBox維持＋オーナードロー」vs「ListView置換」で対立し解消しなかった。Fableは実コードを実測し、会議が懸念した「LB_*依存コードへの影響」は`LauncherItemUnderMouse`のわずか3行に留まると確認、ListView置換の方が優位と判断した。

`LVM_HITTEST`(0x1012)、`LVM_GETITEMRECT`(0x100E)、`LVS_SHAREIMAGELISTS`(0x0040)、`LVHITTESTINFO`構造体レイアウトはMicrosoft公式ドキュメントで裏取り済み、いずれも正確。

Fableの核心的な工夫は、司令塔が提示した「thumbIdx衝突問題」に対し、**ImageListを2つ作らず単一グローバルILを両ウィンドウで共有し、`LVS_SHAREIMAGELISTS`スタイルでランチャーのGUI破棄からILを保護する**という解を導出したこと。これにより会議の両陣営が懸念した「使い捨てGUIパターンとImageList寿命管理の相性」問題が構造的に解消される。

## 結論の要約

| 項目 | 判定 |
|---|---|
| ListBox vs ListView | **ListView置換**（履歴タブのみ。定型文タブのListBoxは変更しない） |
| ImageList管理 | **単一グローバルIL(`HistThumbIL`)を両ウィンドウで共有**。`LVS_SHAREIMAGELISTS`でGUI破棄から保護 |
| サムネイル生成ロジック | 既存の`MakeHistThumb`/`HistThumbIndex`/`DibBitsOffset`を**無変更で共用** |
| thumbIdx | 両ウィンドウで共有（別々に持たない） |
| 見積もり行数 | 約+50行（1280行 → 約1330行） |

---

## A. 理想の体験フロー

1. XButton1長押し / `^#v`でランチャーが従来と同じ体感速度で開く。
2. 履歴タブの各行は従来通り`1 テキスト先頭58文字…`の形式。画像履歴の行だけ、行頭に32×32の実サムネイルが付く。テキスト行はアイコンなし。両ウィンドウは同一ImageListを参照するため、文字通り同じビットマップが出る。
3. クリックで即ペースト、数字キー1–9,0で即ペースト、ホバーで全文ToolTip、右クリックでメニュー — すべて従来通り。変わるのは画像行に絵が付くことと、行高が約21px→約36pxになりウィンドウが縦に伸びることだけ。
4. ランチャーを閉じて開き直しても、サムネイルの再生成は起きない（`v.thumbIdx`キャッシュが生きている）。

## B. 統合アーキテクチャ

### 判断理由

1. 「LB_*依存コードへの影響が大きい」という会議の懸念は過大評価。LB_*直叩きは`LauncherItemUnderMouse`のわずか3行だけ。数字キー選択（`LauncherPickKey`→`PasteHistoryAt(n)`）はコントロールに一切触れず配列indexを直接渡す設計なので影響ゼロ。
2. オーナードローは「新規に描画レイヤーを自作する」ことが本質的リスク。選択ハイライト色・フォント選択・省略記号・背景色との整合を全部GDIで手書きする約100行は最も壊れやすい種類のコードになる。
3. 決定打: 出荷済み・実戦テスト済みのサムネイル機構はImageList前提で、ListViewなら描画コード追加ゼロで再利用できる。

### 新設・変更する関数とデータ構造

| 項目 | 種別 | 内容 |
|---|---|---|
| `LauncherLvH` | 改名 | `LauncherLbH`→改名（ListBoxでなくなるため） |
| `FillLauncherHistoryLV(lv)` | 新設 | `HistoryListItems()`を置換。Icon付きでAddする |
| `LauncherLVItemUnderMouse(lv)` | 新設 | LVM_HITTESTによるマウス直下行の特定 |
| `LauncherLVItemHeight(lv)` | 新設 | LVM_GETITEMRECTで実行高を測る |
| `LauncherHistSelect(lv,row,selected)` | 新設 | ItemSelect→ペースト（右クリックガード付き） |
| `EnsureHistThumbIL()` | 責務縮小 | ILの生成だけにする。`SetImageList`は呼び出し元へ移す |
| `RebuildHistThumbILIfBloated()` | 変更 | 再構築後、生存中の各ビューへ再アサイン＋再充填 |

## C. 具体機構

### C-1. LB_* → LVM_* 対応表

| 現行（ListBox） | 移行先（ListView） | 備考 |
|---|---|---|
| `LB_GETTOPINDEX` (0x18E) | 不要 | LVM_HITTESTがスクロール位置を内部で吸収 |
| `LB_GETITEMHEIGHT` (0x1A1) | `LVM_GETITEMRECT` (0x100E) | 行高は「サイズ合わせ」にのみ使用 |
| `LB_GETCOUNT` (0x18B) | `lv.GetCount()` | 組み込みメソッドで足りる |
| （座標→index手計算） | `LVM_HITTEST` (0x1012) + LVHITTESTINFO | 1メッセージで完結 |
| `.Value` + Changeイベント | `ItemSelect`イベントの`row`引数 | AHK v2組み込み |

### C-2. ShowLauncher の変更部

```autohotkey
    ; 履歴タブ: ListView化(1列・ヘッダなし)。+0x40=LVS_SHAREIMAGELISTS が生命線:
    ; これが無いとGui.Destroy()のたびに共有ImageList(HistThumbIL)が道連れ破壊される。
    RebuildHistThumbILIfBloated()             ; 充填前に肥大チェック(SnipMgrHistRefreshと同じ順序)
    LauncherLvH := LauncherGui.Add("ListView"
        , "w440 r" . rows . " -Hdr -Multi NoSort +0x40 BackgroundF0F6FF", ["履歴"])
    LauncherLvH.Opt("+LV0x10000")             ; LVS_EX_DOUBLEBUFFER: 再描画のチラつき防止
    EnsureHistThumbIL()
    LauncherLvH.SetImageList(HistThumbIL, 1)  ; 1=Small(レポート表示で使われる側)
    LauncherLvH.ModifyCol(1, 416)             ; 440 - スクロールバー/枠ぶん
    FillLauncherHistoryLV(LauncherLvH)
    LauncherLvH.OnEvent("ItemSelect", LauncherHistSelect)
```

`UseTab()`で抜けた直後、高さ補正を挿入:

```autohotkey
    ; r行指定はアイコン行高(約36px)を知らずに文字高で計算されるため、実測して合わせる。
    if (ih := LauncherLVItemHeight(LauncherLvH)) {
        listH := ih * rows + 6
        LauncherLvH.GetPos(&lvX, &lvY, , &lvH0)
        LauncherLvH.Move(, , , listH)
        LauncherLbS.Move(, , , listH)         ; 定型文側も同じ箱サイズに(タブ切替で高さが揃う)
        LauncherTab.GetPos(&tX, &tY, , &tH0)
        LauncherTab.Move(, , , tH0 + (listH - lvH0))
    }
```

### C-3. 新設関数（完全なコード）

```autohotkey
; ShowLauncherとRefreshLauncherHistoryで共用。HistoryListItems()の後継。
; Icon0省略不可(省略すると全行に1枚目が出る既知の仕様。SnipMgrHistRefreshと同じ)
FillLauncherHistoryLV(lv) {
    global ClipHistory
    lv.Opt("-Redraw")
    lv.Delete()
    for i, v in ClipHistory {
        s := RegExReplace(v.text, "\s+", " ")
        txt := (i <= 10 ? Mod(i, 10) . " " : "   ") . (StrLen(s) > 58 ? SubStr(s, 1, 58) . "…" : s)
        lv.Add((v.type = "image") ? "Icon" . (HistThumbIndex(v) + 1) : "Icon0", txt)
    }
    lv.Opt("+Redraw")
}

; マウス直下のListView行番号(1始まり)。行外は0。LB版(LauncherItemUnderMouse)のLV版。
LauncherLVItemUnderMouse(lv) {
    MouseGetPos &mx, &my
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " . lv.Hwnd)
    if (mx < cx || mx >= cx + cw || my < cy || my >= cy + ch)
        return 0
    ht := Buffer(24, 0)                       ; LVHITTESTINFO {POINT, flags, iItem, iSubItem, iGroup}
    NumPut("Int", mx - cx, ht, 0), NumPut("Int", my - cy, ht, 4)
    return SendMessage(0x1012, 0, ht.Ptr, , "ahk_id " . lv.Hwnd) + 1   ; LVM_HITTEST: -1(なし)→0
}

; 1行目の外接矩形から実際の行高を得る。行ゼロ時は0(fail-closed: リサイズしないだけ)
LauncherLVItemHeight(lv) {
    rc := Buffer(16, 0)                       ; rc.left=0 (LVIR_BOUNDS)
    if !SendMessage(0x100E, 0, rc.Ptr, , "ahk_id " . lv.Hwnd)   ; LVM_GETITEMRECT, wParam=item0
        return 0
    return NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
}

; クリック(選択)→即ペースト。旧Changeイベントの後継。
LauncherHistSelect(lv, row, selected) {
    if (!selected || GetKeyState("RButton", "P"))   ; 選択解除時と、右クリック由来の選択では発火させない
        return
    PasteHistoryAt(row)
}
```

### C-4. サムネイル機構側のリファクタ

```autohotkey
EnsureHistThumbIL() {                         ; ILの生成のみ。アサインは各呼び出し元の責務に変更
    global HistThumbIL
    if HistThumbIL
        return
    HistThumbIL := DllCall("comctl32\ImageList_Create"
        , "Int", 32, "Int", 32, "UInt", 0x20, "Int", 4, "Int", 4, "Ptr")
}

RebuildHistThumbILIfBloated() {
    global HistThumbIL, ClipHistory, SnipMgrHistLV, LauncherGui, LauncherLvH
    if (!HistThumbIL || DllCall("comctl32\ImageList_GetImageCount", "Ptr", HistThumbIL, "Int") <= 32)
        return
    old := HistThumbIL
    HistThumbIL := 0
    for v in ClipHistory
        if (v.type = "image")
            v.DeleteProp("thumbIdx")
    EnsureHistThumbIL()
    if IsObject(SnipMgrHistLV)                ; 未生成なら0
        SnipMgrHistLV.SetImageList(HistThumbIL, 1)
    if IsObject(LauncherGui) {                ; 理論上の競合窓も塞ぐ
        LauncherLvH.SetImageList(HistThumbIL, 1)
        FillLauncherHistoryLV(LauncherLvH)    ; 旧indexを持つ行を貼り替え
    }
    DllCall("comctl32\ImageList_Destroy", "Ptr", old)   ; 再アサイン完了後に旧ILを破棄(この順序を守る)
}
```

SnipMgr側の変更は2行のみ: ListView生成オプションに`+0x40`を追加、506行を`EnsureHistThumbIL(), SnipMgrHistLV.SetImageList(HistThumbIL, 1)`に変更。

### C-5. 既存関数の書き換え内容

- `RefreshLauncherHistory()`: `LauncherLbH.Delete()/Add(HistoryListItems())` → `FillLauncherHistoryLV(LauncherLvH)`1行に。
- `LauncherWatchHover()`: `LauncherItemUnderMouse(LauncherLbH)` → `LauncherLVItemUnderMouse(LauncherLvH)`。定型文側は既存LB版のまま。
- `LauncherContextMenu()`: 同上の関数名差し替えのみ。
- `HistoryListItems()`は削除。

## D. 既存機能との関係

| 機能 | 影響 | 対応 |
|---|---|---|
| `LauncherPickKey`（数字キー） | 影響なし | `PasteHistoryAt(n)`直呼びでコントロール非依存 |
| `LauncherWatchHover` | 関数名1箇所差し替え | ToolTipの内容・120msタイマー・座標判定の流儀は不変 |
| `LauncherItemUnderMouse` | 残す（定型文ListBox用） | 履歴用にLV版を新設して並置 |
| `LauncherContextMenu` | 関数名1箇所差し替え＋右クリックガード | ListViewは右クリックで行選択が走るため、ガードなしだと右クリック=即ペースト暴発 |
| SnipMgr側サムネイル関数群 | `MakeHistThumb`/`HistThumbIndex`/`DibBitsOffset`は無変更で共用 | 変更はEnsureHistThumbILの責務縮小とRebuildの再アサイン処理のみ |
| `thumbIdx` | 両ウィンドウで共有（単一IL・単一index空間） | HBITMAPは従来通り関数スコープ外に出ない |

## E. MVP

C節の全部がMVP（これ以上削ると壊れる最小単位）:
1. ListView化＋`+0x40`＋共有IL接続＋Icon付き充填（コア）
2. LV版ヒットテスト（ホバー/右クリックの現行動作維持に必須）
3. 右クリックガード（暴発防止に必須）
4. 行高実測リサイズ（欠くと最終行が欠けてスクロールバーが常時出る＝ブランド毀損）
5. EnsureHistThumbIL/Rebuildの責務整理（欠くとSnipMgr未起動時に例外）

MVPに含めないもの: 定型文タブのListView化、ホバー時の拡大画像プレビュー、サムネイルサイズ設定、ランチャーのシングルトン化。

## F. 捨てた案と理由

1. **ListBox維持＋オーナードロー**: 却下。約100行のGDI自作になり、ListViewがネイティブでやることの劣化再実装。`SetWindowSubclass`はそもそも不要（WM_DRAWITEMは親ウィンドウに届くので`OnMessage(0x2B,...)`で受かる）。
2. **gpt-oss-120bのコード例**: 結論（ListView）は採用するが、コードはv1構文で使用不可。「WM_DRAWITEM頻発による描画負荷」という論拠も30件規模では成立しない。
3. **ランチャー専用ImageListの新設**: 却下。thumbIdx衝突・サムネイルメモリ二重化・GUI破棄との同期問題を自ら作り出す案。`LVS_SHAREIMAGELISTS`＋単一グローバルILなら問題クラスごと消える。
4. **ランチャーのシングルトン化**: 却下。サムネイル1機能のためのリスクとして不釣り合い。
5. **`v.thumbIdx`をウィンドウ別に持つ**: 却下。IL共有により不要。

## G. 地雷と回避策

1. **【最重要】`LVS_SHAREIMAGELISTS`(+0x40)の付け忘れ**: `Gui.Destroy()`のたびに共有ILがOSに破棄され、SnipMgr側サムネイル全滅＋全`thumbIdx`がダングリング化。検証手順: ランチャー開閉→定型文の管理の履歴タブでサムネイル健在を確認、を必ず受け入れ試験に入れる。
2. **EnsureHistThumbILの現実装が`SetImageList`を内包**: SnipMgr未起動でランチャーを先に開くと`0.SetImageList`で実行時エラー。責務分離が前提条件。
3. **Rebuild時の旧index残留**: IL再構築後に旧`Icon<n>`のまま残った行は別画像・空白を表示する。Rebuild内で生存ビューを再アサイン＋再充填し、破棄は最後。
4. **右クリック→ItemSelect→即ペースト暴発**: ListView固有。RButton物理状態ガードで遮断。ItemSelectは行Delete時に`selected=false`で発火するので`!selected`ガードも必須。
5. **`Icon0`省略**: 省略すると全行に1枚目のサムネイルが出る既知の仕様。テキスト行にも必ず`Icon0`。
6. **r行指定と実行高の乖離**: `r10`は文字高で計算されるため32pxアイコン設定後は約半分しか見えない。実測リサイズで解消。Tab3は後からのMoveに自動追従しないので、Tab高さも手動更新。
7. **メモリリークの総括**: 新規に増えるGDIリソースはゼロ。ILはプロセスで唯一・上限は既存Rebuild（32枚）が管理・GUI破棄と完全独立。
8. **理論上の競合**: 通常はCheckLauncherFocus(150ms)が先にランチャーを閉じるため起きないが、`IsObject(LauncherGui)`分岐で起きても正しく動く。

## 行数見積もり

| 変更 | 増減 |
|---|---|
| 新設4関数 | +38 |
| ShowLauncher内の差し替え＋高さ補正ブロック | +14 |
| Rebuild/Ensure責務整理 | +8 |
| SnipMgr側 | +1 |
| HistoryListItems削除 | −9 |
| RefreshLauncherHistory簡素化 | −2 |
| **純増** | **約+50行** |

**1280行 → 約1330行（±15行）**。
