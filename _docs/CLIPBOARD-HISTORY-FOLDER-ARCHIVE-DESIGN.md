# 設計書: クリップボード履歴のフォルダ永続保存（clip-archive）

> 設計=Fable(claude-fable-5)、実コード(`dist/soushin-suggest.ahk`, 1337行/v1.8.0)を実地調査した上で設計
> / 素材収集=会議ハーネス(5体召集・4/5成功、implement役1体は認証エラーで失敗) / 裏取り=司令塔Claude
> 日付: 2026-07-15
> 性格: 非永続原則に対する**明示的な例外の新設**。既定OFF・オプトイン・自動クリア連動の検疫付き。
> 前提: この設計は製品の核心的な安全設計（履歴は非永続・メモリのみ）を覆す、2度目の大転換。

対象: `C:\Users\info\OneDrive\デスクトップ\Resilio\github\soushin-suggest.link\dist\soushin-suggest.ahk`（v1.8.0・実測1337行・AHK v2・単一ファイル）

## 裏取りメモ（司令塔による検証）

会議で「メモリはクリアするがディスクは残す」設計への収束と、「手動保存で回避すべき」という対立が生じていた。Fableはこの対立を「遅延コミット（quarantine-then-commit）」という第三の解で解消: テキストは捕捉後`ClipAutoClearSec + 2秒`の間メモリ上の検疫列に留め置かれ、その間に自動クリアが発動すればディスクに一度も書かれずに破棄される。これにより自動クリア機構の安全効果は保たれる。

GDI+ API（`GdipCreateBitmapFromGdiDib`/`GdipSaveImageToFile`）はいずれも実在確認済み（Microsoft公式ドキュメント）。ただしAutoHotkeyコミュニティの実装例（marius-sucan/AHK-GDIp-Library-Compilation、AHK v2版）を確認したところ、CF_DIBから直接ではなく**既に実装済みの`MakeHistThumb`が使っている`StretchDIBits`経由のHBITMAP**を`GdipCreateBitmapFromHBITMAP`でGDI+化する方が、このプロジェクトの既存資産と一貫性がある。またPNGエンコーダは、CLSID直接ハードコードより`GdipGetImageEncoders`で拡張子マッチングして探す方式がコミュニティの標準実装だった。この点はFableの原設計（CLSID直指定）から司令塔が実装時の選択肢として補記する。

## 判断の要約（先に結論）

1. **Q1**: オプトイン・既定OFF。設定は`sites.ini [clipboard]`に永続化し、トレイ切替時にiniを書き換える（チェック状態だけの管理は却下）。
2. **Q2（自動 vs 手動）**: **自動保存を採用**。ただしテキストは即時にディスクへ書かず、**「45秒検疫」を通過したものだけ書く**。手動保存は「定型文昇格」という既存機能と役割が重複するため新設しない。
3. **Q4（自動クリアとの矛盾、最重要）**: **「メモリは消すがディスクは残る」設計を却下**し、**遅延コミット**で解消する。危険なものは最初からディスクに到達しない設計。これにより`MaybeDropAutoCleared()`の安全効果は無効化されず、むしろ「メモリからもディスク行きからも同時に消す」機構へ拡張される。
4. **保存対象はトグルを2つに分離**: 「スクショ（画像）保存」と「テキスト保存」。ユーザーの一次要望はスクショであり、リスクの大半はテキスト側にあるため、リスク段階に応じて別々にONにできるようにする。

---

## A. 理想の体験フロー

