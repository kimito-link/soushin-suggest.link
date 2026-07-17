#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"
; コンパイル後もWindows 10/11のトースト通知はAutoHotkey本体のAUMID("AutoHotkey.AutoHotkey")に
; 紐づく既定アイコン(緑のH)を出す。自前のAUMIDを明示登録することで通知側にも自分のアイデンティティを持たせる。
DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "wstr", "KimitoLink.SoushinSuggest")
; .ahk直接実行(開発時・検証プローブ)ではexeのアイコンリソースが存在せずTraySetIconのリソース指定が失敗し、
; それ以降の自動実行(OnClipboardChange登録等)まで巻き込んで壊れることを実測で確認したためコンパイル時のみ実行。
if A_IsCompiled
    TraySetIcon(A_ScriptFullPath, 1)   ; トレイアイコンの明示指定(リソース1番=Ahk2Exeのメインアイコン)
; ============================================================
;  送信サジェスト / soushin-suggest.link
;  なぞってコピー・右クリック長押しで送信・サイドボタンでスクショ&クイックペースト
;  Windows 10/11 対応・買い切り・追加課金なし
; ============================================================
;  左クリック（ドラッグ）  -> 選択範囲を自動コピー（全アプリ）
;  右クリック長押し(0.35s) -> サイトに合った送信キーを送る（短押しは通常の右クリック）
;  サイドボタン(戻る)      -> クイックペースト（全アプリ）
;  サイドボタン(進む)      -> 短押し=全画面スクショ / 長押し=範囲指定スクショ
;  ミドルクリック           -> Git Bash を前面へ（無ければ起動）
;  Ctrl+Win+C              -> なぞってコピーのON/OFF切り替え
;  Ctrl+Win+V              -> クイックペーストを開く（マウスなしでも呼び出せる）
;  対応アプリ・送信ルールは sites.ini、定型文は snippets.ini で編集できます（同梱）。
;  トレイのアイコンを右クリック -> Suspend Hotkeys / Exit

global AppVersion := "1.14.0"
global CopyOnSelect := true, dragX := 0, dragY := 0, dragT := 0
global SitesConfig := Map()
global SiteRules := []
global ClipHistory := [], ClipHistoryMax := 30   ; {text,time}の配列・メモリのみ
; 既定は非永続。archiveimage/archivetextトグルによる明示オプトイン例外あり(検疫付き・既定OFF)。
; 経緯は_docs/CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md参照
global LongPressSec := 0.35     ; sites.ini [general] longpress= で上書き可
global LauncherGui := 0, LauncherTarget := 0, LauncherTab := 0, Snippets := [], LauncherDragBar := 0, LauncherLvH := 0, LauncherLbS := 0, LauncherHoverLast := ""
global LauncherSearchEdit := 0                ; 検索ボックス(履歴/定型文タブ共通、内容で絞り込み)
global LauncherHistFilterMap := []            ; 表示行(1始まり) → ClipHistoryの実インデックス。フィルタ無しなら1:1
global LauncherSnipFilterMap := []            ; 表示行(1始まり) → Snippetsの実インデックス。フィルタ無しなら1:1
global ClipWatchOn := true                ; トレイから一時停止可
global LastUserCopyTick := 0              ; ^c/^x/^Ins・なぞってコピー送信の時刻
global LastLButtonUpTick := 0             ; 右クリックメニュー「コピー」等のクリック由来を救う
global SelfClipTick := 0                  ; 自分がA_Clipboardへ書いた時刻(監視除外)
global LastCaptureText := "", LastCaptureTick := 0   ; 自動クリア検知用
global ClipUserWindowMs := 1000           ; ユーザー操作限定フィルタの窓(iniに出さない・固定)
global ClipAutoClearSec := 45, ClipMaxLen := 100000
global ClipExcludeExes := Map("keepass.exe",1, "keepassxc.exe",1, "1password.exe",1, "bitwarden.exe",1)
global ClipImageMax := 5, ClipImageMaxBytes := 36 * 1024 * 1024   ; 画像専用の件数上限・4Kスクショ程度まで許容
global ClipImageMinPx := 32                ; 幅/高さがこれ未満の極小画像(ノイズ)は履歴に記録しない
global ClipArchiveImage := false, ClipArchiveText := false, ClipArchiveDir := ""   ; 既定OFF・オプトイン
global PendingArchive := []                ; テキストの検疫待ち配列 {text, tick}(45秒+2秒で確定保存)

; --- 診断計器: メモリのみ・プロセス終了で消える(非永続原則と同居)。書込入口はDiagBumpだけ。
; 経緯・設計判断は_docs/SELF-DIAGNOSTIC-INSTRUMENTATION-DESIGN.md参照 ---
global ClipDiag := Map()
global ClipDiagStartTick := A_TickCount

DiagBump(key) {
    global ClipDiag
    if ClipDiag.Has(key)
        ClipDiag[key].n += 1, ClipDiag[key].last := A_TickCount
    else
        ClipDiag[key] := {n: 1, last: A_TickCount}
}

Flash(msg, ms := 1500) {
    ToolTip(msg)
    SetTimer () => ToolTip(), -ms
}

; メモリ上の計器をJSON文字列化してクリップボードへ。ディスクには一切書かない。
; 履歴本文・クリップボード内容は絶対に含めない(カウンターと設定値のみ)。
CopyDiagnostics(*) {
    global SelfClipTick
    txt := BuildDiagText()               ; ★書き込みの前にスナップショット(診断コピー自身のselfSuppressを混入させない)
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

; --- load sites.ini (per-app rules + [sites] title-keyword rules) ---
; IniReadは使わない: 非ASCIIキーをUTF-16 LE以外で誤読する既知の問題があり、[sites]は日本語キーワードを扱うため
LoadSitesConfig() {
    global SitesConfig, SiteRules, LongPressSec, ClipWatchOn, ClipHistoryMax, ClipAutoClearSec, ClipExcludeExes, ClipImageMax, ClipImageMaxBytes, ClipArchiveImage, ClipArchiveText, ClipArchiveDir
    SitesConfig := Map()
    SiteRules := []
    iniPath := A_ScriptDir . "\sites.ini"
    if !FileExist(iniPath) {
        ; fallback defaults if sites.ini is missing/deleted
        for exe in ["chrome.exe", "msedge.exe", "firefox.exe", "brave.exe",
                    "ChatGPT.exe", "claude.exe", "Chatwork.exe"]
            SitesConfig[exe] := "enter"
        SiteRules.Push({keyword: "ココナラ", mode: "manual"},
                       {keyword: "coconala", mode: "manual"})
        return
    }
    section := ""
    for line in StrSplit(FileRead(iniPath, "UTF-8"), "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        if RegExMatch(line, "^\[(.+)\]$", &m) {
            section := Trim(m[1])
            continue
        }
        eq := InStr(line, "=")
        if !eq
            continue
        key := Trim(SubStr(line, 1, eq - 1))
        val := Trim(SubStr(line, eq + 1))
        if (p := InStr(val, ";"))          ; strip inline comment
            val := Trim(SubStr(val, 1, p - 1))
        if (section = "sites")
            SiteRules.Push({keyword: key, mode: StrLower(val)})
        else if (section = "general" && StrLower(key) = "longpress" && IsNumber(val))
            LongPressSec := val + 0
        else if (section = "clipboard") {
            k := StrLower(key)
            if (k = "watch")
                ClipWatchOn := (StrLower(val) != "off")
            else if (k = "max" && IsNumber(val))
                ClipHistoryMax := Integer(val)
            else if (k = "autoclear" && IsNumber(val))
                ClipAutoClearSec := val + 0
            else if (k = "imagemax" && IsNumber(val))
                ClipImageMax := Integer(val)
            else if (k = "imagemaxmb" && IsNumber(val))
                ClipImageMaxBytes := Integer(val) * 1024 * 1024
            else if (k = "archiveimage")
                ClipArchiveImage := (StrLower(val) = "on")
            else if (k = "archivetext")
                ClipArchiveText := (StrLower(val) = "on")
            else if (k = "archivedir")
                ClipArchiveDir := val
            else if (k = "exclude")
                for e in StrSplit(val, ",")
                    if (Trim(e) != "")
                        ClipExcludeExes[StrLower(Trim(e))] := 1
        } else if (section != "" && StrLower(key) = "send")
            SitesConfig[section] := StrLower(val)
    }
}

; --- resolve send rule: title keyword ([sites]) > per-app default > '' ---
; Title-keyword match is layered on top of the process-name default so a
; misdetection can only ever fall back to "show the manual-send tooltip" —
; never trigger an unwanted auto-send.
CurrentSendMode() {
    global SitesConfig, SiteRules
    exe := ""
    try exe := WinGetProcessName("A")
    if (exe = "" || !SitesConfig.Has(exe))
        return ""
    title := ""
    try title := WinGetTitle("A")
    for rule in SiteRules {
        if (rule.keyword != "" && InStr(title, rule.keyword))  ; InStr is case-insensitive by default
            return rule.mode
    }
    return SitesConfig[exe]
}

CopyOnSelectApp() => CurrentSendMode() != ""

; --- スタートアップ登録 (shell:startup にショートカットを作成/削除) ---
StartupShortcutPath() => A_Startup . "\soushin-suggest.lnk"
IsStartupRegistered() => FileExist(StartupShortcutPath()) ? true : false

; --- スタートメニューへのAUMID付きショートカット登録 ---
; Windows 10/11のトースト通知(TrayTip)は、コンパイル済みexeがAutoHotkey本体のAUMID
; ("AutoHotkey.AutoHotkey")にフォールバックすると既定のAutoHotkeyアイコンを出す。
; SetCurrentProcessExplicitAppUserModelID単体では通知アイコンは解決されず、
; 「スタートメニューに、そのAUMIDを持つショートカットが存在する」ことが必要
; (Microsoft Learn: How to enable desktop toast notifications through an AppUserModelID)。
; 実装はAutoHotkey v2公式インストーラーのUX\inc\CreateAppShortcut.ahkを踏襲。
global AppAumid := "KimitoLink.SoushinSuggest"
StartMenuShortcutPath() => A_AppData . "\Microsoft\Windows\Start Menu\Programs\送信サジェスト.lnk"

; 既存ショートカットのIconLocationが想定と違えば再作成する(過去の試行錯誤で不完全なショートカットが
; 残っている環境の自己修復も兼ねる。FileExistだけの判定だと一度不完全な状態で作られると直らない)。
EnsureStartMenuShortcut() {
    global AppAumid
    if !A_IsCompiled   ; .ahk直接実行(開発時・検証プローブ)ではexeにアイコンが埋め込まれていないためスキップ
        return
    path := StartMenuShortcutPath()
    wantIcon := A_ScriptFullPath . ",0"
    if FileExist(path) {
        try {
            sh := ComObject("WScript.Shell")
            lnk := sh.CreateShortcut(path)
            if (lnk.IconLocation = wantIcon)
                return
        } catch {
            ; 読み取り失敗時は下のtryで再作成を試みる
        }
    }
    try CreateAppShortcut(path, {target: A_ScriptFullPath, desc: "送信サジェスト", aumid: AppAumid, icon: A_ScriptFullPath, iconIndex: 0})
}

; AutoHotkey v2公式インストーラー(AutoHotkeyUX/inc/CreateAppShortcut.ahk)からの移植。
; IShellLinkでショートカット本体を組み立て、IPropertyStore経由でSystem.AppUserModel.IDを埋め込む。
CreateAppShortcut(linkFile, p) {
    lnk := ComObject("{00021401-0000-0000-C000-000000000046}", "{000214F9-0000-0000-C000-000000000046}")   ; CLSID/IID_IShellLink
    ComCall(20, lnk, "wstr", p.target)                                          ; SetPath
    ComCall(11, lnk, "wstr", p.HasProp("args") ? p.args : "")                   ; SetArguments
    ComCall(7, lnk, "wstr", p.desc)                                             ; SetDescription
    if p.HasProp("icon")
        ComCall(17, lnk, "wstr", p.icon, "int", p.HasProp("iconIndex") ? p.iconIndex : 0)   ; SetIconLocation

    props := ComObjQuery(lnk, "{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")         ; IPropertyStore
    pkeyAumid := AhkPropKey("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}", 5)        ; PKEY_AppUserModel_ID
    AhkPropSet(props, pkeyAumid, p.aumid)

    pf := ComObjQuery(lnk, "{0000010B-0000-0000-C000-000000000046}")           ; IPersistFile
    ComCall(6, pf, "wstr", linkFile, "int", true)                              ; Save
}

AhkPropSet(props, key, value) {
    propvar := Buffer(24, 0)
    propref := ComValue(0x400C, propvar.Ptr)   ; VT_BYREF|VT_VARIANT。この後 propref[] への代入でBSTRとして値が書き込まれる
    propref[] := String(value)
    ComCall(6, props, "ptr", key, "ptr", propvar)   ; IPropertyStore::SetValue
    propref[] := 0
}

AhkPropKey(sguid, propID) {
    pk := Buffer(20)
    DllCall("ole32\IIDFromString", "wstr", sguid, "ptr", pk, "hresult")
    NumPut("int", propID, pk, 16)
    return pk
}

EnableStartup() {
    try FileCreateShortcut(A_ScriptFullPath, StartupShortcutPath(), A_ScriptDir), Flash("次回のWindows起動時から自動で立ち上がります", 1800)
    catch as e
        Flash("スタートアップ登録に失敗しました: " . e.Message, 2000)
}

