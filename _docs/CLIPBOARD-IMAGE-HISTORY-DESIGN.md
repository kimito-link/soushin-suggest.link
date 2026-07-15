# 設計書: クリップボード履歴の画像対応（soushin-suggest.ahk）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 1046行/v1.5.0)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・4/5成功、implement役1体は認証エラーで失敗) / 裏取り=司令塔Claude
> 日付: 2026-07-15
> 前提: 「Windows標準のWin+Vクリップボード履歴と同じ体験」というユーザー要望への回答

対象: `C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link\dist\soushin-suggest.ahk`（現1046行 / AHK v2 / 単一ファイル・外部ライブラリ非依存）

## 裏取りメモ（司令塔による検証）

実地調査により、AutoHotkey公式ドキュメントで`OnClipboardChange`のtype引数（0=クリア、1=テキスト、2=画像を含む非テキスト全般）を確認済み。また「画像取得から再設定まで一時ファイル書き出しは不要、メモリ内（HGLOBAL/HBITMAPハンドル）だけで完結できる」ことも技術調査済み。

会議で複数メンバーが挙げた`Gdip_CreateBitmapFromClipboard`等は、tariqporter/Gdip.ahkという**外部ライブラリの関数名**でありこのプロジェクトには存在しないため不採用。gpt-oss-120b(critic)の「ハンドル寿命は保証されないため一時ファイル化が必須」という主張も、Win32 APIの一般的な挙動と完全には整合しないとして「事実誤認」と一次判定していたが、Fableの設計はこれを**半分正しい**と再評価し、「一時ファイルは不要だが、ハンドルの長期保持も安全ではない」という第三の結論（開いている間に即座にメモリコピーする）を導いた。これは司令塔の当初判定より精緻であり、採用する。

## 設計の核となる判断

履歴には HBITMAP や HGLOBAL の「ハンドル」を保持しない。**CF_DIB のバイト列を AHK の `Buffer` オブジェクトにコピーして保持する**。`GetClipboardData` が返すハンドルはクリップボード側の所有物であり、次にどこかのアプリが `EmptyClipboard` した瞬間に無効化されうる。解決策は一時ファイルではなく、開いている間の即時メモリコピー。この方式ならGDIハンドルを一切保持しないため`DeleteObject`の帳簿管理が不要になり、履歴から要素が消えればAHKの参照カウントがBufferを自動解放する。

---

## A. 理想の体験フロー

1. **コピー**: ユーザーがPrintScreen / Win+Shift+S / ブラウザの「画像をコピー」等で画像をクリップボードに載せる。既存のテキストと同じく無音で履歴に入る。
2. **履歴に見える**: ランチャーの履歴タブに、テキスト行と混在して新しい順に `1 📷 画像 1920×1080 (8.3MB)` のようなプレースホルダー行が出る。ホバーすると既存のToolTipに「2026/07/15(水) 14:03:22 にコピー」＋同じプレースホルダーが出る（既存コード無改修で実現）。
3. **選択**: クリックまたは数字キーで選ぶと、その画像がクリップボードに再設定され、直前のアクティブウィンドウに`^v`が送られる。ペイント/Word/Slack/ブラウザ等、CF_DIBを受けるアプリにそのまま貼り付く。
4. **定型文の管理→履歴タブ**でも同じプレースホルダー行が並び、選択すると全文プレビュー欄に「画像 1920×1080 — ダブルクリックまたはボタンで再コピー」と出て、「クリップボードへコピー」で再設定できる。
5. 非永続の原則どおり、スクリプト終了で全画像は消える。ディスクには一切書かない。

## B. 統合アーキテクチャ

### データ構造

```
テキスト要素: {type: "text",  text: <本文>,                          time: <日時文字列>}
画像要素    : {type: "image", text: "📷 画像 1920×1080 (8.3MB)",     time: <日時文字列>,
               dib: <Buffer>, w: 1920, h: 1080}
```

画像要素にも`text`プロパティを持たせ、そこに表示用プレースホルダー文字列を格納する。`v.text`を読むだけの既存コード（`HistoryListItems`/`LauncherWatchHover`/`SnipMgrHistRefresh`の検索・表示/`RunnablePathFrom`）は一行も変更せずに画像対応になる。`RunnablePathFrom("📷 画像 …")`はパス正規表現に落ちて空を返す（fail-closed）ので誤爆もない。