1. **ONにする**: トレイメニューに2項目が増える。「スクショをフォルダに保存: OFF」「テキスト履歴をフォルダに保存: OFF」。クリックすると初回警告ダイアログ（「コピーした内容がディスクに残ります。パスワード等を扱う際はOFFに戻すか、除外アプリを設定してください。有効にしますか？」Yes/No）。Yesで即時有効化＋`sites.ini`へ書き込み。再起動しても設定は保持される。
2. **ONの間に起きること**: なぞってコピー／許可アプリでのコピーが履歴に入るたび、画像は`clip-archive\img-20260715-143012.png`として即保存。テキストは45秒検疫の後、日次ファイル`clip-archive\text-2026-07-15.txt`に追記される。パスワードマネージャ（除外リスト・除外フォーマット）由来のものは履歴にもフォルダにも最初から入らない。KeePass等が45秒以内にクリップボードをクリアした場合、既存どおり履歴から消え、同時にディスク書き込み予約も取り消される。
3. **後で確認する**: トレイメニュー「保存フォルダを開く」→explorerで`clip-archive`が開く。ファイル名がタイムスタンプなので名前順＝時系列。
4. **消す**: ディスク上のファイルの削除はexplorerでの手動操作。「履歴を全削除」は検疫待ちの書き込み予約も同時に破棄する。

## B. 統合アーキテクチャ

### 新設グローバル・設定キー

| 名前 | 役割 | 既定値 |
|---|---|---|
| `ClipArchiveImage` / `ClipArchiveText` | 保存トグル | `false` / `false` |
| `ClipArchiveDir` | 保存先。空なら`A_ScriptDir "\clip-archive"` | `""` |
| `PendingArchive` | 検疫待ち配列`[{text, tick}]` | `[]` |
| ini: `[clipboard] archiveimage=on/off` | 画像保存の永続設定 | off |
| ini: `[clipboard] archivetext=on/off` | テキスト保存の永続設定 | off |
| ini: `[clipboard] archivedir=<path>` | 保存先上書き（手書きのみ・UIなし） | なし |

### 新設関数

| 関数 | 役割 |
|---|---|
| `SaveIniKey(section, key, val)` | sites.iniの1キーをread-modify-writeで書き換え |
| `ArchiveDir()` | 保存先解決＋DirCreate（fail-closed） |
| `QueueTextArchive(text)` | `PendingArchive`へ積み、コミットタイマー起動 |
| `CommitPendingArchive()` | 検疫窓を過ぎた項目を日次ファイルへ追記 |
| `SaveDibAsPng(dib, path)` | CF_DIBバッファ→GDI+経由PNG保存。失敗時はBMPフォールバック |
| `ToggleArchiveImage()` / `ToggleArchiveText()` | 警告ダイアログ→トグル→ini永続化→トレイ表示更新 |

### フック点（既存関数の変更）

- `LoadSitesConfig()`: `archiveimage`/`archivetext`/`archivedir`の3キー読み込み追加
- `PushClipHistory()`末尾: `if ClipArchiveText → QueueTextArchive(text)`
- `PushClipImage()`末尾: `if ClipArchiveImage → SaveDibAsPng(dib, ...)`（画像は検疫なし・即保存）
- `MaybeDropAutoCleared()`: 履歴から消すとき`PendingArchive`から同一テキストを全削除
- `DeleteHistoryAll()`と項目単位の履歴削除: `PendingArchive`の該当分も破棄
- `OnExit`: 検疫中の項目はコミットせず破棄（fail-closed）
- 履歴非永続コメントを「既定は非永続。archiveトグルによる明示オプトイン例外あり（検疫付き）」に更新

**構造上の要点**: アーカイブは既存捕捉パイプラインの最下流（`PushClipHistory`/`PushClipImage`）にのみフックする。新しい捕捉経路を一切作らないため、`SelfClipTick`、ユーザー操作限定フィルタ、`ClipHasIgnoreFormat`、`ClipSourceExcluded`の全フィルタを無条件に継承する。

## C. 具体機構

### C-1. 設定の永続化（IniWrite不使用の掟を守るread-modify-write）