DisableStartup() {
    try FileDelete(StartupShortcutPath()), Flash("自動起動を解除しました", 1800)
}

ActivateGitBash() {
    if WinExist("ahk_exe mintty.exe") {
        WinActivate
        return
    }
    for p in ["C:\Program Files\Git\git-bash.exe",
              "C:\Program Files (x86)\Git\git-bash.exe",
              A_AppData . "\..\Local\Programs\Git\git-bash.exe"] {
        if FileExist(p) {
            Run '"' p '"'
            return
        }
    }
    Flash("Git Bash が見つかりませんでした", 1500)
}

; ユーザー発のコピー操作を時刻だけ記録する(~でキー自体は素通し)
~^c::
~^x::
~^Ins:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}

; --- なぞってコピー: ドラッグ解放でCtrl+Cを送る（履歴追加はClipChangedに一本化） ---
~LButton:: {
    global dragX, dragY, dragT
    MouseGetPos &dragX, &dragY
    dragT := A_TickCount
}

~LButton up:: {
    global CopyOnSelect, dragX, dragY, dragT, LastLButtonUpTick, LastUserCopyTick
    LastLButtonUpTick := A_TickCount          ; コンテキストメニュー由来のコピーを救う(全アプリ対象)
    if !CopyOnSelect
        return
    MouseGetPos &x, &y
    dt := A_TickCount - dragT
    if (Abs(x - dragX) < 30 && Abs(y - dragY) < 30) || dt < 150 || dt > 15000
        return
    prev := A_Clipboard
    LastUserCopyTick := A_TickCount           ; フィルタを確実に通す
    Send("^c")
    Sleep 150
    if (A_Clipboard != "" && A_Clipboard != prev)
        Flash("コピーしました", 800)          ; 履歴追加はClipChangedに一本化
}

PushClipHistory(text) {
    global ClipHistory, ClipHistoryMax, ClipArchiveText
    DiagBump("pushText")
    for i, v in ClipHistory
        if (v.type = "text" && v.text = text) {   ; 画像のプレースホルダー文字列と偶然一致しても誤爆しない
            ClipHistory.RemoveAt(i)   ; 重複は先頭へ昇格（時刻も更新される）
            break
        }
    ClipHistory.InsertAt(1, {type: "text", text: text, time: NowWithWeekday()})
    while (ClipHistory.Length > ClipHistoryMax)
        ClipHistory.Pop()
    ; テキストは検疫キューへ。自動クリアで消えれば一度もディスクに書かれない(D節の核心)
    if ClipArchiveText
        QueueTextArchive(text)
    RefreshLauncherHistory()   ; ランチャーが開いたままの間もタブ数字・リストをライブ反映
}

; FormatTimeの ddd はロケール依存で日本語曜日が出ないことがあるため自前マッピング
NowWithWeekday() {
    static wd := ["日", "月", "火", "水", "木", "金", "土"]
    return FormatTime(, "yyyy/MM/dd") . "(" . wd[FormatTime(, "WDay")] . ") " . FormatTime(, "HH:mm:ss")
}

^#c:: {
    global CopyOnSelect
    CopyOnSelect := !CopyOnSelect
    Flash(CopyOnSelect ? "なぞってコピー: ON" : "なぞってコピー: OFF", 1200)
}

; --- 右クリック長押し = 送信サジェスト ---
; 対応アプリ・Git Bash のみで有効。短押しは通常の右クリックのまま。
#HotIf CopyOnSelectApp() || WinActive("ahk_exe mintty.exe")
$RButton:: {
    global LongPressSec
    if KeyWait("RButton", "T" . LongPressSec) {
        Send("{Click Right}")
        return
    }
    KeyWait("RButton")
    if WinActive("ahk_exe mintty.exe") {
        Send("{Enter}")
        return
    }
    mode := CurrentSendMode()
    if (mode = "manual")
        Flash("このサイトは送信ボタンを押してください（自動送信非対応）", 1800)
    else
        Send("{Enter}")
}
#HotIf

; --- ミドルクリックで Git Bash を前面へ ---
#HotIf !WinActive("ahk_exe mintty.exe")
MButton::ActivateGitBash()
#HotIf
^#t::ActivateGitBash()
^#v::ShowLauncher()   ; キーボードからクイックペースト（Clibor風・アプリを問わず有効）

; --- サイドボタン(戻る): 押すとすぐクイックペースト（全アプリ・長押し判定なし） ---
XButton1::ShowLauncher()

; --- サイドボタン(進む): 短押し=カーソルのモニタを全画面スクショ / 長押し=範囲指定スクショ ---
XButton2:: {
    global LongPressSec, LastUserCopyTick
    if KeyWait("XButton2", "T" . LongPressSec) {
        LastUserCopyTick := A_TickCount        ; 自スクリプト発のSendはフックに乗らないため明示記録
        if !CaptureMonitorAtCursorToClipboard()
            Send("#{PrintScreen}")             ; 自前キャプチャ失敗時は従来のWin+PrintScreenへフォールバック
        return
    }
    KeyWait("XButton2")
    LastUserCopyTick := A_TickCount            ; Win+Shift+Sのクリップボードコピーもユーザー操作として認める
    Send("#+s")                                ; Windows標準の切り取り&スケッチ(範囲指定)
}

; PrintScreen(全画面/Alt+PrintScreenでアクティブウィンドウ)によるコピーもユーザー操作として認める
~PrintScreen::
~!PrintScreen:: {
    global LastUserCopyTick
    LastUserCopyTick := A_TickCount
}

; --- snippets.ini: ラベル=本文（\n で改行、run:パス で起動）---
; sites.iniパーサと違い、インラインコメント(;)は剥がさない — 本文に ; が入りうるため。
; IniRead は使わない（非ASCIIキー誤読の既知の罠。ラベルは日本語になる）。
LoadSnippets(path := "") {
    items := []
    if (path = "")
        path := A_ScriptDir . "\snippets.ini"
    if !FileExist(path)
        return items
    for line in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "[")
            continue
        eq := InStr(line, "=")
        if !eq
            continue
        label := Trim(SubStr(line, 1, eq - 1))
        val := Trim(SubStr(line, eq + 1))
        if (label != "" && val != "")
            items.Push({label: label, value: StrReplace(val, "\n", "`n")})
    }
    return items
}

EditSnippetsFile(*) {
    path := A_ScriptDir . "\snippets.ini"
    if !FileExist(path)
        try FileAppend("; ラベル=本文（\n で改行、run:パス で起動）`n", path, "UTF-8")
    Run('notepad.exe "' . path . '"')
}

; RFC4180準拠の1行CSVパース（ダブルクォート囲み・""エスケープ・カンマ/改行含む値に対応）
; 呼び出し側はセル境界をまたぐ複数行フィールドがある場合を考慮し、行単位ではなく全文を渡すこと
ParseCsv(text) {
    rows := [], row := [], field := "", inQuotes := false
    i := 1, len := StrLen(text)
    while (i <= len) {
        c := SubStr(text, i, 1)
        if inQuotes {
            if (c = '"') {
                if (SubStr(text, i + 1, 1) = '"')
                    field .= '"', i++
                else
                    inQuotes := false
            } else
                field .= c
        } else {
            if (c = '"')
                inQuotes := true
            else if (c = ",") {
                row.Push(field), field := ""
            } else if (c = "`r") {
                ; 無視（`n側で改行確定）
            } else if (c = "`n") {
                row.Push(field), field := ""
                rows.Push(row), row := []
            } else
                field .= c
        }
        i++
    }
    if (field != "" || row.Length)
        row.Push(field), rows.Push(row)
    return rows
}

; CSV(label,body の2列)を読み、LoadSnippetsと同じ {label,value} 配列形式で返す
LoadSnippetsCsv(path) {
    items := []
    text := FileRead(path, "UTF-8")
    text := RegExReplace(text, "^\x{FEFF}")   ; BOM除去
    rows := ParseCsv(text)
    for idx, row in rows {
        if (idx = 1 && row.Length >= 2 && Trim(row[1]) = "label" && Trim(row[2]) = "body")
            continue   ; ヘッダー行はスキップ
        if (row.Length < 2)
            continue
        label := Trim(row[1]), val := row[2]
        if (label != "" && val != "")
            items.Push({label: label, value: val})
    }
    return items
}

; CliborエクスポートCSV(4列, CP932, BOMなし)の判定＋変換。非該当ならfalseを返しLoadSnippetsCsvへフォールバック。
; existing: 既存ラベル→本文 のMap（clearFirst時は空Mapを渡す）。冪等性(同一本文の再取込スキップ)判定に使う。
; 詳細は_docs/CLIBOR-CSV-IMPORT-DESIGN.md参照
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

    ; パス1: 非空グループの種類数を数える（2種類以上のときのみラベルにプレフィックスを付ける）
    groups := Map()
    for idx, row in rows
        if (idx > 1 && row.Length >= 1 && Trim(row[1]) != "")
            groups[Trim(row[1])] := 1
    multi := groups.Count >= 2

    ; パス2: 変換＋一意化＋冪等スキップ
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
}

; Clibor形式CSVのヘッダ行判定(4列: 定型文グループ,定型文,メモ,ホットキー)。誤コードページ読みは日本語が化けて必ず不一致になる。
CliborHeaderOk(rows) {
    return rows.Length >= 2 && rows[1].Length >= 4
        && Trim(rows[1][1]) = "定型文グループ" && Trim(rows[1][2]) = "定型文"
        && Trim(rows[1][3]) = "メモ" && Trim(rows[1][4]) = "ホットキー"
}

; Cliborの1件分からラベル素材を生成(メモ優先、空なら本文先頭20文字)し、ini形式を壊す文字をサニタイズする
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

; CSVフィールドとして安全な形にエスケープ（カンマ・改行・ダブルクォートを含む場合のみ囲む）
CsvField(s) {
    if InStr(s, '"') || InStr(s, ",") || InStr(s, "`n") || InStr(s, "`r")
        return '"' . StrReplace(s, '"', '""') . '"'
    return s
}

; 定型文をCSV(label,body)でエクスポート。他ツール(Excel等)との往復を想定した汎用形式。
; dlg=trueなら結果をCSVダイアログのステータス行に出す。falseならToolTip(Flash)。
; snippets(items配列)をCSVテキスト(UTF-8 BOM付き・ヘッダlabel,body)へ整形する共通ロジック
SnippetsToCsvText(items) {
    out := Chr(0xFEFF) . "label,body`r`n"
    for s in items
        out .= CsvField(s.label) . "," . CsvField(s.value) . "`r`n"
    return out
}

ExportSnippetsCsv(dlg := false) {
    items := LoadSnippets()
    if (items.Length = 0) {
        dlg ? SetCsvStatus("エクスポートする定型文がありません") : Flash("エクスポートする定型文がありません", 1800)
        return
    }
    f := FileSelect("S16", A_ScriptDir . "\snippets.csv", "エクスポート先を選択", "CSVファイル (*.csv)")
    if (f = "")
        return
    if !RegExMatch(f, "i)\.csv$")
        f .= ".csv"
    try {
        if FileExist(f)
            FileDelete(f)
        FileAppend(SnippetsToCsvText(items), f, "UTF-8")
        msg := items.Length . " 件をCSVに書き出しました"
        dlg ? SetCsvStatus(msg) : Flash(msg, 1800)
    } catch as e {
        msg := "エクスポートに失敗しました: " . e.Message
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
    }
}

; 定型文フォルダ保存(既定OFF・オプトイン)。snippets.iniが変更されるたびに呼ばれ、
; template/snippets.csv を丸ごと上書きする(定型文は元々ファイル永続化済みなので検疫は不要)。
ArchiveSnippetsCsv() {
    global ClipArchiveText
    if !ClipArchiveText
        return
    dir := ArchiveSubDir("template")
    if (dir = "")
        return
    items := LoadSnippets()
    path := dir . "\snippets.csv"
    try {
        if FileExist(path)
            FileDelete(path)
        FileAppend(SnippetsToCsvText(items), path, "UTF-8")
    }
}

; 別ファイルから定型文を取り込む。既定は追記マージ（重複ラベルはスキップ）。
; clearFirst=true のときは snippets.ini を空にしてから取り込む（Clibor同様の「全クリアして取込」）。
; 拡張子で自動判別: .csv はCSVパーサ、それ以外(.ini/.txt)は既存のLoadSnippetsを流用。
; 書き込みはPromoteHistoryAtと同じ流儀（IniWrite不使用・UTF-8明示のFileAppend）
ImportSnippets(clearFirst := false, dlg := false) {
    f := FileSelect(1, , "取り込む定型文ファイルを選択", "定型文ファイル (*.ini; *.txt; *.csv)")
    if (f = "")
        return
    try if (FileGetSize(f) > 1024 * 1024) {
        msg := "ファイルが大きすぎます（1MB超）"
        dlg ? SetCsvStatus(msg) : Flash(msg, 1800)
        return
    }
    path := A_ScriptDir . "\snippets.ini"
    isClibor := false
    if RegExMatch(f, "i)\.csv$") {
        existing := Map()
        if !clearFirst
            for s in LoadSnippets()
                existing[s.label] := s.value
        incoming := TryLoadCliborCsv(f, existing)
        if incoming
            isClibor := true
        else
            incoming := LoadSnippetsCsv(f)   ; 従来のlabel,body形式
    } else
        incoming := LoadSnippets(f)
    if (incoming.Length = 0) {
        msg := "取り込める定型文が見つかりませんでした（ラベル=本文 の形式）"
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
        return
    }
    try {
        if clearFirst
            FileDelete(path)   ; 既存を全クリアしてから取り込む(確認はGUI側で取得済み)
        have := Map()
        for s in LoadSnippets()
            have[s.label] := 1
        nl := (FileExist(path) && !RegExMatch(FileRead(path, "UTF-8"), "\R$")) ? "`n" : ""
        added := 0
        for s in incoming {
            if have.Has(s.label)
                continue
            FileAppend(nl . s.label . "=" . StrReplace(s.value, "`n", "\n") . "`n", path, "UTF-8")
            nl := "", added++
        }
        ArchiveSnippetsCsv()                  ; 定型文フォルダ保存(ONの場合のみ)
        skipped := incoming.Length - added
        msg := (isClibor ? "Clibor形式として" : "") . added . " 件を取り込みました（重複 " . skipped . " 件はスキップ）"
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
    } catch as e {
        msg := "インポートに失敗しました: " . e.Message
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
    }
}

