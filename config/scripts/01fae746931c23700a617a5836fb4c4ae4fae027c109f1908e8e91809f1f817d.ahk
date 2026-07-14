#SingleInstance, force

F9::
    ExportOnly("/KAINET-QUOTE-LIST", "KAINET-QUOTE-LIST Data.csv")
return

;====================================================================================

ExportOnly(eraQuery, csvName) {
    global hCtl
    csvPath := "C:\Users\" . A_UserName . "\OneDrive - Hopper Motor Group\Documents\PSdata\" . csvName

    preTime := FileExist(csvPath) ? FileGetTimeMod(csvPath) : ""

    if !WinExist("ERA Port")
        return Fail("ERA Port window not found. Is ERA open?")
    ERA_Activate()
    ERA_HomePage()
    if !hCtl
        return Fail("ERA control handle not found after HomePage.")

    SendText(hCtl, "6913`r")
    SendText(hCtl, eraQuery . "`r")
    SendText(hCtl, "o")
    SendText(hCtl, "4")
    SendText(hCtl, "`r")
    SendText(hCtl, "`r")
    SendText(hCtl, "`r")

    if !WaitAndSend("PC destination format", "ListBox1", "{Enter}", 3)
        return
    if !WaitAndSend("Select the destination file for the ERA data", "Button2", "{Enter}", 3)
        return
    if !WaitAndSend("Confirm Save As", "Button1", "{Left}{Enter}", 3)
        return

    WinWaitActive, File Import Monitor,, 10
    if !ErrorLevel
        WinWaitNotActive, File Import Monitor,, 80

    ; Poll for fresh CSV
    Loop, 60 {
        if FileExist(csvPath) {
            if (preTime == "" || FileGetTimeMod(csvPath) != preTime)
                break
        }
        if (A_Index = 60)
            return Fail("CSV not updated within 60s (export may have failed):`n" . csvPath)
        Sleep, 1000
    }
    Sleep, 500

    MsgBox, 64, Done!, Export complete!`n%csvName%`n%csvPath%
    WinActivate, ERA
    Sleep, 200
    Send,{F1}
    return true
}

WaitAndSend(winTitle, control, keys, timeout) {
    WinWait, %winTitle%,, %timeout%
    if ErrorLevel
        return Fail("Window not found within " . timeout . "s:`n" . winTitle)
    Sleep, 500
    ControlSend, %control%, %keys%, %winTitle%
    if ErrorLevel
        return Fail("ControlSend failed on '" . control . "' in:`n" . winTitle)
    return true
}

FileGetTimeMod(path) {
    FileGetTime, t, %path%, M
    return t
}

Fail(msg) {
    MsgBox, 48, Error, %msg%
    return false
}

;====================================================================================

ERA_Activate() {
WinActivate, ERA Port
WinWaitActive, ERA Port
global hWnd
global hCtl
hWnd := WinExist("ERA Port")
Sleep, 100
ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hWnd%
if (!hCtl) {
    ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hWnd%
}
text := "C:\Program Files (x86)\PowerLink\image\i_pageb.bmp"
ControlClick , Button18, ahk_id %hWnd%, %text%, Left, 1, NA
}

ERA_HomePage(){
WinActivate, ERA Port
WinWaitActive, ERA Port
global hWnd
global hCtl
hWnd := WinExist("ERA Port")
Sleep, 100
ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010003:00000000:000000001, ahk_id %hWnd%
if (!hCtl) {
    ControlGet, hCtl, Hwnd,, Afx:10000000:b:00010005:00000000:000000001, ahk_id %hWnd%
}
text := "C:\Program Files (x86)\PowerLink\image\i_pageb.bmp"
ControlClick , Button18, ahk_id %hWnd%, %text%, Left, 1, NA
Loop 13
	SendKey(hCtl, 0x08)
Loop, 1
	SendKey(hCtl, 0x71)
Loop, 2
    SendKey(hCtl, 0x70)
Loop, 3
    SendText(hCtl, "END`r")
Sleep, 250
WinGet, hwnd, ID,, No previous menu
PostMessage, 0x10,, , , ahk_id %hwnd%
}

SendKey(hwnd, vk) {
    WM_KEYDOWN := 0x100
    WM_KEYUP := 0x101
    DllCall("PostMessage", "Ptr", hwnd, "UInt", WM_KEYDOWN, "Ptr", vk, "Ptr", 0)
    DllCall("PostMessage", "Ptr", hwnd, "UInt", WM_KEYUP, "Ptr", vk, "Ptr", 0)
}

SendText(hwnd, text) {
    Loop, Parse, text
	{
        SendCharToControl(hwnd, A_LoopField)
	}
	Sleep, 150
}

SendCharToControl(hwnd, char) {
    WM_CHAR := 0x102
    DllCall("PostMessage", "Ptr", hwnd, "UInt", WM_CHAR, "Ptr", Asc(char), "Ptr", 0)
}