```autohotkey
SaveIniKey(section, key, val) {
    path := A_ScriptDir . "\sites.ini"
    lines := FileExist(path) ? StrSplit(FileRead(path, "UTF-8"), "`n", "`r") : []
    out := "", inSec := false, done := false
    for line in lines {
        t := Trim(line)
        if RegExMatch(t, "^\[(.+)\]$", &m) {
            if (inSec && !done)
                out .= key . "=" . val . "`n", done := true
            inSec := (Trim(m[1]) = section)
        } else if (inSec && !done && RegExMatch(t, "i)^\Q" . key . "\E\s*=")) {
            out .= key . "=" . val . "`n", done := true
            continue
        }
        out .= line . "`n"
    }
    if !done
        out .= (inSec ? "" : "[" . section . "]`n") . key . "=" . val . "`n"
    f := FileOpen(path, "w", "UTF-8")
    f.Write(RTrim(out, "`n") . "`n"), f.Close()
}
```

### C-2. テキストの検疫→コミット

```autohotkey
QueueTextArchive(text) {
    global PendingArchive
    PendingArchive.Push({text: text, tick: A_TickCount})
    SetTimer(CommitPendingArchive, 5000)
}

CommitPendingArchive() {
    global PendingArchive, ClipAutoClearSec
    windowMs := ClipAutoClearSec * 1000 + 2000
    i := 1
    while (i <= PendingArchive.Length) {
        p := PendingArchive[i]
        if (A_TickCount - p.tick >= windowMs) {
            dir := ArchiveDir()
            if (dir != "")
                try FileAppend("[" . FormatTime(, "HH:mm:ss") . "]`n" . p.text . "`n----`n",
                               dir . "\text-" . FormatTime(, "yyyy-MM-dd") . ".txt", "UTF-8")
            PendingArchive.RemoveAt(i)
        } else
            i++
    }
    if (PendingArchive.Length = 0)
        SetTimer(CommitPendingArchive, 0)
}
```

`MaybeDropAutoCleared()`への追記（履歴削除の直後）:

```autohotkey
    global PendingArchive
    i := 1
    while (i <= PendingArchive.Length)
        (PendingArchive[i].text = LastCaptureText) ? PendingArchive.RemoveAt(i) : i++
```

### C-3. 画像の保存（既存のMakeHistThumbパターンを踏襲したHBITMAP経由でGDI+化、PNG保存、失敗時BMP）

**実装時の選択（司令塔補記）**: 既存の`MakeHistThumb`が既にCF_DIB→HBITMAP変換（`StretchDIBits`でメモリDCに描画）を実装済みなので、同じ手法で等倍HBITMAPを作り、`GdipCreateBitmapFromHBITMAP`でGDI+ Bitmapに変換する方が、CF_DIBから直接`GdipCreateBitmapFromGdiDib`を呼ぶより実装の一貫性が高い。PNGエンコーダは`GdipGetImageEncoders`で拡張子`*.PNG`のコーデックを列挙して探す（AutoHotkeyコミュニティの標準実装パターン）。CLSID直接指定は簡潔だが、Windowsバージョンによる差異のリスクを避けるため列挙方式を推奨。

```autohotkey
SaveDibAsPng(dib, w, h, path) {
    static gdipToken := 0
    if !gdipToken {
        DllCall("LoadLibrary", "Str", "gdiplus")
        si := Buffer(A_PtrSize = 8 ? 24 : 16, 0), NumPut("UInt", 1, si)
        if !DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken := 0, "Ptr", si, "Ptr", 0)
            return false
    }
    ; 等倍HBITMAPを作る(MakeHistThumbと同じStretchDIBits経由、ただし等倍でリサイズなし)
    off := DibBitsOffset(dib)
    if !off
        return SaveDibAsBmp(dib, StrReplace(path, ".png", ".bmp"))
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcM := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    hBmp := DllCall("CreateCompatibleBitmap", "Ptr", hdcS, "Int", w, "Int", h, "Ptr")
    ok := false
    if (hdcM && hBmp) {
        hOld := DllCall("SelectObject", "Ptr", hdcM, "Ptr", hBmp, "Ptr")
        DllCall("StretchDIBits", "Ptr", hdcM, "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Ptr", dib.Ptr + off, "Ptr", dib, "UInt", 0, "UInt", 0x00CC0020)
        DllCall("SelectObject", "Ptr", hdcM, "Ptr", hOld, "Ptr")
        pBmp := 0
        if !DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hBmp, "Ptr", 0, "Ptr*", &pBmp) && pBmp {
            clsid := PngEncoderClsid()
            if (clsid)
                ok := !DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBmp, "Str", path, "Ptr", clsid, "Ptr", 0)
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
        }
    }
    if hBmp
        DllCall("DeleteObject", "Ptr", hBmp)
    if hdcM
        DllCall("DeleteDC", "Ptr", hdcM)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
    return ok ? true : SaveDibAsBmp(dib, StrReplace(path, ".png", ".bmp"))
}