; SetCsvStatus: 定型文管理ウィンドウのステータス行に書く（CSV出力/取込の結果表示先）
SetCsvStatus(msg) {
    global SnipMgrStatus
    if SnipMgrStatus
        SnipMgrStatus.Text := msg
}

; ランチャー右上の歯車から開く設定メニュー。トレイメニューと同じ項目を抜粋して束ねる。
ShowLauncherSettingsMenu(*) {
    global LauncherGui, ClipWatchOn
    SetTimer(CheckLauncherFocus, 0)   ; メニュー表示中の誤クローズ防止(既存の履歴右クリックメニューと同じ流儀)
    m := Menu()
    m.Add("クリップボード監視を一時停止", ToggleClipWatch)
    m.Add("クリップボード履歴を全削除", DeleteHistoryAll)
    m.Add("定型文の管理...", ShowSnippetManager)
    m.Add("定型文ファイルを編集 (snippets.ini)", EditSnippetsFile)   ; 上級者向け(生のiniを直接編集)。通常は上のGUIで足りる
    m.Add("設定...", ShowSettingsWindow)
    m.Add("設定フォルダを開く", (*) => Run('explorer.exe "' . A_ScriptDir . '"'))
    if !ClipWatchOn
        m.Check("クリップボード監視を一時停止")
    m.Show()
    if IsObject(LauncherGui)
        SetTimer(CheckLauncherFocus, 150)
}

; --- 定型文の管理ウィンドウ（一覧＋編集フォーム＋CSV出力/取込を1画面に統合） ---
; snippets.iniは「1定型文=1行」の不変条件を持つため、保存/削除は行番号ベースの
; 行単位書き換えで行う（全文書き直しはコメント行消失・重複ラベル誤爆のリスクがあり不採用）。
global SnipMgrGui := 0, SnipMgrLV := 0, SnipMgrLabelEd := 0, SnipMgrBodyEd := 0
global SnipMgrStatus := 0, SnipMgrItems := [], SnipMgrClearChk := 0
global SnipMgrTab := 0, SnipMgrHistLV := 0, SnipMgrHistEd := 0, SnipMgrHistPrev := 0
global SnipMgrHistCount := 0, SnipMgrHistRows := []

ShowSnippetManager(*) {
    global SnipMgrGui, SnipMgrLV, SnipMgrLabelEd, SnipMgrBodyEd, SnipMgrStatus, SnipMgrClearChk
    global SnipMgrTab, SnipMgrHistLV, SnipMgrHistEd, SnipMgrHistPrev, SnipMgrHistCount
    if SnipMgrGui {
        SnipMgrRefresh()               ; 外部編集(メモ帳/取込)を拾うため再表示時は必ず再読込
        SnipMgrHistRefresh()
        SnipMgrGui.Show()
        return
    }
    SnipMgrGui := Gui("+ToolWindow", "定型文の管理")
    SnipMgrGui.SetFont("s9", "Meiryo UI")
    SnipMgrTab := SnipMgrGui.Add("Tab3", "x0 y0 w600 h496 -Wrap", ["定型文", "履歴"])
    SnipMgrTab.OnEvent("Change", SnipMgrTabChanged)

    SnipMgrTab.UseTab(1)
    ; NoSort NoSortHdr が必須: ソートを許すと行番号↔SnipMgrItemsの対応が壊れ、
    ; 別の定型文を上書き・削除する事故につながる（この設定を外さないこと）
    SnipMgrLV := SnipMgrGui.Add("ListView", "x10 y36 w580 h250 -Multi NoSort NoSortHdr +Grid",
        ["ラベル", "本文"])
    SnipMgrLV.ModifyCol(1, 150), SnipMgrLV.ModifyCol(2, 400)
    SnipMgrLV.OnEvent("ItemSelect", SnipMgrOnSelect)

    SnipMgrGui.Add("Text", "x10 y300 w50 h20", "ラベル")
    SnipMgrLabelEd := SnipMgrGui.Add("Edit", "x64 y296 w300 h24")
    SnipMgrGui.Add("Text", "x10 y330 w50 h20", "本文")
    ; +WantReturn: 既定ボタンにEnterを食われず本文中に改行を打てるようにする
    SnipMgrBodyEd := SnipMgrGui.Add("Edit", "x64 y326 w526 h96 +Multi +WantReturn +VScroll")

    SnipMgrGui.Add("Button", "x64 y432 w100 h28", "新規追加").OnEvent("Click", SnipMgrAdd)
    SnipMgrGui.Add("Button", "x172 y432 w100 h28", "上書き保存").OnEvent("Click", SnipMgrSave)
    SnipMgrGui.Add("Button", "x280 y432 w80 h28", "削除").OnEvent("Click", SnipMgrDelete)
    SnipMgrGui.Add("Button", "x430 y432 w76 h28", "CSV出力").OnEvent("Click", (*) => ExportSnippetsCsv(true))
    SnipMgrGui.Add("Button", "x510 y432 w80 h28", "CSV取込").OnEvent("Click", SnipMgrImport)
    SnipMgrClearChk := SnipMgrGui.Add("CheckBox", "x430 y464 w160 h20", "全クリアして取込")

    ; --- 履歴タブ: 非永続のClipHistoryを検索・参照するだけのビュー(ペースト機能は持たせない) ---
    SnipMgrTab.UseTab(2)
    SnipMgrGui.Add("Text", "x10 y40 w40 h20", "検索")
    SnipMgrHistEd := SnipMgrGui.Add("Edit", "x54 y36 w280 h24")
    SnipMgrHistEd.OnEvent("Change", (*) => SnipMgrHistRefresh())
    SnipMgrHistCount := SnipMgrGui.Add("Text", "x344 y40 w246 h20 cGray", "")
    ; 履歴LVにもNoSort NoSortHdrを付ける: ソートされると行↔SnipMgrHistRows対応が崩れ、
    ; 選んだのと違う行がコピーされる事故になる（定型文タブと同じ理由）
    ; +0x40=LVS_SHAREIMAGELISTS: ランチャーとImageListを共有するため、このLVが破棄されても
    ; 共有ImageList(HistThumbIL)が道連れ破壊されないようにする(付け忘れると相互に壊れる)。
    SnipMgrHistLV := SnipMgrGui.Add("ListView", "x10 y66 w580 h240 -Multi NoSort NoSortHdr +Grid +0x40",
        ["コピー日時", "本文"])
    SnipMgrHistLV.ModifyCol(1, 150), SnipMgrHistLV.ModifyCol(2, 400)
    EnsureHistThumbIL()                       ; 画像履歴の実サムネイル表示用ImageList
    SnipMgrHistLV.SetImageList(HistThumbIL, 1)
    SnipMgrHistLV.OnEvent("ItemSelect", SnipMgrHistOnSelect)
    SnipMgrHistLV.OnEvent("DoubleClick", (lv, row) => SnipMgrHistCopy())
    SnipMgrGui.Add("Text", "x10 y316 w50 h20", "全文")
    SnipMgrHistPrev := SnipMgrGui.Add("Edit", "x64 y312 w526 h108 +ReadOnly +Multi +VScroll")
    SnipMgrGui.Add("Button", "x64 y428 w170 h28", "クリップボードへコピー").OnEvent("Click", SnipMgrHistCopy)
    SnipMgrGui.Add("Text", "x244 y434 w340 h20 cGray",
        "履歴は最大" . ClipHistoryMax . "件・このPC内のみ・保存されません")

    SnipMgrTab.UseTab()   ; 必須: 以降のステータス行を両タブ共通にする
    ; ブランドロゴ: タブより後に追加してz-orderを前面にし、タブ行の右端に重ねて表示。
    ; 読み込み失敗(ファイル欠落等)は機能に影響しないよう握りつぶす
    try SnipMgrGui.Add("Picture", "x566 y2 w22 h22", A_ScriptDir . "\kimitolink-mark.png")
    SnipMgrStatus := SnipMgrGui.Add("Text", "x10 y500 w400 h20 cGray", "")
    ; フッター: フルロゴを右下に控えめに配置。読み込み失敗は握りつぶす(G-3と同じ流儀)
    try SnipMgrGui.Add("Picture", "x522 y528 w58 h36", A_ScriptDir . "\kimitolink-full-logo.png")

    SnipMgrGui.OnEvent("Close", (*) => SnipMgrGui.Hide())
    SnipMgrGui.OnEvent("Escape", (*) => SnipMgrGui.Hide())
    SnipMgrRefresh()
    SnipMgrHistRefresh()
    SnipMgrGui.Show("w600 h572")
}

SnipMgrTabChanged(tab, *) {
    if (tab.Value = 2)
        SnipMgrHistRefresh()
}

; ClipHistoryを検索語でフィルタし総入れ替え。最大30件(ClipHistoryMax)なので
; 総入れ替えの性能コストは無視できる(デバウンス等は不要)。
SnipMgrHistRefresh() {
    global ClipHistory, SnipMgrHistLV, SnipMgrHistEd, SnipMgrHistRows, SnipMgrHistCount, SnipMgrHistPrev
    RebuildHistThumbILIfBloated()
    q := Trim(SnipMgrHistEd.Value)
    SnipMgrHistRows := []
    SnipMgrHistLV.Delete()
    for v in ClipHistory {                       ; 配列は常に新しい順（PushClipHistoryが先頭挿入）
        if (q != "" && !InStr(v.text, q, false) && !InStr(v.time, q, false))
            continue
        SnipMgrHistRows.Push(v)                  ; インデックスでなく要素の参照を保持
        disp := StrReplace(StrReplace(v.text, "`r", ""), "`n", " ⏎ ")
        opt := (v.type = "image") ? "Icon" . (HistThumbIndex(v) + 1) : "Icon0"  ; Icon0省略不可(全行に1番目が出る既知の仕様)
        SnipMgrHistLV.Add(opt, v.time, SubStr(disp, 1, 100))
    }
    SnipMgrHistCount.Text := SnipMgrHistRows.Length . " 件"
        . (q != "" ? " （絞り込み中 / 全" . ClipHistory.Length . "件）" : "")
    SnipMgrHistPrev.Value := ""
}

; ItemSelectは選択解除時もselected=falseで発火する。ここを無視すると
; 選択解除のたびに直前の行の内容がプレビューに残り続ける不具合になる。
SnipMgrHistOnSelect(lv, row, selected) {
    global SnipMgrHistRows, SnipMgrHistPrev
    if (!selected || row < 1 || row > SnipMgrHistRows.Length)
        return
    v := SnipMgrHistRows[row]
    SnipMgrHistPrev.Value := (v.type = "image")
        ? "画像 " . v.w . "×" . v.h . " — ダブルクリックまたはボタンで再コピーできます"
        : StrReplace(v.text, "`n", "`r`n")   ; Editの改行はCRLF
}

; コピー操作はクリップボード監視経由でPushClipHistoryを発火させ、その要素が
; 配列先頭へ移動しうる。SnipMgrHistRowsは要素の参照を保持しているためズレない。
SnipMgrHistCopy(*) {
    global SnipMgrHistLV, SnipMgrHistRows
    row := SnipMgrHistLV.GetNext(0)
    if (!row || row > SnipMgrHistRows.Length) {
        SetCsvStatus("コピーする履歴を選択してください")
        return
    }
    v := SnipMgrHistRows[row]
    if (v.type = "image") {
        if SetClipboardImage(v.dib)
            SetCsvStatus("クリップボードへコピーしました")
        else
            SetCsvStatus("画像を再設定できませんでした")
        return
    }
    A_Clipboard := v.text
    SetCsvStatus("クリップボードへコピーしました")
}

; LoadSnippetsと同じ判定規則だが ini上の行番号を保持する(編集・削除の宛先に使う)
; LoadSnippets本体は改造しない(ランチャー側の呼び出し複数箇所への波及を避けるため)
SnipMgrReadItems() {
    items := [], path := A_ScriptDir . "\snippets.ini"
    if !FileExist(path)
        return items
    for n, raw in StrSplit(FileRead(path, "UTF-8"), "`n", "`r") {
        line := Trim(raw)
        if (line = "" || SubStr(line, 1, 1) = ";" || SubStr(line, 1, 1) = "[")
            continue
        eq := InStr(line, "=")
        if !eq
            continue
        label := Trim(SubStr(line, 1, eq - 1)), val := Trim(SubStr(line, eq + 1))
        if (label != "" && val != "")
            items.Push({label: label, value: StrReplace(val, "\n", "`n"), lineNo: n})
    }
    return items
}

