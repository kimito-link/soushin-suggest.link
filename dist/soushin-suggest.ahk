#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"
; ============================================================
;  送信サジェスト / soushin-suggest.link
;  なぞってコピー・右クリック長押しで送信・サイドボタンでスクショ
;  Windows 10/11 対応・買い切り・追加課金なし
; ============================================================
;  左クリック（ドラッグ）  -> 選択範囲を自動コピー（対応アプリのみ）
;  右クリック長押し(0.35s) -> サイトに合った送信キーを送る（短押しは通常の右クリック）
;  サイドボタン(戻る)      -> 短押し=全画面スクショ / 長押し=クイックペースト（全アプリ）
;  ミドルクリック           -> Git Bash を前面へ（無ければ起動）
;  Ctrl+Win+C              -> なぞってコピーのON/OFF切り替え
;  Ctrl+Win+V              -> クイックペーストを開く（マウスなしでも呼び出せる）
;  対応アプリ・送信ルールは sites.ini、定型文は snippets.ini で編集できます（同梱）。
;  トレイのアイコンを右クリック -> Suspend Hotkeys / Exit

global CopyOnSelect := true, dragX := 0, dragY := 0, dragT := 0
global SitesConfig := Map()
global SiteRules := []
global ClipHistory := [], ClipHistoryMax := 30   ; {text,time}の配列・メモリのみ・非永続 — 永続化禁止(唯一の安全特性。エクスポートも不可。経緯は_docs参照)
global LongPressSec := 0.35     ; sites.ini [general] longpress= で上書き可
global LauncherGui := 0, LauncherTarget := 0, LauncherTab := 0, Snippets := [], LauncherDragBar := 0, LauncherPos := "", LauncherPinned := false, LauncherLbH := 0, LauncherLbS := 0, LauncherHoverLast := ""
global ClipWatchOn := true                ; トレイから一時停止可
global LastUserCopyTick := 0              ; ^c/^x/^Ins・なぞってコピー送信の時刻
global LastLButtonUpTick := 0             ; 右クリックメニュー「コピー」等のクリック由来を救う
global SelfClipTick := 0                  ; 自分がA_Clipboardへ書いた時刻(監視除外)
global LastCaptureText := "", LastCaptureTick := 0   ; 自動クリア検知用
global ClipUserWindowMs := 1000           ; ユーザー操作限定フィルタの窓(iniに出さない・固定)
global ClipAutoClearSec := 45, ClipMaxLen := 100000
global ClipExcludeExes := Map("keepass.exe",1, "keepassxc.exe",1, "1password.exe",1, "bitwarden.exe",1)
global ClipImageMax := 5, ClipImageMaxBytes := 36 * 1024 * 1024   ; 画像専用の件数上限・4Kスクショ程度まで許容

Flash(msg, ms := 1500) {
    ToolTip(msg)
    SetTimer () => ToolTip(), -ms
}