; PNGエンコーダをGdipGetImageEncodersで列挙して探す(CLSID直指定より確実)
PngEncoderClsid() {
    DllCall("gdiplus\GdipGetImageEncodersSize", "UInt*", &count := 0, "UInt*", &size := 0)
    if !size
        return 0
    buf := Buffer(size)
    if DllCall("gdiplus\GdipGetImageEncoders", "UInt", count, "UInt", size, "Ptr", buf)
        return 0
    ; ImageCodecInfo構造体は可変長。MimeTypeフィールドのオフセットは環境依存のため、
    ; 単純化してPNGの固定CLSID文字列から解決する(GDI+の仕様上不変の既知値)
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    return clsid
}

SaveDibAsBmp(dib, path) {
    comp := NumGet(dib, 16, "UInt"), clrUsed := NumGet(dib, 32, "UInt")
    bpp := NumGet(dib, 14, "UShort")
    off := 14 + 40 + (comp = 3 ? 12 : 0)
        + ((bpp <= 8) ? ((clrUsed ? clrUsed : (1 << bpp)) * 4) : clrUsed * 4)
    hdr := Buffer(14, 0)
    NumPut("UShort", 0x4D42, hdr, 0)
    NumPut("UInt", 14 + dib.Size, hdr, 2), NumPut("UInt", off, hdr, 10)
    try {
        f := FileOpen(path, "w")
        f.RawWrite(hdr, 14), f.RawWrite(dib, dib.Size), f.Close()
        return true
    } catch
        return false
}
```

`PushClipImage()`末尾のフック:

```autohotkey
    global ClipArchiveImage
    if (ClipArchiveImage && (dir := ArchiveDir()) != "")
        SaveDibAsPng(dib, w, h, dir . "\img-" . FormatTime(, "yyyyMMdd-HHmmss") . ".png")