SnipMgrRefresh() {
    global SnipMgrLV, SnipMgrItems, SnipMgrLabelEd, SnipMgrBodyEd
    SnipMgrItems := SnipMgrReadItems()
    SnipMgrLV.Delete()
    for s in SnipMgrItems {
        prev := RegExReplace(s.value, "\s+", " ")
        SnipMgrLV.Add(, s.label, (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . SubStr(prev, 1, 80))
    }
    SnipMgrLabelEd.Value := "", SnipMgrBodyEd.Value := ""
}

; ItemSelectは選択解除時もselected=falseで発火する。ここを無視すると
; 選択解除のたびに直前の行の内容がフォームに残り続ける不具合になる。
SnipMgrOnSelect(lv, row, selected) {
    global SnipMgrItems, SnipMgrLabelEd, SnipMgrBodyEd
    if (!selected || row < 1 || row > SnipMgrItems.Length)
        return
    SnipMgrLabelEd.Value := SnipMgrItems[row].label
    SnipMgrBodyEd.Value := StrReplace(SnipMgrItems[row].value, "`n", "`r`n")   ; Editの改行はCRLF
}

; 行単位の書換え/削除。書換え前に宛先行のラベルを検証し、外部編集でズレていたら中止(fail-closed)。
; これがメモ帳等での同時編集と競合して「別の定型文を壊す」事故を防ぐ唯一の防御。
SnipMgrWriteLine(lineNo, expectLabel, newLine) {
    path := A_ScriptDir . "\snippets.ini"
    lines := StrSplit(FileRead(path, "UTF-8"), "`n", "`r")
    if (lineNo > lines.Length || !RegExMatch(Trim(lines[lineNo]), "^\Q" . expectLabel . "\E\s*="))
        return false
    (newLine = "") ? lines.RemoveAt(lineNo) : lines[lineNo] := newLine
    out := ""
    for l in lines
        out .= l . "`n"
    FileDelete(path)
    FileAppend(RTrim(out, "`n") . "`n", path, "UTF-8")
    ArchiveSnippetsCsv()                      ; 定型文フォルダ保存(ONの場合のみ)
    return true
}

; フォーム値の取り出し共通部: CRLF→LF正規化＋ラベル無害化(PromoteHistoryAtと同一規則)
SnipMgrFormValues(&label, &body) {
    global SnipMgrLabelEd, SnipMgrBodyEd
    label := RegExReplace(Trim(SnipMgrLabelEd.Value), "[=\[\];]")
    body := StrReplace(SnipMgrBodyEd.Value, "`r`n", "`n")
    return (label != "" && body != "")
}

SnipMgrAdd(*) {
    global SnipMgrItems
    if !SnipMgrFormValues(&label, &body)
        return SetCsvStatus("ラベルと本文を入力してください")
    for s in SnipMgrItems
        if (s.label = label)
            return SetCsvStatus("同じラベルが既に存在します: " . label)
    path := A_ScriptDir . "\snippets.ini"
    try {
        nl := (FileExist(path) && !RegExMatch(FileRead(path, "UTF-8"), "\R$")) ? "`n" : ""
        FileAppend(nl . label . "=" . StrReplace(body, "`n", "\n") . "`n", path, "UTF-8")
        ArchiveSnippetsCsv()                  ; 定型文フォルダ保存(ONの場合のみ)
        SnipMgrRefresh()
        SetCsvStatus("追加しました: " . label)
    } catch as e {
        SetCsvStatus("追加に失敗しました: " . e.Message)
    }
}

SnipMgrSave(*) {
    global SnipMgrLV, SnipMgrItems
    row := SnipMgrLV.GetNext(0)
    if (!row || row > SnipMgrItems.Length)
        return SetCsvStatus("一覧から編集する行を選んでください")
    if !SnipMgrFormValues(&label, &body)
        return SetCsvStatus("ラベルと本文を入力してください")
    item := SnipMgrItems[row]
    newLine := label . "=" . StrReplace(body, "`n", "\n")
    if SnipMgrWriteLine(item.lineNo, item.label, newLine) {
        SnipMgrRefresh()
        SetCsvStatus("保存しました: " . label)
    } else {
        SnipMgrRefresh()
        SetCsvStatus("ファイルが外部で変更されていたため再読込しました。もう一度お試しください")
    }
}

SnipMgrDelete(*) {
    global SnipMgrLV, SnipMgrItems
    row := SnipMgrLV.GetNext(0)
    if (!row || row > SnipMgrItems.Length)
        return SetCsvStatus("一覧から削除する行を選んでください")
    item := SnipMgrItems[row]
    if SnipMgrWriteLine(item.lineNo, item.label, "") {
        SnipMgrRefresh()
        SetCsvStatus("削除しました: " . item.label)
    } else {
        SnipMgrRefresh()
        SetCsvStatus("ファイルが外部で変更されていたため再読込しました。もう一度お試しください")
    }
}

SnipMgrImport(*) {
    global SnipMgrClearChk
    ImportSnippets(SnipMgrClearChk.Value, true)
    SnipMgrRefresh()
}

; 検索ボックスの入力変更で発火。現在のタブの一覧だけを絞り込み直す(もう一方は次回タブ切替時に絞り込む)。
; 絞り込み後は選択行が動くため数字キー対応の見た目上の番号もFillLauncher*で振り直される。
LauncherFilterChanged(edit, *) {
    global LauncherTab, LauncherLvH, LauncherLbS
    q := Trim(edit.Value)
    if (LauncherTab.Value = 1)
        FillLauncherHistoryLV(LauncherLvH, q)
    else
        FillLauncherSnippetsLB(LauncherLbS, q)
}

; タブ切替時、検索語が入っていれば切替先のタブにも同じ絞り込みを適用する
; (検索ボックスは共通1つなので、片方のタブだけ絞り込んだままにしない)。
LauncherTabChanged(tab, *) {
    global LauncherSearchEdit, LauncherLvH, LauncherLbS
    q := IsObject(LauncherSearchEdit) ? Trim(LauncherSearchEdit.Value) : ""
    if (q = "")
        return
    (tab.Value = 1) ? FillLauncherHistoryLV(LauncherLvH, q) : FillLauncherSnippetsLB(LauncherLbS, q)
}

ShowLauncher() {
    global ClipHistory, LauncherGui, LauncherTarget, Snippets, LauncherTab, LauncherDragBar, LauncherLvH, LauncherLbS, LauncherHoverLast, ClipWatchOn, AppVersion, LauncherSearchEdit, LauncherHistFilterMap, LauncherSnipFilterMap
    Snippets := LoadSnippets()                ; 開くたびに読む: iniを編集→次の長押しで即反映
    if (ClipHistory.Length = 0 && Snippets.Length = 0) {
        Flash("履歴がありません（コピーすると貯まります）", 1800)
        return
    }
    LauncherHistFilterMap := [], LauncherSnipFilterMap := []   ; 前回開いたときの絞り込み状態を持ち越さない
    LauncherTarget := WinExist("A")
    CloseLauncher()
    LauncherGui := Gui("-Caption +AlwaysOnTop +ToolWindow +Border")
    LauncherGui.SetFont("s12", "Meiryo UI")
    LauncherDragBar := LauncherGui.Add("Text", "x0 y0 w380 h16 BackgroundD4DCE8 c1A3E7A +0x100", "  君斗りんくの送信サジェスト")  ; SS_NOTIFY相当をv2既定に加え、押下を明示検知
    LauncherDragBar.SetFont("s8")
    gearBtn := LauncherGui.Add("Text", "x380 y0 w20 h16 BackgroundD4DCE8 cGray Center +0x100", "⚙")
    gearBtn.SetFont("s10")
    gearBtn.OnEvent("Click", ShowLauncherSettingsMenu)
    LauncherGui.Add("Text", "x400 y2 w60 h12 cGray", "v" . AppVersion).SetFont("s8")   ; 掴みしろの右隣にバージョン表示
    LauncherGui.SetFont("s10")
    LauncherSearchEdit := LauncherGui.Add("Edit", "x4 y18 w452 h22", "")
    LauncherSearchEdit.OnEvent("Change", LauncherFilterChanged)
    LauncherGui.SetFont("s12")
    LauncherTab := LauncherGui.Add("Tab3", "x0 y44 w460 -Wrap",
        ["履歴 " . ClipHistory.Length, "定型文 " . Snippets.Length])
    LauncherTab.OnEvent("Change", LauncherTabChanged)
    rows := Min(Max(ClipHistory.Length, Snippets.Length, 3), 10)
    LauncherTab.UseTab(1)
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
    LauncherTab.UseTab(2)
    LauncherLbS := LauncherGui.Add("ListBox", "w440 r" . rows . " BackgroundFFF9E6", [])
    FillLauncherSnippetsLB(LauncherLbS)
    LauncherLbS.OnEvent("Change", (lb, *) => UseSnippetAt(ResolveSnipRow(lb.Value)))
    LauncherTab.UseTab()
    if (ClipHistory.Length = 0)
        LauncherTab.Value := 2                        ; 履歴が空なら定型文タブで開く
    ; r行指定はアイコン行高(約36px)を知らずに文字高で計算されるため、実測して合わせる。
    if (ih := LauncherLVItemHeight(LauncherLvH)) {
        listH := ih * rows + 6
        LauncherLvH.GetPos(&lvX, &lvY, , &lvH0)
        LauncherLvH.Move(, , , listH)
        LauncherLbS.Move(, , , listH)         ; 定型文側も同じ箱サイズに(タブ切替で高さが揃う)
        LauncherTab.GetPos(&tX, &tY, , &tH0)
        LauncherTab.Move(, , , tH0 + (listH - lvH0))
    }
    ; ブランドロゴ: フッター(Tab3コントロールの下端に明示座標で追従)に中央揃えで控えめに表示。
    ; リスト行数(rows)でTab3の下端が動くため、Tab3.GetPos()で実際の下端を取得してから置く。
    ; 画像は102x64(2:1)。wのみ指定してhは-1でアスペクト比を保たせ、横伸びを防ぐ。
    ; 読み込み失敗時は握りつぶし、ロゴが出ないだけでランチャーは通常通り使える。
    LauncherTab.GetPos(&tabX, &tabY, &tabW, &tabH)
    footerY := tabY + tabH + 6
    logoW := 90, logoH := 45                      ; 102x64を90幅に縮小(比率維持: 90*64/102≈56だが余白確保のため45に収める)
    try LauncherGui.Add("Picture", "x" . (tabX + (tabW - logoW) // 2) . " y" . footerY . " w" . logoW . " h-1",
        A_ScriptDir . "\kimitolink-full-logo-64.png")
    LauncherGui.Add("Text", "x0 y" . footerY . " w1 h40")   ; ロゴ行の高さをウィンドウ計算に含めるための透明スペーサ
    LauncherGui.OnEvent("Escape", (*) => CloseLauncher())
    LauncherGui.OnEvent("ContextMenu", LauncherContextMenu)
    ; 画面上の固定位置に開く(プライマリモニタ中央)。マウスカーソルが画面下部にあると
    ; 追従表示では毎回隠れてしまうという実運用フィードバックを受け、位置固定に変更(v1.13.0〜)。
    LauncherGui.Show("w460 xCenter yCenter")
    WinActivate("ahk_id " . LauncherGui.Hwnd)
    SetTimer(CheckLauncherFocus, 150)
    SetTimer(LauncherWatchDrag, 30)
    LauncherHoverLast := "", SetTimer(LauncherWatchHover, 120)
}

; 表示行(ListView/数字キー由来の1始まり行番号) → ClipHistoryの実インデックス。
; LauncherHistFilterMapが空(検索未使用)なら1:1のまま素通しする。
ResolveHistRow(displayRow) {
    global LauncherHistFilterMap
    if (LauncherHistFilterMap.Length = 0)
        return displayRow
    return (displayRow >= 1 && displayRow <= LauncherHistFilterMap.Length) ? LauncherHistFilterMap[displayRow] : 0
}

PasteHistoryAt(idx) {
    global ClipHistory
    if (idx < 1 || idx > ClipHistory.Length)
        return
    v := ClipHistory[idx]
    CloseLauncher()
    (v.type = "image") ? PasteImage(v.dib) : PasteText(v.text)
}

; クリック(選択)→即ペースト。旧ListBox Changeイベントの後継(履歴タブのListView化に伴う)。
LauncherHistSelect(lv, row, selected) {
    if (!selected || GetKeyState("RButton", "P"))   ; 選択解除時と、右クリック由来の選択では発火させない
        return
    PasteHistoryAt(ResolveHistRow(row))
}

; 表示行(ListBox/数字キー由来の1始まり行番号) → Snippetsの実インデックス。
; LauncherSnipFilterMapが空(検索未使用)なら1:1のまま素通しする。
ResolveSnipRow(displayRow) {
    global LauncherSnipFilterMap
    if (LauncherSnipFilterMap.Length = 0)
        return displayRow
    return (displayRow >= 1 && displayRow <= LauncherSnipFilterMap.Length) ? LauncherSnipFilterMap[displayRow] : 0
}

UseSnippetAt(idx) {
    global Snippets
    if (idx < 1 || idx > Snippets.Length)
        return
    s := Snippets[idx]
    CloseLauncher()
    if (SubStr(s.value, 1, 4) = "run:") {
        target := Trim(SubStr(s.value, 5))
        try Run(target)
        catch
            Flash("起動できませんでした: " . target, 1800)
        return
    }
    PasteText(s.value)
}

PasteText(text) {
    global LauncherTarget, SelfClipTick
    SelfClipTick := A_TickCount
    A_Clipboard := text
    if (LauncherTarget && WinExist("ahk_id " . LauncherTarget))
        WinActivate("ahk_id " . LauncherTarget)
    Sleep 150
    Send("^v")
}

; --- グローバルクリップボード監視（ユーザー操作限定フィルタ付き） ---
; RDP/VM同期で載らないのは仕様（ローカルのキー・マウス操作を伴わないためフィルタで弾く）
ClipChanged(type) {
    global ClipWatchOn, SelfClipTick
    if (A_TickCount - SelfClipTick < 500) {   ; PasteText/SetClipboardImage等の自己書き込み
        DiagBump("selfSuppress")
        return
    }
    if (type = 0) {                           ; クリア → 自動クリア検知
        DiagBump("evtClear")
        MaybeDropAutoCleared()
        return
    }
    if (!ClipWatchOn) {
        DiagBump("watchOff")
        return
    }
    if ClipHasIgnoreFormat() {                ; パスワードマネージャの標準除外フォーマット(テキスト/画像共通)
        DiagBump("ignoreFormat")
        return
    }
    if (type = 1) {
        DiagBump("evtText")
        SetTimer(CaptureClip, -120)           ; 多重発火デバウンス(最後の発火から120ms後に1回)
    } else if (type = 2 && DllCall("IsClipboardFormatAvailable", "UInt", 8)) {  ; CF_DIB=8
        DiagBump("evtImage")
        SetTimer(CaptureClipImage, -120)
    }
}

CaptureClip() {
    global LastUserCopyTick, LastLButtonUpTick, ClipUserWindowMs, ClipMaxLen
    global LastCaptureText, LastCaptureTick
    DiagBump("capText")
    now := A_TickCount
    ; ★核心の安全策: 直近1秒以内のユーザー操作がなければ捨てる(fail-closed)
    if (now - LastUserCopyTick > ClipUserWindowMs) && (now - LastLButtonUpTick > ClipUserWindowMs) {
        DiagBump("rejUserText")
        return
    }
    if ClipSourceExcluded() {
        DiagBump("rejSource")
        return
    }
    text := ""
    try text := A_Clipboard                   ; 遅延レンダリング元が死んでいると失敗しうる
    if (text = "" || StrLen(text) > ClipMaxLen) {
        DiagBump("rejEmptyLong")
        return
    }
    LastCaptureText := text, LastCaptureTick := now
    PushClipHistory(text)
}

; --- クリップボード画像履歴 ---
; ハンドル(HBITMAP/HGLOBAL)は履歴に持ち越さない: GetClipboardDataの戻りはクリップボード側の
; 所有物で、他プロセスのEmptyClipboardで無効化されうる。開いている間にBufferへ即コピーする
; ことで、一時ファイルなしでもハンドル寿命問題を回避する(GDIハンドルを保持しないためDeleteObject
; の帳簿管理も不要になる)。

ClipOpen() {
    Loop 5 {                                  ; 他プロセスが握っていると失敗するためリトライ
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
        hDib := DllCall("GetClipboardData", "UInt", 8, "Ptr")   ; CF_DIB
        if hDib {
            p := DllCall("GlobalLock", "Ptr", hDib, "Ptr")
            if p {
                sz := DllCall("GlobalSize", "Ptr", hDib, "UPtr")
                buf := Buffer(sz)
                DllCall("RtlMoveMemory", "Ptr", buf, "Ptr", p, "UPtr", sz)
                DllCall("GlobalUnlock", "Ptr", hDib)
            }
        }
    } finally DllCall("CloseClipboard")       ; 例外でも必ず閉じる(閉じ忘れはOS全体のコピペを止める)
    return buf
}

CaptureClipImage() {
    global LastUserCopyTick, LastLButtonUpTick, ClipUserWindowMs, ClipImageMaxBytes, ClipImageMinPx
    DiagBump("capImage")
    now := A_TickCount
    if (now - LastUserCopyTick > ClipUserWindowMs) && (now - LastLButtonUpTick > ClipUserWindowMs) {
        DiagBump("rejUserImage")
        return
    }
    if ClipSourceExcluded() {
        DiagBump("rejSource")
        return
    }
    dib := GetClipDib()
    if (!dib || dib.Size < 40) {                                  ; 40=BITMAPINFOHEADER最小
        DiagBump("rejDib")
        return
    }
    if (dib.Size > ClipImageMaxBytes) {
        DiagBump("rejSize")
        return
    }
    w := NumGet(dib, 4, "Int"), h := Abs(NumGet(dib, 8, "Int"))  ; biWidth/biHeight(トップダウンは負)
    if (w < ClipImageMinPx || h < ClipImageMinPx) {               ; 極小画像(意図しないノイズ)は弾く
        DiagBump("rejMinPx")
        return
    }
    PushClipImage(dib, w, h)
}

PushClipImage(dib, w, h) {
    global ClipHistory, ClipHistoryMax, ClipImageMax, ClipArchiveImage
    DiagBump("pushImage")
    label := "📷 画像 " . w . "×" . h . " (" . Round(dib.Size / 1048576, 1) . "MB)"
    ClipHistory.InsertAt(1, {type: "image", text: label, dib: dib, w: w, h: h, time: NowWithWeekday()})
    n := 0
    for i, v in ClipHistory                   ; 画像専用上限: 古い画像から間引く
        if (v.type = "image" && ++n > ClipImageMax) {
            ClipHistory.RemoveAt(i)           ; RemoveAtでBufferの参照が切れ自動解放される
            break                             ; 1回の追加で超過は最大1件
        }
    while (ClipHistory.Length > ClipHistoryMax) {
        i := ClipHistory.Length
        while (i >= 1 && ClipHistory[i].type = "image")   ; 末尾から見てテキストを優先的に間引く
            i--
        ClipHistory.RemoveAt(i > 0 ? i : ClipHistory.Length)
    }
    ; 画像は検疫なし即保存(自動クリアはテキストのみ追跡するため対象外。D節参照)
    if (ClipArchiveImage && (dir := ArchiveSubDir("screenshot")) != "")
        SaveDibAsPng(dib, w, h, dir . "\img-" . FormatTime(, "yyyyMMdd-HHmmss") . ".png")
    RefreshLauncherHistory()   ; ランチャーが開いたままの間もタブ数字・リストをライブ反映
}

SetClipboardImage(dib) {
    global SelfClipTick
    hMem := DllCall("GlobalAlloc", "UInt", 0x2, "UPtr", dib.Size, "Ptr")  ; GMEM_MOVEABLE
    if !hMem
        return false
    p := DllCall("GlobalLock", "Ptr", hMem, "Ptr")
    DllCall("RtlMoveMemory", "Ptr", p, "Ptr", dib, "UPtr", dib.Size)
    DllCall("GlobalUnlock", "Ptr", hMem)
    if !ClipOpen() {
        DllCall("GlobalFree", "Ptr", hMem)    ; 開けなかったら自分で解放
        return false
    }
    ok := false
    try {
        SelfClipTick := A_TickCount           ; EmptyClipboardのtype=0通知より前に立てる(自己書込フィルタ)
        DllCall("EmptyClipboard")
        ok := DllCall("SetClipboardData", "UInt", 8, "Ptr", hMem, "Ptr") != 0
    } finally DllCall("CloseClipboard")
    if !ok
        DllCall("GlobalFree", "Ptr", hMem)    ; 成功時は所有権がOSに移るため触らない(触ると二重解放)
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

; --- カーソルがあるモニタだけの全画面スクショ（マルチモニタ対応） ---
; MonitorFromPointはPOINT構造体(x,yの8バイト)を1つの値として渡す必要がある。
; MONITOR_DEFAULTTONEAREST(=2)により、境界値でも必ずどこかのモニタを返す(fail-safe)。
MonitorRectAtCursor() {
    MouseGetPos(&mx, &my)
    pt := Buffer(8, 0)
    NumPut("Int", mx, pt, 0), NumPut("Int", my, pt, 4)
    hMon := DllCall("MonitorFromPoint", "Int64", NumGet(pt, 0, "Int64"), "UInt", 2, "Ptr")
    if !hMon
        return 0
    mi := Buffer(40, 0)                       ; MONITORINFO構造体
    NumPut("UInt", 40, mi, 0)                 ; cbSize(事前セット必須)
    if !DllCall("GetMonitorInfo", "Ptr", hMon, "Ptr", mi)
        return 0
    l := NumGet(mi, 4, "Int"), t := NumGet(mi, 8, "Int")   ; rcMonitor(offset 4-19)
    r := NumGet(mi, 12, "Int"), b := NumGet(mi, 16, "Int")
    return {l: l, t: t, r: r, b: b, w: r - l, h: b - t}
}

; 指定矩形(スクリーン座標)をBitBltでキャプチャしCF_DIB形式のBufferを返す。失敗時は0。
; SaveDibAsPngと同じGDIハンドル確保・解放パターン(GetDC/CreateCompatibleDC/SelectObject退避復帰)。
CaptureRectToDib(l, t, w, h) {
    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    if !hdcScreen
        return 0
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    bi := Buffer(40, 0)                       ; BITMAPINFOHEADER
    NumPut("UInt", 40, bi, 0), NumPut("Int", w, bi, 4), NumPut("Int", -h, bi, 8)   ; 負=トップダウン
    NumPut("UShort", 1, bi, 12), NumPut("UShort", 32, bi, 14), NumPut("UInt", 0, bi, 16)
    hBmp := DllCall("CreateDIBSection", "Ptr", hdcScreen, "Ptr", bi, "UInt", 0
        , "Ptr*", &pBits := 0, "Ptr", 0, "UInt", 0, "Ptr")
    ok := false
    if (hdcMem && hBmp && pBits) {
        hOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hBmp, "Ptr")
        ok := DllCall("BitBlt", "Ptr", hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Ptr", hdcScreen, "Int", l, "Int", t, "UInt", 0x00CC0020)   ; SRCCOPY
        DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hOld, "Ptr")
    }
    dib := 0
    if ok {                                   ; SetClipboardImageが期待する「ヘッダ+ピクセル連続」形式に詰め直す
        rowBytes := w * 4
        dib := Buffer(40 + rowBytes * h)
        DllCall("RtlMoveMemory", "Ptr", dib, "Ptr", bi, "UPtr", 40)
        DllCall("RtlMoveMemory", "Ptr", dib.Ptr + 40, "Ptr", pBits, "UPtr", rowBytes * h)
        ; BitBltはアルファチャンネルを埋めないため0(透明)のまま残ることがある。
        ; CF_DIBに厳密なアルファ意味はなく、貼り付け先が透明=無描画と解釈する事故を防ぐため255で強制する。
        px := dib.Ptr + 40
        Loop w * h
            NumPut("UChar", 255, px, (A_Index - 1) * 4 + 3)
    }
    if hBmp
        DllCall("DeleteObject", "Ptr", hBmp)
    if hdcMem
        DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
    return dib
}

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
        FlashScreenRect(rect.l, rect.t, rect.w, rect.h)   ; Win+PrintScreenの暗転演出を模倣(撮影後なので画質に影響しない)
        ; SetClipboardImageが立てるSelfClipTickにより、ClipChanged→CaptureClipImage経路は
        ; 自己書込として遮断される(仕様通り・変更しない)。dibは手元にコピー済み所有なので、
        ; ここで直接履歴へ載せる。通常経路と同じサイズ/極小ガードを通す(fail-closed)。
        ; 詳細経緯: _docs/SELF-DIAGNOSTIC-INSTRUMENTATION-DESIGN.md C-4節
        if (dib.Size <= ClipImageMaxBytes && rect.w >= ClipImageMinPx && rect.h >= ClipImageMinPx) {
            PushClipImage(dib, rect.w, rect.h)
            DiagBump("shotDirect")
        } else
            DiagBump("shotDirectRej")
    } else
        DiagBump("shotFail")
    return ok
}

