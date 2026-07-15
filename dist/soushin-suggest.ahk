#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"
; ============================================================
;  送信サジェスト / soushin-suggest.link
;  なぞってコピー・右クリック長押しで送信・サイドボタンでスクショ
;  Windows 10/11 対応・買い切り・追加課金なし
; ============================================================
;
;  左クリック（ドラッグ）  -> 選択範囲を自動コピー（対応アプリのみ）
;  右クリック長押し(0.35s) -> サイトに合った送信キーを送る（短押しは通常の右クリック）
;  サイドボタン(戻る)      -> 短押し=全画面スクショ / 対応アプリでは長押し=クイックペースト
;  ミドルクリック           -> Git Bash を前面へ（無ければ起動）
;  Ctrl+Win+C              -> なぞってコピーのON/OFF切り替え
;
;  対応アプリ・送信ルールは sites.ini で編集できます（同梱）。
;  トレイの緑の "H" アイコンを右クリック -> Suspend Hotkeys / Exit

global CopyOnSelect := true
global dragX := 0, dragY := 0, dragT := 0
global SitesConfig := Map()
global SiteRules := []
global ClipHistory := []        ; メモリのみ・非永続（なぞってコピー経由のみ）
global ClipHistoryMax := 10
global LongPressSec := 0.35     ; sites.ini [general] longpress= で上書き可
global LauncherGui := 0
global LauncherTarget := 0

; --- load sites.ini (per-app rules + [sites] title-keyword rules) ---
; Uses FileRead+manual parsing rather than IniRead: IniRead (GetPrivateProfileString)
; is known to mis-decode non-ASCII keys unless the file is UTF-16 LE, and [sites]
; needs to hold Japanese keywords (e.g. "ココナラ") reliably as UTF-8.
LoadSitesConfig() {
    global SitesConfig, SiteRules, LongPressSec
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
        else if (section != "" && StrLower(key) = "send")
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

CopyOnSelectApp() {
    return CurrentSendMode() != ""
}

; --- スタートアップ登録 (shell:startup にショートカットを作成/削除) ---
global StartupMenuLabel := ""

StartupShortcutPath() {
    return A_Startup . "\soushin-suggest.lnk"
}

IsStartupRegistered() {
    return FileExist(StartupShortcutPath()) ? true : false
}

StartupLabelFor(registered) {
    return registered ? "Windows起動時に自動実行: ON" : "Windows起動時に自動実行: OFF"
}

EnableStartup() {
    try FileCreateShortcut(A_ScriptFullPath, StartupShortcutPath(), A_ScriptDir)
    catch as e {
        ToolTip("スタートアップ登録に失敗しました: " . e.Message)
        SetTimer () => ToolTip(), -2000
        return
    }
    ToolTip("次回のWindows起動時から自動で立ち上がります")
    SetTimer () => ToolTip(), -1800
}

DisableStartup() {
    try FileDelete(StartupShortcutPath())
    ToolTip("自動起動を解除しました")
    SetTimer () => ToolTip(), -1800
}

ToggleStartup(*) {
    if IsStartupRegistered()
        DisableStartup()
    else
        EnableStartup()
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
    ToolTip("Git Bash が見つかりませんでした")
    SetTimer () => ToolTip(), -1500
}

; --- なぞってコピー: ドラッグ解放でCtrl+Cを送る ---
~LButton:: {
    global dragX, dragY, dragT
    MouseGetPos &dragX, &dragY
    dragT := A_TickCount
}

~LButton up:: {
    global CopyOnSelect, dragX, dragY, dragT
    if !CopyOnSelect || !CopyOnSelectApp()
        return
    MouseGetPos &x, &y
    dt := A_TickCount - dragT
    if (Abs(x - dragX) < 30 && Abs(y - dragY) < 30) || dt < 150 || dt > 15000
        return
    prev := A_Clipboard
    Send("^c")
    Sleep 150
    if (A_Clipboard != "" && A_Clipboard != prev) {
        PushClipHistory(A_Clipboard)
        ToolTip("コピーしました")
        SetTimer () => ToolTip(), -800
    }
}

PushClipHistory(text) {
    global ClipHistory, ClipHistoryMax
    for i, v in ClipHistory
        if (v = text) {
            ClipHistory.RemoveAt(i)   ; 重複は先頭へ昇格
            break
        }
    ClipHistory.InsertAt(1, text)
    while (ClipHistory.Length > ClipHistoryMax)
        ClipHistory.Pop()
}

^#c:: {
    global CopyOnSelect
    CopyOnSelect := !CopyOnSelect
    ToolTip(CopyOnSelect ? "なぞってコピー: ON" : "なぞってコピー: OFF")
    SetTimer () => ToolTip(), -1200
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
    if (mode = "manual") {
        ToolTip("このサイトは送信ボタンを押してください（自動送信非対応）")
        SetTimer () => ToolTip(), -1800
    } else {
        Send("{Enter}")
    }
}
#HotIf