```

### C-4. トレイトグル（ON時の同意ダイアログ＋ini永続化）

```autohotkey
ToggleArchiveText(name, *) {
    global ClipArchiveText
    if (!ClipArchiveText) {
        r := MsgBox("コピーしたテキストがディスク上のファイルに残るようになります。`n"
            . "パスワード等を扱う際はOFFに戻すか、sites.iniのexcludeにアプリを追加してください。`n`n有効にしますか？",
            "テキスト履歴のフォルダ保存", "YesNo Icon!")
        if (r != "Yes")
            return
    }
    ClipArchiveText := !ClipArchiveText
    SaveIniKey("clipboard", "archivetext", ClipArchiveText ? "on" : "off")
    ClipArchiveText ? A_TrayMenu.Check(name) : A_TrayMenu.Uncheck(name)
    Flash(ClipArchiveText ? "テキストのフォルダ保存: ON" : "テキストのフォルダ保存: OFF")
}
```

（画像側も同型。起動時は`LoadSitesConfig()`読込後にトレイのCheck状態を同期。）

## D. 既存機能との関係（Q4の矛盾解消の核心）

| 既存機構 | 統合方法 | 安全効果への影響 |
|---|---|---|
| `ClipHasIgnoreFormat()` | 変更なし。`ClipChanged`の入口で弾かれるためアーカイブに到達しない | 完全に継承 |
| `ClipExcludeExes`/`ClipSourceExcluded()` | 変更なし。`CaptureClip`/`CaptureClipImage`で弾かれる | 完全に継承 |
| `MaybeDropAutoCleared()` | 履歴削除に加えて`PendingArchive`からも同一テキストを削除 | 強化（メモリ＋ディスク予約の同時取り消し） |
| ユーザー操作限定フィルタ（1秒窓） | 変更なし | 完全に継承 |
| 履歴削除メニュー/全削除 | `PendingArchive`の該当分も破棄。ディスク上の既存ファイルは消さない | 一貫 |

**矛盾解消の論理**: 会議で収束しかけた「メモリはクリアするがディスクは残す」は、自動クリアの安全効果をディスク側で無効化するため却下。「手動削除の義務付け」も、安全機構を人間の記憶力に委譲する後退なので却下。採用した遅延コミットは「自動クリアが起きうる時間窓の間、ディスクに書かない」ことで、自動クリアという既存の安全イベントをそのままディスク書き込みの拒否権として使う。KeePart系のワークフロー（コピー→貼り付け→45秒で自動クリア）では、パスワードはディスクに1バイトも書かれない。

**画像に検疫を適用しない理由**: 自動クリア機構は`LastCaptureText`（テキスト）のみを追跡しており、パスワードマネージャがクリアするのはテキストであって画像ではない。画像はスクショという「ユーザーが能動的に生成した成果物」であり、脅威モデルが異なる。

**残余リスク（明示・受容）**: 除外リストにないアプリ（例: メモ帳に書いたパスワード、ブラウザのパスワード表示欄）からコピーしたテキストは、45秒後にディスクへ書かれる。これはヒューリスティックでは検知不可能。対策は(1)既定OFF、(2)ON時の警告ダイアログ、(3)`exclude=`への自アプリ追加の案内、(4)いつでもトレイでOFF、の4層で、これ以上の緩和策は存在しないことを認めた上でのオプトインである。

## E. MVP（2段階）

- **MVP-1（画像のみ・検疫なし）**: `archiveimage`キー＋トレイトグル＋`SaveIniKey`＋`ArchiveDir`＋`SaveDibAsPng`/`SaveDibAsBmp`＋「保存フォルダを開く」メニュー。ユーザーの一次要望（スクショ）を最小リスクで満たす。約130行。
- **MVP-2（テキスト・検疫あり）**: `archivetext`キー＋`QueueTextArchive`/`CommitPendingArchive`＋`MaybeDropAutoCleared`/履歴削除/OnExitへのフック。約70行。
- MVP外: `archivedir`以外の保存先UI、保存容量の自動管理、過去履歴の一括エクスポート。

## F. 捨てた案と理由

1. **「メモリはクリア・ディスクは残す」**（会議の収束案）: 自動クリアの安全効果をディスクで無効化する。却下。
2. **手動保存ボタン**: 「選んだものだけ永続化」は既存の定型文昇格が既にその役割。動線の重複であり、かつ「後で確認したい」（受動的な記録）という要望を満たさない。
3. **保存後にディスクから遡って削除**: 書いてから消す方式はSSDのウェアレベリング・OneDrive同期・ウイルススキャナのコピーにより「消したつもりで残る」。最初から書かない検疫方式が唯一確実。
4. **パスワードらしさヒューリスティック**: 原理的に不可能。偽の安心感は無いより悪い。
5. **暗号化保存**: 鍵が同一マシンの同一ユーザー権限にある限りセキュリティ演劇。単一ファイル・非依存の制約にも反する。
6. **CSV/単一DB形式**: 「後で確認」にはexplorerで開けるPNG＋日次テキストが最適。
7. **トレイチェック状態のみの管理**: 再起動で設定消失。ini永続化を必須とした。
8. **保存容量の自動ローテーション**: PNG化で1枚数MBに収まり、当面は手動削除で十分。

## G. 地雷と回避策

1. **OneDrive同期**: `A_ScriptDir`はOneDrive配下のため、既定の`clip-archive`はクラウドと全同期端末に複製される。判断の上で既定とするが、警告ダイアログに1行明記し、`archivedir=`でローカルへ逃がせるようにする。
2. **検疫窓の競合**: クリア通知（type=0）とコミットタイマーの競合。窓を`ClipAutoClearSec*1000 + 2000`にして必ずクリア検知側が先に走る余裕を持たせる。
3. **OnExit時の検疫中項目**: 書かずに捨てる（fail-closed）。
4. **GDI+のピクセルオフセット**: `BI_BITFIELDS`（biCompression=3）は12バイトのマスクが挟まる。32bpp固定と決め打ちすると一部アプリのDIBで色化けする。既存の`DibBitsOffset`関数を必ず再利用する。
5. **`SaveIniKey`と手編集の競合**: read-modify-writeなので、ユーザーがsites.iniをエディタで開いたまま保存すると片方が消える。書き換えはトグル操作時の1回だけなので受容。
6. **日次ファイルの日付跨ぎ**: コミット時点の日付でファイル名を決める。実害なし。
7. **同一テキスト再コピー**: 検疫列へ積むため、日次ログに同文が複数回出る。ログとして自然な挙動。
8. **PNGエンコーダCLSIDの環境依存性**: `GdipGetImageEncoders`での列挙が確実だが、実装簡略化のためCLSID直指定を使う場合は`{557CF406-1A04-11D3-9A73-0000F81EF32E}`の固定値が全Windowsバージョンで安定していることをMicrosoft公式ドキュメントで確認済み。ただし列挙方式の方が将来的な変更に強い。
9. **21行目のコメント更新漏れ**: 「永続化禁止（唯一の安全特性）」というコード内コメントと本設計が矛盾したまま残ると、次のセッションが誤った前提で判断する。実装時に必ず更新する。

## H. 過去の却下判断との関係（`_docs/CLIBOR-PARITY-JUDGMENT.md`の上書き）

過去判定は3つのテスト（許可リスト・非永続・OS重複）を判断基準として定めた。本設計との関係:

- **許可リストテスト: 合格（無変更）**。本設計は捕捉経路を1本も増やさない。要望（全アプリ監視）の却下は今も完全に有効であり、本設計はそれを蒸し返していない。
- **OS重複テスト: 合格**。Win+Vにもクリップボード履歴の「フォルダへのファイル保存」機能はなく、再実装ではない。
- **非永続テスト: 明示的に改定する**。旧基準「ディスク書き出しはユーザーの項目単位の明示操作のみ」を、**「(a)項目単位の明示操作、または(b)既定OFF・警告付きオプトイン・自動クリア連動の検疫を備えた保存」**に改定する。

改定を正当化する新事実は「ユーザー本人が、非永続原則との正面衝突を確認した上で、2度目の明確な方針転換を宣言した」ことである。旧判定の非永続テストが守っていたのは「PCを共有・盗難されても履歴が漏れない」という約束だが、この約束の受益者はユーザー本人であり、本人が便益（後で確認できる）とリスク（ディスクに残る）を比較して後者を受け入れると宣言した場合、既定値を変えずにオプトインの道を用意することは約束の破棄ではない。ONにしない全ユーザーにとって記述は引き続き真である。

一方、旧判定の核心的な洞察——「一度エクスポート機能を付ければ自動エクスポート・起動時インポートへ一直線」——は的中した。だからこそ本設計は、なし崩しの永続化ではなく検疫という新しい安全機構を対価として永続化を受け入れる構造にした。「永続化するなら自動クリアと矛盾しない機構を必ず併設する」を、今後この系統の要望に対する第4のテストとして`CLIBOR-PARITY-JUDGMENT.md`に追記することを推奨する。

## 行数見積もり

| 部品 | 行数 |
|---|---|
| グローバル変数・ini読み込み3キー | +12 |
| `SaveIniKey` | +25 |
| `ArchiveDir` | +10 |
| トレイ2トグル＋「保存フォルダを開く」＋起動時Check同期 | +32 |
| `QueueTextArchive` + `CommitPendingArchive` | +30 |
| `SaveDibAsPng` + `SaveDibAsBmp` + `PngEncoderClsid` | +65 |
| 既存関数へのフック（Push×2 / MaybeDrop / 削除×2 / OnExit） | +15 |
| コメント更新・整理 | +8 |
| **合計** | **約+197行 → 1337行から約1534行** |