; 指定モニタ矩形を一瞬だけ黒くフラッシュさせる(Win+PrintScreen風の撮影フィードバック)
FlashScreenRect(l, t, w, h) {
    g := Gui("-Caption +ToolWindow +AlwaysOnTop +E0x20")   ; E0x20=WS_EX_TRANSPARENT(クリック等を素通し)
    g.BackColor := "000000"
    WinSetTransparent(120, g)
    g.Show("x" . l . " y" . t . " w" . w . " h" . h . " NoActivate")
    SetTimer(() => g.Destroy(), -120)
}

; --- 画像履歴の実サムネイル表示（「定型文の管理」の履歴タブのみ。ランチャーのListBoxは非対応） ---
; HBITMAPは生成関数のスコープ外に一切出さない: ImageList_Addは内部コピーなので、
; Add直後にDeleteObjectしてよい。要素にHBITMAPを持たせて使い回すことはしない
; （「ハンドルを持ち越さない」という画像履歴全体の設計思想を、表示層でも守るため）。
global HistThumbIL := 0

; ILの生成のみ。SetImageListでのビューへの紐付けは各呼び出し元の責務（ビューは複数あるため）。
EnsureHistThumbIL() {
    global HistThumbIL
    if HistThumbIL
        return
    HistThumbIL := DllCall("comctl32\ImageList_Create"
        , "Int", 48, "Int", 48, "UInt", 0x20, "Int", 4, "Int", 4, "Ptr")  ; ILC_COLOR32
    AddBlankHistThumb()   ; 0番目=生成失敗時のプレースホルダ。呼び出し側の"Icon".(idx+1)式で-1→0が誤画像を指す事故を防ぐ
}

