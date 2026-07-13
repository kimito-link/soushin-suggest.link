#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================
;  送信サジェスト / soushin-suggest.link
;  なぞってコピー・右クリック長押しで送信・サイドボタンでスクショ
;  Windows 10/11 対応・買い切り・追加課金なし
; ============================================================
;
;  左クリック（ドラッグ）  -> 選択範囲を自動コピー（対応アプリのみ）
;  右クリック長押し(0.35s) -> サイトに合った送信キーを送る（短押しは通常の右クリック）
;  サイドボタン(戻る)      -> 全画面スクリーンショット
;  ミドルクリック           -> Git Bash を前面へ（無ければ起動）
;  Ctrl+Win+C              -> なぞってコピーのON/OFF切り替え
;
;  対応アプリ・送信ルールは sites.ini で編集できます（同梱）。
;  トレイの緑の "H" アイコンを右クリック -> Suspend Hotkeys / Exit

global CopyOnSelect := true
global dragX := 0, dragY := 0, dragT := 0
global SitesConfig := Map()
global SiteRules := []

; --- load sites.ini (per-app rules + [sites] title-keyword rules) ---
; Uses FileRead+manual parsing rather than IniRead: IniRead (GetPrivateProfileString)
; is known to mis-decode non-ASCII keys unless the file is UTF-16 LE, and [sites]
; needs to hold Japanese keywords (e.g. "ココナラ") reliably as UTF-8.
LoadSitesConfig() {
    global SitesConfig, SiteRules
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
    exe := WinGetProcessName("A")
    if !SitesConfig.Has(exe)
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
        ToolTip("コピーしました")
        SetTimer () => ToolTip(), -800
    }
}

^#c:: {
    global CopyOnSelect
    CopyOnSelect := !CopyOnSelect
    ToolTip(CopyOnSelect ? "なぞってコピー: ON" : "なぞってコピー: OFF")
    SetTimer () => ToolTip(), -1200
}

; --- 右クリック長押し(0.35s) = 送信サジェスト ---
; 対応アプリ・Git Bash のみで有効。短押しは通常の右クリックのまま。
#HotIf CopyOnSelectApp() || WinActive("ahk_exe mintty.exe")
$RButton:: {
    if KeyWait("RButton", "T0.35") {
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

; --- サイドボタン(戻る) = 全画面スクリーンショット ---
XButton1::Send("#{PrintScreen}")

; --- 起動時 ---
LoadSitesConfig()
TrayTip("送信サジェスト", "常駐を開始しました", "Mute")