### 新設する関数（すべてUser32/GDI32/Kernel32の範囲。GDI+不使用）

| 関数 | 役割 |
|---|---|
| `ClipOpen()` | `OpenClipboard(A_ScriptHwnd)`をリトライ付きで開く（5回×20ms） |
| `GetClipDib()` | CF_DIB(8)を`GlobalLock`→`Buffer`へ即コピー→`GlobalUnlock`→`CloseClipboard`。Bufferを返す |
| `CaptureClipImage()` | 画像版`CaptureClip`。ユーザー操作フィルタ・除外元判定・サイズ上限を通して`PushClipImage` |
| `PushClipImage(dib, w, h)` | プレースホルダー文字列を組んで先頭挿入。画像専用件数上限と全体30件上限を適用 |
| `SetClipboardImage(dib)` | `GlobalAlloc`→コピー→`EmptyClipboard`→`SetClipboardData(CF_DIB)`。成否を返す |
| `PasteImage(dib)` | `PasteText`の画像版 |

### 変更する既存箇所

| 箇所 | 変更 |
|---|---|
| `ClipChanged` | `type=2`の分岐を追加 |
| `PushClipHistory` | 生成する要素に`type:"text"`を付与。重複判定に`v.type="text"`ガード追加 |
| `PasteHistoryAt` | `v.type="image"`なら`PasteImage(v.dib)` |
| `SnipMgrHistCopy` | 画像行なら`SetClipboardImage` |
| `SnipMgrHistOnSelect` | 画像行ならプレビュー欄にメタ情報文字列 |
| `LauncherContextMenu` | 画像行では「定型文に登録」を出さない |
| `PromoteHistoryAt` | 冒頭に画像ガード（メニュー非表示と二重の防御） |
| `LoadSitesConfig`の`[clipboard]`節 | `imagemax=`/`imagemaxmb=`の2キー追加 |
| `XButton1` | `Send("#{PrintScreen}")`の直前に`LastUserCopyTick := A_TickCount` |
| 新規ホットキー | `~PrintScreen`/`~!PrintScreen`で`LastUserCopyTick`を記録 |

### 新設グローバル

```ahk
global ClipImageMax := 5          ; 画像専用の件数上限（[clipboard] imagemax=）
global ClipImageMaxBytes := 36 * 1024 * 1024   ; 4Kスクショ(約33MB)まで許容（imagemaxmb=）
```

## C. 具体機構

### C-1. 監視の入口

```ahk
    if (!ClipWatchOn)
        return
    if ClipHasIgnoreFormat()                  ; パスワードマネージャ除外はテキスト/画像共通
        return
    if (type = 1)
        SetTimer(CaptureClip, -120)
    else if (type = 2 && DllCall("IsClipboardFormatAvailable", "UInt", 8))  ; CF_DIB=8
        SetTimer(CaptureClipImage, -120)      ; デバウンスも既存と同一パターン
```

### C-2. 取得（開いている間に即コピー、finallyで必ず閉じる）

```ahk
ClipOpen() {
    Loop 5 {
        if DllCall("OpenClipboard", "Ptr", A_ScriptHwnd)
            return true
        Sleep 20
    }
    return false                              ; 諦め=捕捉しないだけ(fail-closed)
}

GetClipDib() {
    if !ClipOpen()
        return 0
    buf := 0
    try {
        hDib := DllCall("GetClipboardData", "UInt", 8, "Ptr")
        if hDib {
            p := DllCall("GlobalLock", "Ptr", hDib, "Ptr")
            if p {
                sz := DllCall("GlobalSize", "Ptr", hDib, "UPtr")
                buf := Buffer(sz)
                DllCall("RtlMoveMemory", "Ptr", buf, "Ptr", p, "UPtr", sz)  ; ハンドルは保持せず即コピー
                DllCall("GlobalUnlock", "Ptr", hDib)
            }
        }
    } finally DllCall("CloseClipboard")
    return buf
}

CaptureClipImage() {
    global LastUserCopyTick, LastLButtonUpTick, ClipUserWindowMs, ClipImageMaxBytes
    now := A_TickCount
    if (now - LastUserCopyTick > ClipUserWindowMs) && (now - LastLButtonUpTick > ClipUserWindowMs)
        return
    if ClipSourceExcluded()
        return
    dib := GetClipDib()
    if (!dib || dib.Size < 40 || dib.Size > ClipImageMaxBytes)
        return
    w := NumGet(dib, 4, "Int"), h := Abs(NumGet(dib, 8, "Int"))
    PushClipImage(dib, w, h)
}
```