; サムネイル生成失敗(MakeHistThumbが-1)時の受け皿として、ImageList 0番目に無地(白)画像を1枚登録する。
; MakeHistThumbと同じGDI確保・解放パターン(GetDC/CreateCompatibleDC/DeleteObject/DeleteDC/ReleaseDC)。
AddBlankHistThumb() {
    global HistThumbIL
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcM := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    hBmp := DllCall("CreateCompatibleBitmap", "Ptr", hdcS, "Int", 48, "Int", 48, "Ptr")
    if (hdcM && hBmp) {
        hOld := DllCall("SelectObject", "Ptr", hdcM, "Ptr", hBmp, "Ptr")
        rc := Buffer(16), NumPut("Int", 0, rc, 0), NumPut("Int", 0, rc, 4)
        NumPut("Int", 48, rc, 8), NumPut("Int", 48, rc, 12)
        DllCall("FillRect", "Ptr", hdcM, "Ptr", rc, "Ptr", DllCall("GetStockObject", "Int", 0, "Ptr"))  ; WHITE_BRUSH
        DllCall("SelectObject", "Ptr", hdcM, "Ptr", hOld, "Ptr")
        DllCall("comctl32\ImageList_Add", "Ptr", HistThumbIL, "Ptr", hBmp, "Ptr", 0, "Int")
    }
    if hBmp
        DllCall("DeleteObject", "Ptr", hBmp)
    if hdcM
        DllCall("DeleteDC", "Ptr", hdcM)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
}

; 孤児アイコン(履歴から間引かれても残り続けるImageList内の画像)によるメモリ肥大を防ぐ。
; 差し替え時はLVM_SETIMAGELISTが旧ILを破棄しないため明示的にImageList_Destroyする。
; HistThumbILは「定型文の管理」とランチャーで共有(LVS_SHAREIMAGELISTS)しているため、
; 再構築時は生存中の両ビューへ再アサイン→再充填してから、最後に旧ILを破棄する。
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
        try SnipMgrHistLV.SetImageList(HistThumbIL, 1)
    if IsObject(LauncherGui) {                 ; 理論上の競合窓(通常はフォーカス喪失で閉済み)も塞ぐ
        try {
            LauncherLvH.SetImageList(HistThumbIL, 1)
            FillLauncherHistoryLV(LauncherLvH)    ; 旧indexを持つ行を貼り替え
        }
    }
    DllCall("comctl32\ImageList_Destroy", "Ptr", old)   ; 再アサイン完了後に旧ILを破棄(この順序を守る)
}

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

; --- クリップボード履歴のフォルダ永続保存(既定OFF・オプトイン例外) ---
; 非永続の原則を覆す唯一の経路。安全側の設計は3点:
; (1) 既定OFF・ON時は警告ダイアログ (2) テキストは検疫(45秒+2秒)を通過したものだけ書く
;     ＝自動クリア機構がそのままディスク書き込みの拒否権として働く (3) 画像は検疫なし即保存
;     (自動クリアはテキストのみ追跡するため対象外。スクショは能動的な成果物で脅威モデルが違う)
; 経緯・矛盾解消の論理は_docs/CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md参照

; --- SettingsStore: プログラム専有のsettings.iniを唯一の書き手として全文再生成する。 ---
; 所有権分離の核: sites.ini/snippets.iniは人間所有(既存のFileDelete+FileAppend(UTF-8)流儀を維持)、
; settings.iniはプログラム所有(read-modify-writeをせず毎回全文組み立て→原子リネーム)。
; 旧SaveIniKey(sites.ini内[clipboard]セクションへの挿入位置バグの温床)はこの機構で置き換え、削除した。
; 経緯・設計判断は_docs/SETTINGS-UNIFICATION-DESIGN.md参照
global SettingsMap := Map()
global SettingsDirty := false

; apply先の各関数。矢印関数(fat arrow)はグローバル変数への代入がスコープに反映されない
; (実機で確認済みの地雷: (v)=>(G:=v)は外側のGを更新せず握りつぶす)ため、必ず名前付き関数+global宣言にする。
ApplyClipWatchSetting(v) {
    global ClipWatchOn
    ClipWatchOn := (v != "off")
}
ApplyArchiveImageSetting(v) {
    global ClipArchiveImage
    ClipArchiveImage := (v = "on")
}
ApplyArchiveTextSetting(v) {
    global ClipArchiveText
    ClipArchiveText := (v = "on")
}
ApplyFirstRunPromptedSetting(v) {
}

; キー → {section, default, apply(val)}。GUIとsettings.iniのグルーピングの単一の正本。
SettingDefsInit() {
    global SettingDefs
    SettingDefs := Map(
        "clipboard.watch", {section: "clipboard", default: "on", apply: ApplyClipWatchSetting},
        "archive.image", {section: "archive", default: "off", apply: ApplyArchiveImageSetting},
        "archive.text", {section: "archive", default: "off", apply: ApplyArchiveTextSetting},
        "state.firstrunprompted", {section: "state", default: "0", apply: ApplyFirstRunPromptedSetting}
    )
}
global SettingDefs := Map()

SetSetting(key, val) {
    global SettingsMap, SettingsDirty, SettingDefs
    SettingsMap[key] := val
    ; プロパティ経由の暗黙呼び出し(obj.applyFn(v))は不安定なため.Call()を明示する(実機で確認済みの地雷)。
    if SettingDefs.Has(key)
        SettingDefs[key].apply.Call(val)
    SettingsDirty := true
    SetTimer(FlushSettings, -300)   ; 連打をデバウンスでまとめる。負値=1回きりのワンショット
}

; 引数名を"map"にしない: AutoHotkey v2はパラメータ名で組み込みMap()をシャドーイングし、
; 関数内のMap()呼び出しが「値をCallしようとしてMethod not found」エラーになる(実機で確認済みの地雷)。
BuildSettingsText(settingsMap) {
    global SettingDefs
    bySection := Map()
    for key, def in SettingDefs {
        sec := def.section
        if !bySection.Has(sec)
            bySection[sec] := Map()
        name := SubStr(key, InStr(key, ".") + 1)
        bySection[sec][name] := settingsMap.Has(key) ? settingsMap[key] : def.default
    }
    txt := "; このファイルは送信サジェストが自動管理します。手で編集しても次の設定変更で上書きされます。`n"
        . "; 設定はトレイ →「設定...」から。送信ルールは sites.ini、定型文は snippets.ini へ。`n"
        . "[app]`n" . "version=" . AppVersion . "`n`n"
    for sec, kv in bySection {
        txt .= "[" . sec . "]`n"
        for name, v in kv
            txt .= name . "=" . v . "`n"
        txt .= "`n"
    }
    return txt
}

; 全文再生成→tmp書き→原子リネーム。read-modify-writeをしないため挿入位置バグが構造的に起きない。
; settings.iniのみFileOpen(w,UTF-8-RAW)を使う(新規作成でもBOMが構造的に発生しない)。
; sites.ini/snippets.iniへの既存書き込み経路はrefactor-instructions.md §3の絶対制約どおり変更しない。
FlushSettings() {
    global SettingsMap, SettingsDirty
    if !SettingsDirty
        return
    txt := BuildSettingsText(SettingsMap)
    path := A_ScriptDir . "\settings.ini"
    tmp := path . ".tmp"
    try {
        f := FileOpen(tmp, "w", "UTF-8-RAW")
        f.Write(txt)
        f.Close()
        if !DllCall("MoveFileExW", "WStr", tmp, "WStr", path, "UInt", 0x1 | 0x8)   ; REPLACE_EXISTING|WRITE_THROUGH
            throw OSError()
        SettingsDirty := false
    } catch as e {
        try FileDelete(tmp)
        Flash("設定の保存に失敗しました(次の変更時に再試行します)", 2000)
    }
}

; 先頭のBOM(EF BB BF)をスキップして読む。過去に別経路で生成された可能性のあるBOM付きファイルの後方互換。
ReadSettingsIniText(path) {
    txt := FileRead(path, "UTF-8")
    return RegExReplace(txt, "^\x{FEFF}")
}

LoadSettingsIni() {
    global SettingsMap, SettingDefs
    path := A_ScriptDir . "\settings.ini"
    section := ""
    for line in StrSplit(ReadSettingsIniText(path), "`n", "`r") {
        line := Trim(line)
        if (line = "" || SubStr(line, 1, 1) = ";")
            continue
        if RegExMatch(line, "^\[(.+)\]$", &m) {
            section := Trim(m[1])
            continue
        }
        eq := InStr(line, "=")
        if !eq
            continue
        name := Trim(SubStr(line, 1, eq - 1))
        val := Trim(SubStr(line, eq + 1))
        key := section . "." . name
        if SettingDefs.Has(key) {
            SettingsMap[key] := val
            SettingDefs[key].apply.Call(val)
        }
    }
}

; 起動時1回だけ実行。settings.iniが無ければsites.ini/startup-prompted.flagから現在有効値を吸い上げて生成。
; 失敗しても現行動作のまま継続する(fail-closed: 移行の失敗が機能停止にならない)。
MigrateSettingsIfNeeded() {
    global SettingsMap, SettingsDirty, SettingDefs, ClipWatchOn, ClipArchiveImage, ClipArchiveText
    path := A_ScriptDir . "\settings.ini"
    if FileExist(path)
        return
    try {
        sitesPath := A_ScriptDir . "\sites.ini"
        if FileExist(sitesPath) {
            bak := A_ScriptDir . "\sites.ini.bak-" . FormatTime(, "yyyyMMdd")
            if !FileExist(bak)
                FileCopy(sitesPath, bak)
        }
        ; LoadSitesConfig()はこの時点で既に実行済みなので、グローバル変数の現在値をそのまま引き継ぐ
        SettingsMap["clipboard.watch"] := ClipWatchOn ? "on" : "off"
        SettingsMap["archive.image"] := ClipArchiveImage ? "on" : "off"
        SettingsMap["archive.text"] := ClipArchiveText ? "on" : "off"
        flagPath := A_ScriptDir . "\startup-prompted.flag"
        if FileExist(flagPath) {
            SettingsMap["state.firstrunprompted"] := "1"
            FileDelete(flagPath)
        }
        SettingsDirty := true
        FlushSettings()
    } catch as e {
        Flash("設定ファイルの初期化に失敗しました(既定値のまま起動します)", 2000)
    }
}

; ベースフォルダ(サブフォルダ分けなし)。ArchiveSubDirはこの配下にscreenshot/history/templateを作る
ArchiveBaseDir() {
    global ClipArchiveDir
    return (ClipArchiveDir != "") ? ClipArchiveDir : A_ScriptDir . "\clip-archive"
}

; サブフォルダ("screenshot"|"history"|"template")を解決＋作成。
; 作れなければ空文字を返し呼び出し元で保存をスキップする(fail-closed)
ArchiveSubDir(sub) {
    dir := ArchiveBaseDir() . "\" . sub
    try DirCreate(dir)
    return DirExist(dir) ? dir : ""
}

; トレイ「保存フォルダを開く」用。まだ何も保存されていなければ新規作成せず案内する
OpenArchiveDir(*) {
    dir := ArchiveBaseDir()
    if DirExist(dir)
        Run('explorer.exe "' . dir . '"')
    else
        Flash("まだ何も保存されていません", 1800)
}

; PNGエンコーダをGdipGetImageEncodersで列挙して探す(CLSID直指定より環境差異に強い)
PngEncoderClsid() {
    DllCall("gdiplus\GdipGetImageEncodersSize", "UInt*", &count := 0, "UInt*", &size := 0)
    if !size
        return 0
    buf := Buffer(size)
    if DllCall("gdiplus\GdipGetImageEncoders", "UInt", count, "UInt", size, "Ptr", buf)
        return 0
    ; PNGのCLSIDはGDI+仕様上の既知の固定値(Microsoft公式ドキュメントで確認済み)
    clsid := Buffer(16)
    DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
    return clsid
}

; CF_DIB→BMPファイル(BITMAPFILEHEADER14B+DIB丸書き)。PNG保存の失敗時フォールバック。
SaveDibAsBmp(dib, path) {
    off := DibBitsOffset(dib)
    if !off
        return false
    hdr := Buffer(14, 0)
    NumPut("UShort", 0x4D42, hdr, 0)          ; "BM"
    NumPut("UInt", 14 + dib.Size, hdr, 2), NumPut("UInt", 14 + off, hdr, 10)
    try {
        f := FileOpen(path, "w")
        f.RawWrite(hdr, 14), f.RawWrite(dib, dib.Size), f.Close()
        return true
    } catch
        return false
}

; CF_DIB→PNGファイル。既存MakeHistThumbと同じStretchDIBits経由でHBITMAP化してからGDI+化する
; (CF_DIBから直接GdipCreateBitmapFromGdiDibを使わず、既存資産と手法を揃える)。失敗時はBMPへ。
SaveDibAsPng(dib, w, h, path) {
    static gdipToken := 0
    off := DibBitsOffset(dib)
    if !off
        return SaveDibAsBmp(dib, StrReplace(path, ".png", ".bmp"))
    if !gdipToken {
        DllCall("LoadLibrary", "Str", "gdiplus")
        si := Buffer(A_PtrSize = 8 ? 24 : 16, 0), NumPut("UInt", 1, si)
        if !DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdipToken := 0, "Ptr", si, "Ptr", 0)
            return SaveDibAsBmp(dib, StrReplace(path, ".png", ".bmp"))
    }
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
            if clsid
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