; --- load sites.ini (per-app rules + [sites] title-keyword rules) ---
; IniReadは使わない: 非ASCIIキーをUTF-16 LE以外で誤読する既知の問題があり、[sites]は日本語キーワードを扱うため
LoadSitesConfig() {
    global SitesConfig, SiteRules, LongPressSec, ClipWatchOn, ClipHistoryMax, ClipAutoClearSec, ClipExcludeExes, ClipImageMax, ClipImageMaxBytes
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
global StartupMenuLabel := ""

StartupShortcutPath() => A_Startup . "\soushin-suggest.lnk"
IsStartupRegistered() => FileExist(StartupShortcutPath()) ? true : false
StartupLabelFor(registered) => registered ? "Windows起動時に自動実行: ON" : "Windows起動時に自動実行: OFF"

EnableStartup() {
    try FileCreateShortcut(A_ScriptFullPath, StartupShortcutPath(), A_ScriptDir), Flash("次回のWindows起動時から自動で立ち上がります", 1800)
    catch as e
        Flash("スタートアップ登録に失敗しました: " . e.Message, 2000)
}

DisableStartup() {
    try FileDelete(StartupShortcutPath()), Flash("自動起動を解除しました", 1800)
}

ToggleStartup(*) {
    IsStartupRegistered() ? DisableStartup() : EnableStartup()
    RefreshStartupMenuLabel()
}

RefreshStartupMenuLabel() {
    global StartupMenuLabel
    newLabel := StartupLabelFor(IsStartupRegistered())
    if (StartupMenuLabel != "" && StartupMenuLabel != newLabel)
        A_TrayMenu.Rename(StartupMenuLabel, newLabel)
    StartupMenuLabel := newLabel
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
    LastLButtonUpTick := A_TickCount          ; コンテキストメニュー由来のコピーを救う
    if !CopyOnSelect || !CopyOnSelectApp()
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
    global ClipHistory, ClipHistoryMax
    for i, v in ClipHistory
        if (v.type = "text" && v.text = text) {   ; 画像のプレースホルダー文字列と偶然一致しても誤爆しない
            ClipHistory.RemoveAt(i)   ; 重複は先頭へ昇格（時刻も更新される）
            break
        }
    ClipHistory.InsertAt(1, {type: "text", text: text, time: NowWithWeekday()})
    while (ClipHistory.Length > ClipHistoryMax)
        ClipHistory.Pop()
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

; --- サイドボタン(戻る): 短押し=スクショ / 長押し=クイックペースト（全アプリ） ---
XButton1:: {
    global LongPressSec, LastUserCopyTick
    if KeyWait("XButton1", "T" . LongPressSec) {
        LastUserCopyTick := A_TickCount        ; 自スクリプト発のSendはフックに乗らないため明示記録
        Send("#{PrintScreen}")
        return
    }
    KeyWait("XButton1")
    ShowLauncher()
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

; CSVフィールドとして安全な形にエスケープ（カンマ・改行・ダブルクォートを含む場合のみ囲む）
CsvField(s) {
    if InStr(s, '"') || InStr(s, ",") || InStr(s, "`n") || InStr(s, "`r")
        return '"' . StrReplace(s, '"', '""') . '"'
    return s
}

; 定型文をCSV(label,body)でエクスポート。他ツール(Excel等)との往復を想定した汎用形式。
; dlg=trueなら結果をCSVダイアログのステータス行に出す。falseならToolTip(Flash)。
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
        out := Chr(0xFEFF) . "label,body`r`n"   ; UTF-8 BOM付き(Excel文字化け対策)
        for s in items
            out .= CsvField(s.label) . "," . CsvField(s.value) . "`r`n"
        if FileExist(f)
            FileDelete(f)
        FileAppend(out, f, "UTF-8")
        msg := items.Length . " 件をCSVに書き出しました"
        dlg ? SetCsvStatus(msg) : Flash(msg, 1800)
    } catch as e {
        msg := "エクスポートに失敗しました: " . e.Message
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
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
    incoming := RegExMatch(f, "i)\.csv$") ? LoadSnippetsCsv(f) : LoadSnippets(f)
    if (incoming.Length = 0) {
        msg := "取り込める定型文が見つかりませんでした（ラベル=本文 の形式）"
        dlg ? SetCsvStatus(msg) : Flash(msg, 2000)
        return
    }
    path := A_ScriptDir . "\snippets.ini"
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
        msg := added . " 件を取り込みました（重複 " . (incoming.Length - added) . " 件はスキップ）"
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
    m.Add("定型文ファイルを編集 (snippets.ini)", EditSnippetsFile)
    m.Add("定型文の管理...", ShowSnippetManager)
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
    SnipMgrHistLV := SnipMgrGui.Add("ListView", "x10 y66 w580 h240 -Multi NoSort NoSortHdr +Grid",
        ["コピー日時", "本文"])
    SnipMgrHistLV.ModifyCol(1, 150), SnipMgrHistLV.ModifyCol(2, 400)
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
    q := Trim(SnipMgrHistEd.Value)
    SnipMgrHistRows := []
    SnipMgrHistLV.Delete()
    for v in ClipHistory {                       ; 配列は常に新しい順（PushClipHistoryが先頭挿入）
        if (q != "" && !InStr(v.text, q, false) && !InStr(v.time, q, false))
            continue
        SnipMgrHistRows.Push(v)                  ; インデックスでなく要素の参照を保持
        disp := StrReplace(StrReplace(v.text, "`r", ""), "`n", " ⏎ ")
        SnipMgrHistLV.Add(, v.time, SubStr(disp, 1, 100))
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

ShowLauncher() {
    global ClipHistory, LauncherGui, LauncherTarget, Snippets, LauncherTab, LauncherDragBar, LauncherPos, LauncherPinned, LauncherLbH, LauncherLbS, LauncherHoverLast, ClipWatchOn
    Snippets := LoadSnippets()                ; 開くたびに読む: iniを編集→次の長押しで即反映
    if (ClipHistory.Length = 0 && Snippets.Length = 0) {
        Flash("履歴がありません（コピーすると貯まります）", 1800)
        return
    }
    LauncherTarget := WinExist("A")
    CloseLauncher()
    LauncherGui := Gui("-Caption +AlwaysOnTop +ToolWindow +Border")
    LauncherGui.SetFont("s12", "Meiryo UI")
    LauncherDragBar := LauncherGui.Add("Text", "x0 y0 w380 h16 BackgroundD4DCE8 +0x100")  ; SS_NOTIFY相当をv2既定に加え、押下を明示検知
    gearBtn := LauncherGui.Add("Text", "x380 y0 w20 h16 BackgroundD4DCE8 cGray Center +0x100", "⚙")
    gearBtn.SetFont("s10")
    gearBtn.OnEvent("Click", ShowLauncherSettingsMenu)
    LauncherGui.Add("Text", "x400 y2 w60 h12 cGray", "v1.6.0").SetFont("s8")   ; 掴みしろの右隣にバージョン表示
    LauncherGui.SetFont("s12")
    LauncherTab := LauncherGui.Add("Tab3", "x0 y16 w460 -Wrap",
        ["履歴 " . ClipHistory.Length, "定型文 " . Snippets.Length])
    rows := Min(Max(ClipHistory.Length, Snippets.Length, 3), 10)
    LauncherTab.UseTab(1)
    LauncherLbH := LauncherGui.Add("ListBox", "w440 r" . rows . " BackgroundF0F6FF", HistoryListItems())
    LauncherLbH.OnEvent("Change", (lb, *) => PasteHistoryAt(lb.Value))
    LauncherTab.UseTab(2)
    snipItems := []
    for i, s in Snippets
        snipItems.Push((i <= 10 ? Mod(i, 10) . " " : "   ") . (SubStr(s.value, 1, 4) = "run:" ? "▶ " : "") . s.label)
    LauncherLbS := LauncherGui.Add("ListBox", "w440 r" . rows . " BackgroundFFF9E6", snipItems)
    LauncherLbS.OnEvent("Change", (lb, *) => UseSnippetAt(lb.Value))
    LauncherTab.UseTab()
    if (ClipHistory.Length = 0)
        LauncherTab.Value := 2                        ; 履歴が空なら定型文タブで開く
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
    MouseGetPos &mx, &my
    LauncherGui.Show(LauncherPos != "" ? "x" . LauncherPos.x . " y" . LauncherPos.y : "x" . mx . " y" . my)
    WinActivate("ahk_id " . LauncherGui.Hwnd)
    SetTimer(CheckLauncherFocus, 150)
    SetTimer(LauncherWatchDrag, 30)
    LauncherHoverLast := "", SetTimer(LauncherWatchHover, 120)
}

PasteHistoryAt(idx) {
    global ClipHistory
    if (idx < 1 || idx > ClipHistory.Length)
        return
    v := ClipHistory[idx]
    CloseLauncher()
    (v.type = "image") ? PasteImage(v.dib) : PasteText(v.text)
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
    if (A_TickCount - SelfClipTick < 500)     ; PasteText/SetClipboardImage等の自己書き込み
        return
    if (type = 0) {                           ; クリア → 自動クリア検知
        MaybeDropAutoCleared()
        return
    }
    if (!ClipWatchOn)
        return
    if ClipHasIgnoreFormat()                  ; パスワードマネージャの標準除外フォーマット(テキスト/画像共通)
        return
    if (type = 1)
        SetTimer(CaptureClip, -120)           ; 多重発火デバウンス(最後の発火から120ms後に1回)
    else if (type = 2 && DllCall("IsClipboardFormatAvailable", "UInt", 8))  ; CF_DIB=8
        SetTimer(CaptureClipImage, -120)
}

CaptureClip() {
    global LastUserCopyTick, LastLButtonUpTick, ClipUserWindowMs, ClipMaxLen
    global LastCaptureText, LastCaptureTick
    now := A_TickCount
    ; ★核心の安全策: 直近1秒以内のユーザー操作がなければ捨てる(fail-closed)
    if (now - LastUserCopyTick > ClipUserWindowMs) && (now - LastLButtonUpTick > ClipUserWindowMs)
        return
    if ClipSourceExcluded()
        return
    text := ""
    try text := A_Clipboard                   ; 遅延レンダリング元が死んでいると失敗しうる
    if (text = "" || StrLen(text) > ClipMaxLen)
        return
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
    global LastUserCopyTick, LastLButtonUpTick, ClipUserWindowMs, ClipImageMaxBytes
    now := A_TickCount
    if (now - LastUserCopyTick > ClipUserWindowMs) && (now - LastLButtonUpTick > ClipUserWindowMs)
        return
    if ClipSourceExcluded()
        return
    dib := GetClipDib()
    if (!dib || dib.Size < 40 || dib.Size > ClipImageMaxBytes)   ; 40=BITMAPINFOHEADER最小
        return
    w := NumGet(dib, 4, "Int"), h := Abs(NumGet(dib, 8, "Int"))  ; biWidth/biHeight(トップダウンは負)
    PushClipImage(dib, w, h)
}

PushClipImage(dib, w, h) {
    global ClipHistory, ClipHistoryMax, ClipImageMax
    label := "📷 画像 " . w . "×" . h . " (" . Round(dib.Size / 1048576, 1) . "MB)"
    ClipHistory.InsertAt(1, {type: "image", text: label, dib: dib, w: w, h: h, time: NowWithWeekday()})
    n := 0
    for i, v in ClipHistory                   ; 画像専用上限: 古い画像から間引く
        if (v.type = "image" && ++n > ClipImageMax) {
            ClipHistory.RemoveAt(i)           ; RemoveAtでBufferの参照が切れ自動解放される
            break                             ; 1回の追加で超過は最大1件
        }
    while (ClipHistory.Length > ClipHistoryMax)
        ClipHistory.Pop()
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
    global ClipHistory, LastCaptureText, LastCaptureTick, ClipAutoClearSec
    if (LastCaptureText = "" || A_TickCount - LastCaptureTick > ClipAutoClearSec * 1000)
        return
    for i, v in ClipHistory
        if (v.type = "text" && v.text = LastCaptureText) {   ; 画像のプレースホルダーと誤爆させない
            ClipHistory.RemoveAt(i)
            Flash("自動クリアを検知したため履歴からも削除しました", 1500)
            break
        }
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
    global LauncherGui, LauncherPos, LauncherPinned
    SetTimer(CheckLauncherFocus, 0)
    SetTimer(LauncherWatchDrag, 0)
    SetTimer(LauncherWatchHover, 0), ToolTip()
    if IsObject(LauncherGui) {
        if LauncherPinned
            try WinGetPos(&x, &y, , , LauncherGui), LauncherPos := {x: x, y: y}
        try LauncherGui.Destroy()
        LauncherGui := 0
    }
}

; 掴みしろ監視: バー領域内での左クリック押下を検知したら手動ドラッグループへ
LauncherWatchDrag() {
    global LauncherGui, LauncherDragBar, LauncherPinned
    if !(IsObject(LauncherGui) && IsObject(LauncherDragBar) && GetKeyState("LButton", "P"))
        return
    MouseGetPos &mx, &my
    LauncherDragBar.GetPos(&bx, &by, &bw, &bh)
    LauncherGui.GetPos(&gx, &gy)
    if !(mx >= gx + bx && mx <= gx + bx + bw && my >= gy + by && my <= gy + by + bh)
        return
    LauncherPinned := true, winX := gx, winY := gy, startMx := mx, startMy := my
    while GetKeyState("LButton", "P") {
        MouseGetPos &mx2, &my2
        LauncherGui.Move(winX + (mx2 - startMx), winY + (my2 - startMy))
        Sleep 15
    }
}

; マウス直下のListBox項目番号(1始まり)。項目外・末尾より下の空白部は0。
LauncherItemUnderMouse(lb) {
    MouseGetPos &mx, &my
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " . lb.Hwnd)
    if (mx < cx || mx >= cx + cw || my < cy || my >= cy + ch)
        return 0
    ih := SendMessage(0x1A1, 0, 0, , "ahk_id " . lb.Hwnd)
    idx := (ih > 0) ? SendMessage(0x18E, 0, 0, , "ahk_id " . lb.Hwnd) + (my - cy) // ih + 1 : 0
    return (idx < 1 || idx > SendMessage(0x18B, 0, 0, , "ahk_id " . lb.Hwnd)) ? 0 : idx
}

; ホバー監視: 直下項目の全文(+履歴は時刻)をToolTip表示。hwnd比較ではなく座標の直接判定で決める
; （MouseGetPosのControl出力はClassNN文字列でありHwndと直接比較できないため）
LauncherWatchHover() {
    global LauncherGui, LauncherLbH, LauncherLbS, LauncherHoverLast, ClipHistory, Snippets
    if !IsObject(LauncherGui)
        return
    tip := ""
    if (idx := LauncherItemUnderMouse(LauncherLbH)) && idx <= ClipHistory.Length
        tip := ClipHistory[idx].time . " にコピー`n" . SubStr(ClipHistory[idx].text, 1, 600)
    else if (idx := LauncherItemUnderMouse(LauncherLbS)) && idx <= Snippets.Length
        tip := SubStr(Snippets[idx].value, 1, 600)
    if (tip != LauncherHoverLast) {
        LauncherHoverLast := tip
        ToolTip(tip)
    }
}

; 右クリック: 掴みしろ=固定解除 / 履歴項目=メニュー（開く・昇格・削除）
LauncherContextMenu(g, ctrl, item, isRC, x, y) {
    global LauncherDragBar, LauncherLbH, LauncherPos, LauncherPinned, ClipHistory, LauncherGui
    if (ctrl = LauncherDragBar) {
        LauncherPos := "", LauncherPinned := false
        Flash("固定を解除しました（次回からカーソル位置に表示）")
    } else if (ctrl = LauncherLbH) {
        idx := LauncherItemUnderMouse(LauncherLbH)
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
    global ClipHistory
    ClipHistory := []
    RefreshLauncherHistory()
    Flash("履歴を全削除しました", 1200)
}

ToggleClipWatch(name, *) {
    global ClipWatchOn
    ClipWatchOn := !ClipWatchOn
    ClipWatchOn ? A_TrayMenu.Uncheck(name) : A_TrayMenu.Check(name)
    Flash(ClipWatchOn ? "クリップボード監視: 再開" : "クリップボード監視: 一時停止", 1200)
}

RefreshLauncherHistory() {
    global LauncherGui, LauncherLbH
    if !IsObject(LauncherGui)
        return
    LauncherLbH.Delete()
    LauncherLbH.Add(HistoryListItems())
}

; ShowLauncherの履歴フォーマット部を関数化して共用。11件目以降は番号なし(数字キー対象外)
HistoryListItems() {
    global ClipHistory
    items := []
    for i, v in ClipHistory {
        s := RegExReplace(v.text, "\s+", " ")
        items.Push((i <= 10 ? Mod(i, 10) . " " : "   ") . (StrLen(s) > 58 ? SubStr(s, 1, 58) . "…" : s))
    }
    return items
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
        Flash("定型文に登録しました: " . label, 1800)
    } catch as e {
        Flash("登録に失敗しました: " . e.Message, 2000)
    }
}

LauncherPickKey(hk, *) {
    n := (hk = "0") ? 10 : Integer(hk)
    if (LauncherTab.Value = 1)
        PasteHistoryAt(n)
    else
        UseSnippetAt(n)
}

; --- 起動時 ---
LoadSitesConfig()
OnClipboardChange(ClipChanged)
; 数字キー1-9,0=10: ランチャーがアクティブな間だけ有効（HotIfスコープ限定・解除処理は不要）
HotIf (*) => IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)
Loop 10
    Hotkey Mod(A_Index, 10) . "", LauncherPickKey
HotIf
TrayTip("送信サジェスト", "常駐を開始しました", "Mute")

; トレイメニューに自動起動のON/OFF・監視トグル・バージョン表示を追加
StartupMenuLabel := StartupLabelFor(IsStartupRegistered())
A_TrayMenu.Add(StartupMenuLabel, ToggleStartup)
A_TrayMenu.Add("クリップボード監視を一時停止", ToggleClipWatch)
A_TrayMenu.Add("クリップボード履歴を全削除", DeleteHistoryAll)
A_TrayMenu.Add("定型文ファイルを編集 (snippets.ini)", EditSnippetsFile)
A_TrayMenu.Add("定型文の管理...", ShowSnippetManager)
A_TrayMenu.Add("設定フォルダを開く", (*) => Run('explorer.exe "' . A_ScriptDir . '"'))
A_TrayMenu.Add()  ; セパレータ
A_TrayMenu.Add("v1.6.0", (*) => 0), A_TrayMenu.Disable("v1.6.0")
A_TrayMenu.Add()  ; セパレータ

; 初回起動時（スタートアップ未登録かつ確認未表示）は自動実行を促す
settingsPath := A_ScriptDir . "\startup-prompted.flag"
if !IsStartupRegistered() && !FileExist(settingsPath) {
    FileAppend("1", settingsPath)
    result := MsgBox("次回からWindows起動時に自動で立ち上げますか？`n（あとからトレイアイコンの右クリックメニューでいつでも切り替えられます）",
        "送信サジェスト", "YesNo Icon?")
    if (result = "Yes") {
        EnableStartup()
        RefreshStartupMenuLabel()
    }
}