; --- ミドルクリックで Git Bash を前面へ ---
#HotIf !WinActive("ahk_exe mintty.exe")
MButton::ActivateGitBash()
#HotIf
^#t::ActivateGitBash()

; --- サイドボタン(戻る): 短押し=スクショ / 対応アプリでは長押し=クイックペースト ---
XButton1:: {
    global LongPressSec
    if !(CopyOnSelectApp() || WinActive("ahk_exe mintty.exe")) {
        Send("#{PrintScreen}")
        return
    }
    if KeyWait("XButton1", "T" . LongPressSec) {
        Send("#{PrintScreen}")
        return
    }
    KeyWait("XButton1")
    ShowLauncher()
}

ShowLauncher() {
    global ClipHistory, LauncherGui, LauncherTarget
    if (ClipHistory.Length = 0) {
        ToolTip("履歴がありません（なぞってコピーすると貯まります）")
        SetTimer () => ToolTip(), -1800
        return
    }
    LauncherTarget := WinExist("A")           ; ペースト先を先に記憶
    CloseLauncher()
    LauncherGui := Gui("-Caption +AlwaysOnTop +ToolWindow +Border")
    LauncherGui.SetFont("s10", "Meiryo UI")
    items := []
    for v in ClipHistory {
        s := RegExReplace(v, "\s+", " ")
        items.Push(StrLen(s) > 40 ? SubStr(s, 1, 40) . "…" : s)
    }
    lb := LauncherGui.Add("ListBox", "w340 r" . Min(items.Length, 10), items)
    lb.OnEvent("Change", PasteFromLauncher)
    LauncherGui.OnEvent("Escape", (*) => CloseLauncher())
    MouseGetPos &mx, &my
    LauncherGui.Show("x" . mx . " y" . my)
    WinActivate("ahk_id " . LauncherGui.Hwnd)
    SetTimer(CheckLauncherFocus, 150)         ; リスト外クリックで閉じる
}

PasteFromLauncher(lb, *) {
    global ClipHistory, LauncherTarget
    idx := lb.Value
    if (idx < 1)
        return
    text := ClipHistory[idx]
    CloseLauncher()
    A_Clipboard := text
    if (LauncherTarget && WinExist("ahk_id " . LauncherTarget))
        WinActivate("ahk_id " . LauncherTarget)
    Sleep 150
    Send("^v")
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
    if IsObject(LauncherGui) {
        try LauncherGui.Destroy()
        LauncherGui := 0
    }
}

; --- 起動時 ---
LoadSitesConfig()
TrayTip("送信サジェスト", "常駐を開始しました", "Mute")

; トレイメニューに自動起動のON/OFFを追加
StartupMenuLabel := StartupLabelFor(IsStartupRegistered())
A_TrayMenu.Add(StartupMenuLabel, ToggleStartup)
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