### C-3. 履歴への追加（件数上限）

```ahk
PushClipImage(dib, w, h) {
    global ClipHistory, ClipHistoryMax, ClipImageMax
    label := "📷 画像 " . w . "×" . h . " (" . Round(dib.Size / 1048576, 1) . "MB)"
    ClipHistory.InsertAt(1, {type: "image", text: label, dib: dib, w: w, h: h, time: NowWithWeekday()})
    n := 0
    for i, v in ClipHistory
        if (v.type = "image" && ++n > ClipImageMax) {
            ClipHistory.RemoveAt(i)
            break
        }
    while (ClipHistory.Length > ClipHistoryMax)
        ClipHistory.Pop()
}
```

### C-4. 再設定と貼り付け

```ahk
SetClipboardImage(dib) {
    global SelfClipTick
    hMem := DllCall("GlobalAlloc", "UInt", 0x2, "UPtr", dib.Size, "Ptr")  ; GMEM_MOVEABLE
    if !hMem
        return false
    p := DllCall("GlobalLock", "Ptr", hMem, "Ptr")
    DllCall("RtlMoveMemory", "Ptr", p, "Ptr", dib, "UPtr", dib.Size)
    DllCall("GlobalUnlock", "Ptr", hMem)
    if !ClipOpen() {
        DllCall("GlobalFree", "Ptr", hMem)
        return false
    }
    ok := false
    try {
        SelfClipTick := A_TickCount           ; EmptyClipboardのtype=0通知より前に立てる
        DllCall("EmptyClipboard")
        ok := DllCall("SetClipboardData", "UInt", 8, "Ptr", hMem, "Ptr") != 0
    } finally DllCall("CloseClipboard")
    if !ok
        DllCall("GlobalFree", "Ptr", hMem)    ; 成功時は所有権がOSに移るため触らない
    return ok
}

PasteImage(dib) {
    global LauncherTarget
    if !SetClipboardImage(dib) {
        Flash("画像を再設定できませんでした", 1500)
        return
    }
    if (LauncherTarget && WinExist("ahk_id " . LauncherTarget))
        WinActivate("ahk_id " . LauncherTarget)
    Sleep 150
    Send("^v")
}
```

```ahk
PasteHistoryAt(idx) {
    global ClipHistory
    if (idx < 1 || idx > ClipHistory.Length)
        return
    v := ClipHistory[idx]
    CloseLauncher()
    (v.type = "image") ? PasteImage(v.dib) : PasteText(v.text)
}
```

### C-5. ユーザー操作フィルタへの追記（PrintScreen系）

```ahk
~PrintScreen::
~!PrintScreen:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}
```

`XButton1`短押しは自スクリプトの`Send("#{PrintScreen}")`がフックに乗らないため、Send直前に`LastUserCopyTick := A_TickCount`を1行追加する。

## D. 既存機能との関係

- **`ClipHistory`配列**: `type`付き統一配列。既存要素の生成箇所は`PushClipHistory`1箇所だけなので`type: "text"`を足すだけで全要素が型を持つ。重複判定ループは`if (v.type = "text" && v.text = text)`にする。
- **`LauncherLbH`（ListBox）**: 無改修。`HistoryListItems`は`v.text`を読むだけで、プレースホルダーが58字以内に収まるためそのまま並ぶ。
- **`SnipMgrHistLV`（ListView）**: 一覧表示・検索は無改修（検索欄に「画像」と打つと画像だけに絞れる副産物つき）。変更は選択時プレビューと「クリップボードへコピー」の2分岐のみ。サムネイル描画はしない。
- **`ClipHasIgnoreFormat`/`ClipSourceExcluded`**: そのまま画像経路でも呼ぶ。どちらもクリップボードを開かない判定なので順序の制約なし。
- **`MaybeDropAutoCleared`（自動クリア検知）**: テキスト専用のまま変更しない。
- **`PromoteHistoryAt`/`LauncherContextMenu`**: 画像行では「定型文に登録」をメニューに出さず、関数冒頭にもガード。snippets.iniには一切触れない。
- **`sites.ini [clipboard]`**: `imagemax=5`/`imagemaxmb=36`の2キーを既存の`max=`/`autoclear=`と同じパース分岐に追加。

