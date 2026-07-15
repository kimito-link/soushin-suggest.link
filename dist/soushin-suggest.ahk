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
;  サイドボタン(戻る)      -> 短押し=全画面スクショ / 対応アプリでは長押し=クイックペースト
;  ミドルクリック           -> Git Bash を前面へ（無ければ起動）
;  Ctrl+Win+C              -> なぞってコピーのON/OFF切り替え
;  Ctrl+Win+V              -> クイックペーストを開く（マウスなしでも呼び出せる）
;
;  対応アプリ・送信ルールは sites.ini、定型文は snippets.ini で編集できます（同梱）。
;  トレイのアイコンを右クリック -> Suspend Hotkeys / Exit

global CopyOnSelect := true, dragX := 0, dragY := 0, dragT := 0
global SitesConfig := Map()
global SiteRules := []
global ClipHistory := [], ClipHistoryMax := 10   ; {text,time}の配列・メモリのみ・非永続（なぞってコピー経由のみ）
global LongPressSec := 0.35     ; sites.ini [general] longpress= で上書き可
global LauncherGui := 0, LauncherTarget := 0, LauncherTab := 0, Snippets := [], LauncherDragBar := 0, LauncherPos := "", LauncherPinned := false, LauncherLbH := 0, LauncherLbS := 0, LauncherHoverLast := ""

Flash(msg, ms := 1500) {
    ToolTip(msg)
    SetTimer () => ToolTip(), -ms
}

; --- load sites.ini (per-app rules + [sites] title-keyword rules) ---
; IniReadは使わない: 非ASCIIキーをUTF-16 LE以外で誤読する既知の問題があり、[sites]は日本語キーワードを扱うため
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
    try FileDelete(StartupShortcutPath())
    Flash("自動起動を解除しました", 1800)
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
        Flash("コピーしました", 800)
    }
}

PushClipHistory(text) {
    global ClipHistory, ClipHistoryMax
    for i, v in ClipHistory
        if (v.text = text) {
            ClipHistory.RemoveAt(i)   ; 重複は先頭へ昇格（時刻も更新される）
            break
        }
    ClipHistory.InsertAt(1, {text: text, time: FormatTime(, "HH:mm")})
    while (ClipHistory.Length > ClipHistoryMax)
        ClipHistory.Pop()
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

; --- snippets.ini: ラベル=本文（\n で改行、run:パス で起動）---
; sites.iniパーサと違い、インラインコメント(;)は剥がさない — 本文に ; が入りうるため。
; IniRead は使わない（非ASCIIキー誤読の既知の罠。ラベルは日本語になる）。
LoadSnippets() {
    items := []
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

ShowLauncher() {
    global ClipHistory, LauncherGui, LauncherTarget, Snippets, LauncherTab, LauncherDragBar, LauncherPos, LauncherPinned, LauncherLbH, LauncherLbS, LauncherHoverLast
    Snippets := LoadSnippets()                ; 開くたびに読む: iniを編集→次の長押しで即反映
    if (ClipHistory.Length = 0 && Snippets.Length = 0) {
        Flash("履歴がありません（なぞってコピーすると貯まります）", 1800)
        return
    }
    LauncherTarget := WinExist("A")
    CloseLauncher()
    LauncherGui := Gui("-Caption +AlwaysOnTop +ToolWindow +Border")
    LauncherGui.SetFont("s12", "Meiryo UI")
    LauncherDragBar := LauncherGui.Add("Text", "w460 h12 BackgroundD4DCE8 +0x100")  ; SS_NOTIFY相当をv2既定に加え、押下を明示検知
    LauncherTab := LauncherGui.Add("Tab3", "w460 -Wrap",
        ["履歴 " . ClipHistory.Length, "定型文 " . Snippets.Length])
    rows := Min(Max(ClipHistory.Length, Snippets.Length, 3), 10)
    LauncherTab.UseTab(1)
    histItems := []
    for v in ClipHistory {
        s := RegExReplace(v.text, "\s+", " ")
        histItems.Push(Mod(A_Index, 10) . " " . (StrLen(s) > 58 ? SubStr(s, 1, 58) . "…" : s))
    }
    LauncherLbH := LauncherGui.Add("ListBox", "w440 r" . rows . " BackgroundF0F6FF", histItems)
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
    text := ClipHistory[idx].text
    CloseLauncher()
    PasteText(text)
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
    global LauncherTarget
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

; 右クリック: 掴みしろ=固定解除 / 履歴項目=定型文へ昇格
LauncherContextMenu(g, ctrl, item, isRC, x, y) {
    global LauncherDragBar, LauncherLbH, LauncherPos, LauncherPinned
    if (ctrl = LauncherDragBar) {
        LauncherPos := "", LauncherPinned := false
        Flash("固定を解除しました（次回からカーソル位置に表示）")
    } else if (ctrl = LauncherLbH)
        PromoteHistoryAt(LauncherItemUnderMouse(LauncherLbH))
}

; 履歴→定型文昇格。IniWriteは使わず、UTF-8明示のFileAppendで追記する
PromoteHistoryAt(idx) {
    global ClipHistory
    if (idx < 1 || idx > ClipHistory.Length)
        return
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
; 数字キー1-9,0=10: ランチャーがアクティブな間だけ有効（HotIfスコープ限定・解除処理は不要）
HotIf (*) => IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)
Loop 10
    Hotkey Mod(A_Index, 10) . "", LauncherPickKey
HotIf
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