; テキストの検疫キュー投入。ClipAutoClearSec+2秒を過ぎたものだけCommitPendingArchiveが書く。
; この待ち時間こそが「パスワードマネージャの自動クリアがディスク書き込みを止める」仕組みの核心。
QueueTextArchive(text) {
    global PendingArchive
    PendingArchive.Push({text: text, tick: A_TickCount})
    SetTimer(CommitPendingArchive, 5000)
}

CommitPendingArchive() {
    global PendingArchive, ClipAutoClearSec
    windowMs := ClipAutoClearSec * 1000 + 2000   ; +2秒: クリア通知との競合マージン
    i := 1
    while (i <= PendingArchive.Length) {
        p := PendingArchive[i]
        if (A_TickCount - p.tick >= windowMs) {
            dir := ArchiveSubDir("history")
            if (dir != "") {
                path := dir . "\history-" . FormatTime(, "yyyy-MM-dd") . ".csv"
                isNew := !FileExist(path)
                try {
                    out := isNew ? Chr(0xFEFF) . "time,text`r`n" : ""   ; 新規時のみUTF-8 BOM+ヘッダ
                    out .= CsvField(FormatTime(, "HH:mm:ss")) . "," . CsvField(p.text) . "`r`n"
                    FileAppend(out, path, "UTF-8")
                }
            }
            PendingArchive.RemoveAt(i)
        } else
            i++
    }
    if (PendingArchive.Length = 0)
        SetTimer(CommitPendingArchive, 0)
}

; --- 設定ウィンドウ（フォルダ保存のON/OFFをチェックボックスで一望できる専用画面） ---
; トレイメニューは項目名を読まないと何が起きるか分からない、という声を受けて新設。
; チェックボックス+短い説明文を並べるだけの単一画面。SnipMgrGuiと同じシングルトンパターン。
global SettingsGui := 0, SettingsChkImage := 0, SettingsChkText := 0, SettingsChkStartup := 0, SettingsChkWatch := 0

ShowSettingsWindow(*) {
    global SettingsGui, SettingsChkImage, SettingsChkText, SettingsChkStartup, SettingsChkWatch, ClipArchiveImage, ClipArchiveText, ClipWatchOn
    if SettingsGui {
        SettingsChkImage.Value := ClipArchiveImage
        SettingsChkText.Value := ClipArchiveText
        SettingsChkStartup.Value := IsStartupRegistered()
        SettingsChkWatch.Value := ClipWatchOn
        SettingsGui.Show()
        return
    }
    SettingsGui := Gui("+ToolWindow", "設定")
    SettingsGui.SetFont("s9", "Meiryo UI")

    SettingsGui.Add("GroupBox", "x10 y10 w380 h74", "基本")
    SettingsChkStartup := SettingsGui.Add("CheckBox", "x20 y32 w360", "Windows起動時に自動実行する")
    SettingsChkStartup.Value := IsStartupRegistered()
    SettingsChkStartup.OnEvent("Click", (*) => ApplyStartupToggle(SettingsChkStartup))
    SettingsChkWatch := SettingsGui.Add("CheckBox", "x20 y56 w360", "クリップボード監視を有効にする")
    SettingsChkWatch.Value := ClipWatchOn
    SettingsChkWatch.OnEvent("Click", (*) => ApplyClipWatchToggle(SettingsChkWatch))

    SettingsGui.Add("GroupBox", "x10 y92 w380 h130", "フォルダ保存（既定はOFF・保存すると元に戻せません）")
    SettingsChkImage := SettingsGui.Add("CheckBox", "x20 y114 w360", "スクショ（コピーした画像）をフォルダに保存する")
    SettingsChkImage.Value := ClipArchiveImage
    SettingsChkImage.OnEvent("Click", (*) => ApplyArchiveToggle("image", SettingsChkImage))
    SettingsGui.Add("Text", "x38 y134 w340 h16 cGray", "保存先: clip-archive\screenshot（PNG形式）")

    SettingsChkText := SettingsGui.Add("CheckBox", "x20 y160 w360", "テキストのコピー履歴をフォルダに保存する")
    SettingsChkText.Value := ClipArchiveText
    SettingsChkText.OnEvent("Click", (*) => ApplyArchiveToggle("text", SettingsChkText))
    SettingsGui.Add("Text", "x38 y180 w340 h32 cGray",
        "保存先: clip-archive\history（CSV形式）`nパスワード等を扱う際はOFFのままにしてください")

    SettingsGui.Add("Button", "x20 y232 w150 h28", "保存フォルダを開く").OnEvent("Click", OpenArchiveDir)
    SettingsGui.Add("Button", "x290 y232 w100 h28", "閉じる").OnEvent("Click", (*) => SettingsGui.Hide())
    ; ブランドロゴ: 他ウィンドウ(定型文の管理)と同じ流儀でフッターに控えめに配置。読み込み失敗は握りつぶす
    try SettingsGui.Add("Picture", "x20 y270 w58 h36", A_ScriptDir . "\kimitolink-full-logo.png")
    SettingsGui.OnEvent("Close", (*) => SettingsGui.Hide())
    SettingsGui.OnEvent("Escape", (*) => SettingsGui.Hide())
    SettingsGui.Show("w400 h316")
}

; 設定ウィンドウのチェックボックスから起動登録を切り替える。トレイに同項目はない(v1.13.0で設定ウィンドウへ一本化)ため
; ラベル同期は不要。EnableStartup/DisableStartupは初回起動確認ダイアログとも共有する。
ApplyStartupToggle(chk) {
    IsStartupRegistered() ? DisableStartup() : EnableStartup()
    chk.Value := IsStartupRegistered()
}

; 設定ウィンドウのチェックボックスからクリップボード監視を切り替える。トレイのToggleClipWatchと状態を共有する。
; ランチャー歯車メニューは開くたびにClipWatchOnの現在値からCheck状態を作り直すため、ここでは触らない。
ApplyClipWatchToggle(chk) {
    global ClipWatchOn
    ClipWatchOn := chk.Value
    SetSetting("clipboard.watch", ClipWatchOn ? "on" : "off")
    ClipWatchOn ? A_TrayMenu.Uncheck("クリップボード監視を一時停止") : A_TrayMenu.Check("クリップボード監視を一時停止")
    Flash(ClipWatchOn ? "クリップボード監視: 再開" : "クリップボード監視: 一時停止", 1200)
}

; 設定ウィンドウのチェックボックスから呼ばれる。ON時は警告→同意→トレイ側と同じ永続化。
; チェックボックスは操作の起点であると同時に表示状態でもあるため、拒否時は元の値へ戻す。
ApplyArchiveToggle(kind, chk) {
    global ClipArchiveImage, ClipArchiveText
    turningOn := chk.Value
    if turningOn {
        msg := (kind = "image")
            ? "コピーした画像がディスク上のファイルに残るようになります。`n有効にしますか？"
            : "コピーしたテキストがディスク上のファイルに残るようになります。`n"
                . "パスワード等を扱う際はOFFのままにしてください。`n`n有効にしますか？"
        if (MsgBox(msg, "フォルダ保存の確認", "YesNo Icon!") != "Yes") {
            chk.Value := 0                    ; 拒否時はチェックを戻す
            return
        }
    }
    if (kind = "image")
        SetSetting("archive.image", turningOn ? "on" : "off")
    else
        SetSetting("archive.text", turningOn ? "on" : "off")
    Flash(turningOn ? "フォルダ保存: ON" : "フォルダ保存: OFF")
}

; 検疫中(未確定)の項目は保存せず終了する。fail-closed: 「終了直前のコピーが保存されない」より
; 「終了直前のパスワードがディスクに残る」方が重い、という判断(G節参照)。
DiscardPendingArchiveOnExit(*) {
    global PendingArchive
    PendingArchive := []
}

; 300msデバウンス中に終了すると変更が失われるため、終了直前に未反映分を同期的に書き切る。
FlushSettingsOnExit(*) {
    SetTimer(FlushSettings, 0)   ; 保留中のデバウンスタイマーを解除してから即時書き込み
    FlushSettings()
}

; 画像要素1件→ImageListへ追加し0始まりindexを返す。失敗は-1(プレースホルダー表示のまま)
; 等倍HBITMAPを一度も作らず、CF_DIBバッファから48x48へ直接縮小描画する(StretchDIBits)。
MakeHistThumb(v) {
    global HistThumbIL
    static TW := 48, TH := 48, SRCCOPY := 0x00CC0020, HALFTONE := 4, WHITE_BRUSH := 0
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

HistThumbIndex(v) {                        ; 生成は要素につき1回。以後はキャッシュ(失敗は再試行のためキャッシュしない)
    if !v.HasOwnProp("thumbIdx")
        v.thumbIdx := MakeHistThumb(v)
    if (v.thumbIdx = -1)
        v.DeleteProp("thumbIdx")           ; 次回オープン時に再試行(一時的なGDIリソース不足からの回復を期待)
    return v.thumbIdx
}

; クリップボードを開かずに判定できるためコールバック内でも安全
ClipHasIgnoreFormat() {
    static fmts := [DllCall("RegisterClipboardFormat", "Str", "Clipboard Viewer Ignore", "UInt"),
                    DllCall("RegisterClipboardFormat", "Str", "ExcludeClipboardContentFromMonitorProcessing", "UInt")]
    for f in fmts
        if (f && DllCall("IsClipboardFormatAvailable", "UInt", f))
            return true
    return false
}

ClipSourceExcluded() {
    global ClipExcludeExes
    exe := ""
    if (hwnd := DllCall("GetClipboardOwner", "Ptr")) {
        DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid := 0)
        try exe := StrLower(ProcessGetName(pid))
    }
    if (exe = "")
        try exe := StrLower(WinGetProcessName("A"))
    return exe != "" && ClipExcludeExes.Has(exe)
}

MaybeDropAutoCleared() {
    global ClipHistory, LastCaptureText, LastCaptureTick, ClipAutoClearSec, PendingArchive
    if (LastCaptureText = "" || A_TickCount - LastCaptureTick > ClipAutoClearSec * 1000)
        return
    for i, v in ClipHistory
        if (v.type = "text" && v.text = LastCaptureText) {   ; 画像のプレースホルダーと誤爆させない
            ClipHistory.RemoveAt(i)
            Flash("自動クリアを検知したため履歴とフォルダ保存予約からも削除しました", 1500)
            break
        }
    ; 検疫待ちのフォルダ保存予約も同時に取り消す(メモリとディスク行きを同時に守る。D節の核心)
    i := 1
    while (i <= PendingArchive.Length)
        (PendingArchive[i].text = LastCaptureText) ? PendingArchive.RemoveAt(i) : i++
    LastCaptureText := ""
}

CheckLauncherFocus() {
    global LauncherGui
    if !IsObject(LauncherGui) {
        SetTimer(CheckLauncherFocus, 0)
        return
    }
    if !WinActive("ahk_id " . LauncherGui.Hwnd)
        CloseLauncher()
}

CloseLauncher() {
    global LauncherGui
    SetTimer(CheckLauncherFocus, 0)
    SetTimer(LauncherWatchDrag, 0)
    SetTimer(LauncherWatchHover, 0), ToolTip()
    if IsObject(LauncherGui) {
        try LauncherGui.Destroy()
        LauncherGui := 0
    }
}

; 掴みしろ監視: バー領域内での左クリック押下を検知したら手動ドラッグループへ
; （その場での見やすい位置への移動はできるが、次回起動時はCliborと同じく常にカーソル位置に開き直す）
LauncherWatchDrag() {
    global LauncherGui, LauncherDragBar
    if !(IsObject(LauncherGui) && IsObject(LauncherDragBar) && GetKeyState("LButton", "P"))
        return
    MouseGetPos &mx, &my
    LauncherDragBar.GetPos(&bx, &by, &bw, &bh)
    LauncherGui.GetPos(&gx, &gy)
    if !(mx >= gx + bx && mx <= gx + bx + bw && my >= gy + by && my <= gy + by + bh)
        return
    winX := gx, winY := gy, startMx := mx, startMy := my
    while GetKeyState("LButton", "P") {
        if !IsObject(LauncherGui)   ; ドラッグ中にCloseLauncher()で破棄された場合(フォーカス喪失等)
            return
        MouseGetPos &mx2, &my2
        try LauncherGui.Move(winX + (mx2 - startMx), winY + (my2 - startMy))
        catch
            return   ; チェック直後にDestroyされた場合(単一スレッドのAHKでは稀だが念のため)
        Sleep 15
    }
}

; マウス直下のListBox項目番号(1始まり)。項目外・末尾より下の空白部は0。（定型文タブ用）
LauncherItemUnderMouse(lb) {
    MouseGetPos &mx, &my
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " . lb.Hwnd)
    if (mx < cx || mx >= cx + cw || my < cy || my >= cy + ch)
        return 0
    ih := SendMessage(0x1A1, 0, 0, , "ahk_id " . lb.Hwnd)
    idx := (ih > 0) ? SendMessage(0x18E, 0, 0, , "ahk_id " . lb.Hwnd) + (my - cy) // ih + 1 : 0
    return (idx < 1 || idx > SendMessage(0x18B, 0, 0, , "ahk_id " . lb.Hwnd)) ? 0 : idx
}