## E. MVP

**入れるもの**: C-1〜C-5の全部＋Dのアクション系分岐。「画像コピー→プレースホルダーで履歴に載る→選ぶと貼り付く」の一本道と、安全装置（ユーザー操作フィルタ・除外元・件数/サイズ上限・fail-closedなクリップボード開閉）。

**MVPから外すもの**:
- サムネイル/プレビュー画像の表示（プレースホルダー文字列のみ）
- 画像の重複排除
- 自動クリア検知の画像対応

## F. 捨てた案と理由

1. **`Gdip_CreateBitmapFromClipboard`等**: 外部ライブラリの関数名でありプロジェクトに存在しない。GDI+自体を不採用（エンコードもサムネイルもしないため出番がない）。
2. **一時ファイル書き出し**: ファイル化は非永続の原則を破る上に、書込先・削除タイミング・クラッシュ時残骸という新しい問題を持ち込む。
3. **HBITMAP/HGLOBALハンドルをそのまま履歴に保持**: `GetClipboardData`の戻りハンドルはクリップボード所有で、次の`EmptyClipboard`で無効化されうるため不採用。
4. **ListView/ListBoxへのサムネイル直接描画**: プレースホルダー＋寸法表示で識別性は十分。過剰設計として不採用。
5. **メモリ内PNG圧縮（GDI+ IStream）でRAM節約**: 圧縮率は良いが+100行級。件数×サイズ上限で十分足りる。
6. **CF_DIBV5(17)での取得**: 貼り付け先の対応がまちまちで挙動検証コストが高い。CF_DIBはWindowsがCF_BITMAP/DIBV5から自動合成してくれる最大公約数フォーマット。

## G. 地雷と回避策

1. **ハンドル寿命**: `GetClipboardData`の戻りハンドルはクリップボードが所有し、アプリは解放してはならず、`CloseClipboard`後の継続利用に保証はない。→ 開いている間に`RtlMoveMemory`で自前Bufferへ全コピーし、ハンドルは一切持ち越さない。
2. **`CloseClipboard`の取りこぼし**: 閉じ忘れるとシステム全体のコピペが止まる最悪級の事故。→ `OpenClipboard`成功後は必ず`try { … } finally DllCall("CloseClipboard")`で囲む。
3. **コールバック内での`OpenClipboard`**: `OnClipboardChange`の通知中に開くと通知元とデッドロックしうる。→ 既存の`SetTimer(…, -120)`デバウンスがコールバック外へ逃がす構造をそのまま使う。
4. **`OpenClipboard`の競合失敗**: 他アプリが握っていると失敗する。→ `ClipOpen()`で5回×20msリトライ、それでも駄目なら黙って捕捉を諦める（fail-closed）。
5. **`SetClipboardData`の所有権移転**: 成功したらhMemはOSの物 — `GlobalFree`すると二重解放でクラッシュ。失敗時だけ自分で解放。
6. **自己書き込みループ**: `SetClipboardImage`の`EmptyClipboard`（type=0）と`SetClipboardData`（type=2）で`ClipChanged`が2回発火する。→ `SelfClipTick`をEmptyより前に立てる。
7. **メモリ増加**: 既定上限で最悪5件×36MB=180MB、実用上（フルHDスクショ≈8MB）は40MB程度。Bufferは履歴から抜けた瞬間に参照カウントで解放されるため滞留しない。手動解放コードはゼロ。
8. **ユーザー操作フィルタと画像の相性**: PrintScreenは`~^c`群で拾えないため専用フックを追加。Win+Shift+Sはドラッグ解放が既存`~LButton up`の`LastLButtonUpTick`更新で自然に通る。
9. **`GlobalLock`失敗・壊れたDIB**: `p=0`ならbuf=0のまま返す。`dib.Size < 40`（BITMAPINFOHEADER未満）も捨てる。
10. **64bit/32bit差**: サイズ系は`"UPtr"`、ハンドル系は`"Ptr"`で統一。

## 行数見積もり

| 項目 | 増加行 |
|---|---|
| 新設関数6本 | 約95 |
| 既存関数の分岐追加 | 約30 |
| PrintScreenフック＋XButton1の1行＋グローバル2つ＋ini2キー | 約15 |
| 設計意図コメント | 約20 |
| **合計** | **約160行** |

**1046行 → 約1200〜1210行**。
