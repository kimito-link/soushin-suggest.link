; Safety probe: HotIf numkey scope must NOT capture digits when LauncherGui is unset.
; Exit 0 = digits pass through (no residual hook). Exit 1 = digits were swallowed.
#Requires AutoHotkey v2.0
#SingleInstance Force
CoordMode "Mouse", "Screen"

global LauncherGui := 0
global Captured := 0

HotIf (*) => IsObject(LauncherGui) && WinActive("ahk_id " . LauncherGui.Hwnd)
Loop 10
    Hotkey Mod(A_Index, 10) . "", (*) => (Captured += 1)
HotIf

; Fake "launcher exists but not focused" gap: object alive, WinActive false.
LauncherGui := Gui("+ToolWindow")
LauncherGui.Show("Hide")  ; exists, not active

g := Gui(, "numkey-probe")
e := g.Add("Edit", "w200")
g.Show()
WinActivate("ahk_id " . g.Hwnd)
Sleep 200
ControlSend "1234567890", e, "ahk_id " . g.Hwnd
Sleep 300
got := e.Value
g.Destroy()
try LauncherGui.Destroy()
LauncherGui := 0

if (Captured != 0) {
    FileAppend "FAIL captured=" Captured " edit=[" got "]`n", "*"
    ExitApp 1
}
if (got != "1234567890") {
    FileAppend "FAIL edit=[" got "] expected=1234567890`n", "*"
    ExitApp 1
}
FileAppend "PASS digits pass-through; Captured=0`n", "*"
ExitApp 0