; マウス直下のListView行番号(1始まり)。行外は0。LB版(LauncherItemUnderMouse)のLV版（履歴タブ用）。
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

; ホバー監視: 直下項目の全文(+履歴は時刻)をToolTip表示。hwnd比較ではなく座標の直接判定で決める
; （MouseGetPosのControl出力はClassNN文字列でありHwndと直接比較できないため）
LauncherWatchHover() {
    global LauncherGui, LauncherLvH, LauncherLbS, LauncherHoverLast, ClipHistory, Snippets, LauncherTab
    if !IsObject(LauncherGui)
        return
    tip := ""
    ; Tab3は非アクティブなタブの子コントロールも実体を保持し続けるため、アクティブタブでヒットテストを
    ; 限定しないと、履歴タブ表示中でも裏に隠れた定型文ListBoxの内容がツールチップに出てしまう。
    if (LauncherTab.Value = 1) {
        if (idx := ResolveHistRow(LauncherLVItemUnderMouse(LauncherLvH))) && idx <= ClipHistory.Length
            tip := ClipHistory[idx].time . " にコピー`n" . SubStr(ClipHistory[idx].text, 1, 600)
    } else {
        if (idx := ResolveSnipRow(LauncherItemUnderMouse(LauncherLbS))) && idx <= Snippets.Length
            tip := SubStr(Snippets[idx].value, 1, 600)
    }
    if (tip != LauncherHoverLast) {
        LauncherHoverLast := tip
        ToolTip(tip)
    }
}

; 右クリック: 履歴項目=メニュー（開く・昇格・削除）
LauncherContextMenu(g, ctrl, item, isRC, x, y) {
    global LauncherLvH, ClipHistory, LauncherGui
    if (ctrl = LauncherLvH) {
        idx := ResolveHistRow(LauncherLVItemUnderMouse(LauncherLvH))
        if (idx < 1 || idx > ClipHistory.Length)
            return
        SetTimer(CheckLauncherFocus, 0)       ; メニュー表示中の誤クローズ防止(必須)
        m := Menu()
        if (ClipHistory[idx].type = "text") {
            if (p := RunnablePathFrom(ClipHistory[idx].text))
                m.Add(InStr(FileExist(p), "D") ? "このフォルダを開く" : "このファイルを開く", (*) => OpenHistoryPath(p))
            m.Add("定型文に登録", (*) => PromoteHistoryAt(idx))   ; 画像はsnippets.ini非対応のため出さない
        }
        m.Add("この履歴を削除", (*) => DeleteHistoryAt(idx))
        m.Add("履歴を全削除", (*) => DeleteHistoryAll())
        m.Show()
        if IsObject(LauncherGui)
            SetTimer(CheckLauncherFocus, 150)
    }
}

; 履歴テキストが「実在するローカルのドライブレター絶対パス」のときだけ正規化して返す。
; UNC(\\server)・相対パス・複数行・存在しないパスはすべて空を返す(fail-closed)。
RunnablePathFrom(text) {
    p := Trim(text, " `t`r`n`"'")
    if InStr(p, "`n") || StrLen(p) > 500
        return ""
    if !RegExMatch(p, "i)^[a-z]:\\")
        return ""
    return FileExist(p) ? p : ""
}

OpenHistoryPath(p) {
    CloseLauncher()
    if InStr(FileExist(p), "D") {
        try Run('explorer.exe "' . p . '"')
        return
    }
    if RegExMatch(p, "i)\.(exe|bat|cmd|com|ps1|vbs|js|wsf|msi|scr|lnk)$") {
        if (MsgBox("これはプログラムです。実行しますか？`n`n" . p, "履歴から実行", "YesNo Icon! Default2") != "Yes")
            return
    }
    try Run('"' . p . '"')
    catch
        Flash("開けませんでした: " . p, 1800)
}

DeleteHistoryAt(idx) {
    global ClipHistory
    if (idx >= 1 && idx <= ClipHistory.Length)
        ClipHistory.RemoveAt(idx)
    RefreshLauncherHistory()
}

DeleteHistoryAll(*) {                          ; トレイメニューからも呼ぶため可変引数
    global ClipHistory, PendingArchive
    ClipHistory := []
    PendingArchive := []                       ; 検疫待ちのフォルダ保存予約も同時に破棄
    RefreshLauncherHistory()
    Flash("履歴を全削除しました", 1200)
}

ToggleClipWatch(name, *) {
    global ClipWatchOn, SettingsGui, SettingsChkWatch
    ClipWatchOn := !ClipWatchOn
    SetSetting("clipboard.watch", ClipWatchOn ? "on" : "off")
    ClipWatchOn ? A_TrayMenu.Uncheck(name) : A_TrayMenu.Check(name)
    if SettingsGui
        SettingsChkWatch.Value := ClipWatchOn
    Flash(ClipWatchOn ? "クリップボード監視: 再開" : "クリップボード監視: 一時停止", 1200)
}

RefreshLauncherHistory() {
    global LauncherGui, LauncherLvH, LauncherTab, ClipHistory, LauncherSearchEdit
    if !IsObject(LauncherGui)
        return
    q := IsObject(LauncherSearchEdit) ? Trim(LauncherSearchEdit.Value) : ""
    FillLauncherHistoryLV(LauncherLvH, q)   ; 検索中の追加/削除でも絞り込み語を維持する
    SetTabLabel(LauncherTab, 1, "履歴 " . ClipHistory.Length)
}

; Tab3のタブ見出しを生成後に書き換える。AHK v2にはGui.Tabの見出し変更メソッドが無いため
; TCM_SETITEMをネイティブに叩く(AHKは常にUnicodeビルドなのでA/W区別不要)。
; TCITEMW構造体(64bit): mask(4)+dwState(4)+dwStateMask(4)+pad(4)
; +pszText(8,ptr,offset16)+cchTextMax(4)+iImage(4)+pad(4)+lParam(8,ptr) = 40バイト。
; TCM_FIRST=0x1300、TCM_SETITEM=TCM_FIRST+61=0x133D(Microsoft Learn commctrl.hで裏取り済み)。
SetTabLabel(tabCtrl, index, text) {
    static TCIF_TEXT := 0x1, TCM_SETITEM := 0x133D
    tcitem := Buffer(40, 0)
    NumPut("UInt", TCIF_TEXT, tcitem, 0)               ; mask
    NumPut("Ptr", StrPtr(text), tcitem, 16)             ; pszText
    SendMessage(TCM_SETITEM, index - 1, tcitem.Ptr, tabCtrl)   ; 0-based index
}

; ShowLauncherのListBox初期化とLauncherFilterChangedで共用。ラベル/本文どちらかに部分一致すれば残す。
; ClipHistory側のFillLauncherHistoryLVと同じ「表示行→実インデックス」マップ方式。
FillLauncherSnippetsLB(lb, query := "") {
    global Snippets, LauncherSnipFilterMap
    LauncherSnipFilterMap := []
    items := []
    for i, s in Snippets {
        if (query != "" && !InStr(s.label, query) && !InStr(s.value, query))
            continue
        LauncherSnipFilterMap.Push(i)
        dispRow := LauncherSnipFilterMap.Length
        items.Push((dispRow <= 10 ? Mod(dispRow, 10) . " " : "   ") . (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . s.label)
    }
    lb.Delete()
    if (items.Length)
        lb.Add(items)
}

; ShowLauncherとRefreshLauncherHistoryで共用。11件目以降は番号なし(数字キー対象外)。
; Icon0省略不可(省略すると全行に1枚目が出る既知の仕様。SnipMgrHistRefreshと同じ)
; query != ""のときは本文に部分一致する行だけを表示し、LauncherHistFilterMapに
; 「表示行(1始まり) → ClipHistoryの実インデックス」を積む。数字キー/クリック選択は
; 表示行番号で来るため、呼び出し側(PasteHistoryAt等)の手前でこのマップを経由して実インデックスへ変換する。
FillLauncherHistoryLV(lv, query := "") {
    global ClipHistory, LauncherHistFilterMap
    lv.Opt("-Redraw")
    lv.Delete()
    LauncherHistFilterMap := []
    dispRow := 0
    for i, v in ClipHistory {
        s := RegExReplace(v.text, "\s+", " ")
        if (query != "" && !InStr(s, query))
            continue
        dispRow += 1
        LauncherHistFilterMap.Push(i)
        txt := (dispRow <= 10 ? Mod(dispRow, 10) . " " : "   ") . (StrLen(s) > 58 ? SubStr(s, 1, 58) . "…" : s)
        lv.Add((v.type = "image") ? "Icon" . (HistThumbIndex(v) + 1) : "Icon0", txt)
    }
    lv.Opt("+Redraw")
}

; 履歴→定型文昇格。IniWriteは使わず、UTF-8明示のFileAppendで追記する
PromoteHistoryAt(idx) {
    global ClipHistory
    if (idx < 1 || idx > ClipHistory.Length || ClipHistory[idx].type != "text")
        return                                 ; 画像はsnippets.ini非対応(メニュー非表示と二重の防御)
    text := ClipHistory[idx].text
    CloseLauncher()
    ib := InputBox("この内容を定型文に登録します。名前を入力:", "定型文に昇格", "w380 h120", SubStr(RegExReplace(text, "\s+", " "), 1, 12))
    label := (ib.Result = "OK") ? RegExReplace(Trim(ib.Value), "[=\[\];]") : ""
    if (label = "")
        return
    body := StrReplace(StrReplace(text, "`r`n", "`n"), "`n", "\n")
    path := A_ScriptDir . "\snippets.ini"
    try {
        nl := (FileExist(path) && !RegExMatch(FileRead(path, "UTF-8"), "\R$")) ? "`n" : ""
        FileAppend(nl . label . "=" . body . "`n", path, "UTF-8")
        ArchiveSnippetsCsv()                  ; 定型文フォルダ保存(ONの場合のみ)
        Flash("定型文に登録しました: " . label, 1800)
    } catch as e {
        Flash("登録に失敗しました: " . e.Message, 2000)
    }
}

LauncherPickKey(hk, *) {
    n := (hk = "0") ? 10 : Integer(hk)
    if (LauncherTab.Value = 1)
        PasteHistoryAt(ResolveHistRow(n))
    else
        UseSnippetAt(ResolveSnipRow(n))
}

; --- 起動時 ---
LoadSitesConfig()
SettingDefsInit()
if FileExist(A_ScriptDir . "\settings.ini")
    LoadSettingsIni()
else
    MigrateSettingsIfNeeded()   ; sites.ini/startup-prompted.flagから現在有効値を吸い上げsettings.iniを初回生成
OnClipboardChange(ClipChanged)
; 検疫中の未確定項目は書かずに終了する(fail-closed)。PendingArchiveは単なるメモリ配列なので
; プロセス終了で自然に消えるが、意図を明示するためOnExitで明示クリアする。
OnExit(DiscardPendingArchiveOnExit)
OnExit(FlushSettingsOnExit)
; 数字キー1-9,0=10: ランチャーがアクティブな間だけ有効（HotIfスコープ限定・解除処理は不要）
HotIf (*) => IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)
Loop 10
    Hotkey Mod(A_Index, 10) . "", LauncherPickKey
HotIf
EnsureStartMenuShortcut()   ; トースト通知アイコンのためのAUMID登録(TrayTipより前に実行する必要がある)
TrayTip("送信サジェスト", "常駐を開始しました", "Mute")

; トレイメニューに監視トグル・バージョン表示を追加。自動起動のON/OFFは設定ウィンドウに一本化(v1.13.0〜)。
A_TrayMenu.Add("クリップボード監視を一時停止", ToggleClipWatch)
A_TrayMenu.Add("クリップボード履歴を全削除", DeleteHistoryAll)
A_TrayMenu.Add("定型文の管理...", ShowSnippetManager)
A_TrayMenu.Add("定型文ファイルを編集 (snippets.ini)", EditSnippetsFile)   ; 上級者向け(生のiniを直接編集)。通常は上のGUIで足りる
A_TrayMenu.Add()  ; セパレータ
; 非永続の原則の例外(既定OFF・オプトイン)。経緯は_docs/CLIPBOARD-HISTORY-FOLDER-ARCHIVE-DESIGN.md参照
; トレイ項目名だけでは何が起きるか分からないという声を受け、専用の設定ウィンドウに集約。
A_TrayMenu.Add("設定...", ShowSettingsWindow)
A_TrayMenu.Add()  ; セパレータ
A_TrayMenu.Add("設定フォルダを開く", (*) => Run('explorer.exe "' . A_ScriptDir . '"'))
A_TrayMenu.Add("診断情報をコピー", CopyDiagnostics)   ; AIチャットに貼るための計器ダンプ(履歴本文は含まない)
A_TrayMenu.Add()  ; セパレータ
A_TrayMenu.Add("v" . AppVersion, (*) => 0), A_TrayMenu.Disable("v" . AppVersion)
A_TrayMenu.Add()  ; セパレータ

; 初回起動時（スタートアップ未登録かつ確認未表示）は自動実行を促す
if !IsStartupRegistered() && !SettingsMap.Has("state.firstrunprompted") {
    SetSetting("state.firstrunprompted", "1")
    result := MsgBox("次回からWindows起動時に自動で立ち上げますか？`n（あとからトレイの「設定...」でいつでも切り替えられます）",
        "送信サジェスト", "YesNo Icon?")
    if (result = "Yes")
        EnableStartup()
}
