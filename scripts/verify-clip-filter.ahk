; Security probe for global clipboard filter (Phase 1).
; Start soushin-suggest.exe first, then run this script.
#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"

fail(msg) {
    FileAppend "FAIL " msg "`n", "*"
    ExitApp 1
}
pass(msg) {
    FileAppend "PASS " msg "`n", "*"
}

launcherItems() {
    if !WinExist("ahk_class AutoHotkeyGUI")
        return []
    try return ControlGetItems("ListBox1", "ahk_class AutoHotkeyGUI")
    catch
        return []
}

Sleep 2000   ; age out prior tick windows

; --- Test A: programmatic inject without user copy gesture ---
inject := "injected-test-string-" . A_TickCount
DllCall("User32\OpenClipboard", "Ptr", 0)
DllCall("User32\EmptyClipboard")
DllCall("User32\CloseClipboard")
A_Clipboard := inject
Sleep 500
Send("^#v")
Sleep 600
if !WinExist("ahk_class AutoHotkeyGUI")
    fail("launcher did not open after Ctrl+Win+V")
found := false
for it in launcherItems()
    if InStr(it, "injected-test-string")
        found := true
Send("{Escape}")
Sleep 300
if found
    fail("injected clipboard text appeared in history (filter broken)")
pass("inject filtered out")

; --- Test B: user-like Ctrl+C via Notepad (keyboard path) ---
marker := "user-copy-marker-" . A_TickCount
Run "notepad.exe"
if !WinWait("ahk_exe notepad.exe", , 5)
    fail("notepad did not start")
WinActivate("ahk_exe notepad.exe")
Sleep 300
SendText marker
Sleep 200
Send("^a")
Sleep 100
Send("^c")
Sleep 500
Send("^#v")
Sleep 600
found2 := false
for it in launcherItems()
    if InStr(it, "user-copy-marker")
        found2 := true
Send("{Escape}")
Sleep 200
WinClose("ahk_exe notepad.exe")
if !found2
    fail("Ctrl+C user copy did not appear in history")
pass("Ctrl+C captured")
ExitApp 0
